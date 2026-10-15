import Foundation

public struct CalendarSummaryInput: Codable, Sendable {
    public struct Event: Codable, Sendable {
        public var title: String
        public var start: String
        public var end: String
        public var allDay: Bool
        public var location: String
    }
    public let rangeStart: String
    public let rangeEndExclusive: String
    public let timeZone: String
    public let events: [Event]
    public init(events: [CalendarEventSnapshot], range: DateInterval, timeZone: TimeZone) {
        let iso = ISO8601DateFormatter(); iso.timeZone = timeZone
        rangeStart = iso.string(from: range.start); rangeEndExclusive = iso.string(from: range.end)
        self.timeZone = timeZone.identifier
        self.events = events.filter { Scheduling.overlaps($0.interval(in: timeZone), range) }
            .sorted { $0.start < $1.start }.map {
                let interval = $0.interval(in: timeZone)
                return Event(title: $0.title, start: iso.string(from: interval.start), end: iso.string(from: interval.end), allDay: $0.allDay, location: $0.location)
            }
    }
    public func encoded() throws -> String {
        guard events.count <= 500 else { throw ShikeError.message("当前日程超过 500 条，请缩小日期范围或减少显示的日历。") }
        let data = try JSONEncoder().encode(self)
        guard data.count <= 120_000 else { throw ShikeError.message("日程内容过多，请缩小总结范围。") }
        return String(decoding: data, as: UTF8.self)
    }
}

/// A frozen, allowlisted calendar snapshot plus the conversation about it.
/// Older task records can still be discussed using their summary alone.
public struct CalendarSummaryContext: Codable, Sendable {
    public struct Exchange: Codable, Sendable {
        public let question: String?
        public let answer: CalendarSummary
        public init(question: String?, answer: CalendarSummary) {
            self.question = question; self.answer = answer
        }
    }
    public let title: String
    public let input: CalendarSummaryInput?
    public var exchanges: [Exchange]
    public init(title: String, input: CalendarSummaryInput?, exchanges: [Exchange] = []) {
        self.title = title; self.input = input; self.exchanges = exchanges
    }
    public func encoded(question: String) throws -> String {
        let clean = question.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty, clean.count <= 4000 else { throw ShikeError.message("请填写追问内容，最多 4000 字。") }
        _ = try input?.encoded()
        struct Payload: Encodable { let context: CalendarSummaryContext; let question: String }
        let data = try JSONEncoder().encode(Payload(context: self, question: clean))
        guard data.count <= 240_000 else { throw ShikeError.message("这次对话内容较多，请重新总结后继续提问。") }
        return String(decoding: data, as: UTF8.self)
    }
}

public struct CalendarSummary: Codable, Equatable, Sendable {
    public var overview: String
    public var agenda: [String]
    public var attention: [String]
    public var suggestions: [String]
    public init(overview: String, agenda: [String], attention: [String], suggestions: [String]) {
        self.overview = overview; self.agenda = agenda; self.attention = attention; self.suggestions = suggestions
    }
    public static func decode(_ content: String) throws -> Self {
        let data = try StructuredModelOutput.data(content)
        guard let result = try? JSONDecoder().decode(Self.self, from: data),
              !result.overview.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              result.overview.count <= 6000,
              [result.agenda, result.attention, result.suggestions].allSatisfy({ $0.count <= 100 && $0.allSatisfy { $0.count <= 3000 } }) else {
            throw ShikeError.message("暂时无法读取总结结果，请重试。")
        }
        return result
    }
    public func text(title: String, markdown: Bool) -> String {
        var parts = [(markdown ? "# " : "") + title, overview]
        for (heading, items) in [("日程安排", agenda), ("需要留意", attention), ("安排建议", suggestions)] where !items.isEmpty {
            parts.append((markdown ? "## " : "") + heading + "\n" + items.map { (markdown ? "- " : "• ") + $0 }.joined(separator: "\n"))
        }
        return parts.joined(separator: "\n\n")
    }
}
