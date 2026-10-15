import Foundation

public struct PlanningTurn: Codable, Equatable, Identifiable, Sendable {
    public var id = UUID()
    public var role: String
    public var text: String
    public var options: [String]
    public init(role: String, text: String, options: [String] = []) {
        self.role = role; self.text = text; self.options = options
    }
}

public struct PlanningConversation: Codable, Equatable, Sendable {
    public var goal: String
    public var turns: [PlanningTurn] = []
    public var start: Date
    /// Exclusive end, always calculated with calendar arithmetic.
    public var end: Date
    public var awaitingReply = false
    public var hasProposal = false
    public var checkedAvailability = false
    public var proposalNeedsUpdate: Bool?
    public init(goal: String, now: Date = .now, timeZone: TimeZone = .current) {
        self.goal = goal
        var calendar = Calendar(identifier: .gregorian); calendar.timeZone = timeZone
        start = calendar.startOfDay(for: now)
        end = calendar.date(byAdding: .day, value: 7, to: start)!
    }
    public func validate(timeZone: TimeZone) throws {
        var calendar = Calendar(identifier: .gregorian); calendar.timeZone = timeZone
        guard end > start, end <= calendar.date(byAdding: .day, value: 30, to: start)! else {
            throw ShikeError.message("请选择 1 至 30 天的安排范围。")
        }
        guard !goal.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw ShikeError.message("先写下想做的事。") }
        guard goal.count + turns.reduce(0, { $0 + $1.text.count }) <= 60_000 else {
            throw ShikeError.message("这次问答内容较长，请新建一次安排，简要说明已确定的要求。")
        }
    }
}

public struct PlanningReply: Equatable, Sendable {
    public enum Kind: String, Codable, Sendable { case question, proposal, unavailable }
    public var kind: Kind
    public var message: String
    public var options: [String]
    public var drafts: [EventDraft]
    public init(kind: Kind, message: String, options: [String] = [], drafts: [EventDraft] = []) {
        self.kind = kind; self.message = message; self.options = options; self.drafts = drafts
    }
    public static func decode(_ content: String, timeZone: TimeZone) throws -> Self {
        struct Envelope: Decodable { let kind: Kind; let message: String; let options: [String]? }
        let data = try StructuredModelOutput.data(content)
        guard let value = try? JSONDecoder().decode(Envelope.self, from: data),
              !value.message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, value.message.count <= 6000,
              (value.options ?? []).count <= 6, (value.options ?? []).allSatisfy({ $0.count <= 300 }) else {
            throw ShikeError.message("无法读取模型的安排建议，请重试或更换模型。")
        }
        let drafts = value.kind == .proposal ? try ExtractionDecoder.decode(String(decoding: data, as: UTF8.self), timeZone: timeZone) : []
        guard value.kind != .proposal || !drafts.isEmpty else { throw ShikeError.message("模型没有给出可用的安排，请补充要求后重试。") }
        return Self(kind: value.kind, message: value.message, options: value.options ?? [], drafts: drafts)
    }
}

/// Only intervals from this type are sent to a model, never CalendarEventSnapshot.
public enum Scheduling {
    public static func overlaps(_ a: DateInterval, _ b: DateInterval) -> Bool {
        a.start < b.end && b.start < a.end
    }
    public static func freeIntervals(in range: DateInterval, busy: [DateInterval]) -> [DateInterval] {
        guard range.end > range.start else { return [] }
        let clipped = busy.compactMap { value -> DateInterval? in
            let start = max(value.start, range.start), end = min(value.end, range.end)
            return end > start ? DateInterval(start: start, end: end) : nil
        }.sorted { $0.start < $1.start }
        var cursor = range.start, result: [DateInterval] = []
        for interval in clipped {
            if interval.start > cursor { result.append(DateInterval(start: cursor, end: interval.start)) }
            cursor = max(cursor, interval.end)
        }
        if cursor < range.end { result.append(DateInterval(start: cursor, end: range.end)) }
        return result
    }
    public static func days(from start: Date, count: Int, timeZone: TimeZone) -> [Date] {
        var calendar = Calendar(identifier: .gregorian); calendar.timeZone = timeZone
        let day = calendar.startOfDay(for: start)
        return (0..<max(0, count)).compactMap { calendar.date(byAdding: .day, value: $0, to: day) }
    }
}

public struct CalendarEventSnapshot: Identifiable, Equatable, Sendable {
    public var id: String { "\(calendarID)|\(eventID)|\(start.timeIntervalSinceReferenceDate)" }
    public var eventID: String
    public var itemID: String
    public var calendarID: String
    public var title: String
    public var start: Date
    public var end: Date
    public var allDay: Bool
    public var location: String
    public var notes: String
    public var timeZone: String
    public var blocksTime: Bool
    /// All-day entries remain visible in the calendar but never reserve planning time.
    public var blocksPlanningTime: Bool { blocksTime && !allDay }
    public var interval: DateInterval { DateInterval(start: start, end: max(start, end)) }
    public func interval(in displayZone: TimeZone) -> DateInterval {
        guard allDay else { return interval }
        var source = Calendar(identifier: .gregorian); source.timeZone = TimeZone(identifier: timeZone) ?? .current
        var target = Calendar(identifier: .gregorian); target.timeZone = displayZone
        let begin = target.date(from: source.dateComponents([.year, .month, .day], from: start)) ?? start
        // EventKit also returns inclusive ends such as 23:59:59. Round those up
        // to the next civil day; keep midnight ends exclusive. Never mutate the
        // stored dates, which are still needed to resolve and edit the occurrence.
        let endDay = source.startOfDay(for: end)
        let exclusiveEnd = end > endDay ? source.date(byAdding: .day, value: 1, to: endDay) ?? end : endDay
        let finish = target.date(from: source.dateComponents([.year, .month, .day], from: exclusiveEnd)) ?? exclusiveEnd
        return DateInterval(start: begin, end: max(begin, finish))
    }
    public init(eventID: String, itemID: String, calendarID: String, title: String, start: Date, end: Date,
                allDay: Bool = false, location: String = "", notes: String = "", timeZone: String = TimeZone.current.identifier,
                blocksTime: Bool = true) {
        self.eventID = eventID; self.itemID = itemID; self.calendarID = calendarID; self.title = title
        self.start = start; self.end = end; self.allDay = allDay; self.location = location; self.notes = notes
        self.timeZone = timeZone; self.blocksTime = blocksTime
    }
}

public struct CalendarPreferences: Codable, Equatable, Sendable {
    public var visibleDays = 1
    public var showCountdowns: Bool?
    public var countdownLayout: CountdownLayout?
    /// nil means all, [] means none. References survive different local calendar identifiers.
    public var visibleCalendars: [CalendarReference]?
    public var planningCalendars: [CalendarReference]?
    /// nil follows the system time zone.
    public var timeZoneIdentifier: String?
    public init() {}
}
