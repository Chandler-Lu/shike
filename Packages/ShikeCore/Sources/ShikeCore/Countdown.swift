import Foundation

/// A Gregorian civil date. Never stores midnight as a UTC timestamp.
public struct CivilDate: Codable, Equatable, Hashable, Sendable, CustomStringConvertible {
    public var year: Int
    public var month: Int
    public var day: Int
    public init(year: Int, month: Int, day: Int) { self.year = year; self.month = month; self.day = day }
    public init(_ date: Date, timeZone: TimeZone = .current) {
        var c = Calendar(identifier: .gregorian); c.timeZone = timeZone
        let p = c.dateComponents([.year, .month, .day], from: date)
        self.init(year: p.year!, month: p.month!, day: p.day!)
    }
    public var description: String { String(format: "%04d-%02d-%02d", year, month, day) }
    public func date(in timeZone: TimeZone = .current) -> Date? {
        var c = Calendar(identifier: .gregorian); c.timeZone = timeZone
        guard let d = c.date(from: DateComponents(year: year, month: month, day: day)), CivilDate(d, timeZone: timeZone) == self else { return nil }
        return d
    }
    public init(from decoder: Decoder) throws {
        let box = try decoder.singleValueContainer(), value = try box.decode(String.self)
        let parts = value.split(separator: "-").compactMap { Int($0) }
        guard parts.count == 3 else { throw DecodingError.dataCorruptedError(in: box, debugDescription: "Expected YYYY-MM-DD") }
        self.init(year: parts[0], month: parts[1], day: parts[2])
        guard description == value, date(in: TimeZone(secondsFromGMT: 0)!) != nil else {
            throw DecodingError.dataCorruptedError(in: box, debugDescription: "Invalid civil date")
        }
    }
    public func encode(to encoder: Encoder) throws { var box = encoder.singleValueContainer(); try box.encode(description) }
}

public enum CountdownCalendar: String, Codable, CaseIterable, Sendable { case gregorian, chinese
    public var title: String { self == .gregorian ? "公历" : "农历" }
}
public enum CountdownRepeat: String, Codable, CaseIterable, Sendable { case none, weekly, monthly, yearly
    public var title: String { switch self { case .none: return "不重复"; case .weekly: return "每周"; case .monthly: return "每月"; case .yearly: return "每年" } }
}
public enum CountdownLayout: String, Codable, CaseIterable, Sendable {
    case single, double, strip
    public var title: String { switch self { case .single: "一行一个"; case .double: "一行两个"; case .strip: "窄条列表" } }
    public var symbol: String { switch self { case .single: "rectangle"; case .double: "square.grid.2x2"; case .strip: "list.bullet" } }
}
/// Paper colors for the in-app card. Optional on Countdown for older backups.
public enum CountdownCardColor: String, Codable, CaseIterable, Sendable {
    case paper, cream, peach, sage, sky, lilac
    public var title: String {
        switch self {
        case .paper: "原纸色"
        case .cream: "奶油黄"
        case .peach: "蜜桃粉"
        case .sage: "鼠尾草绿"
        case .sky: "雾蓝"
        case .lilac: "浅丁香"
        }
    }
    public init(from decoder: Decoder) throws {
        let value = try decoder.singleValueContainer().decode(String.self)
        self = Self(rawValue: value) ?? .paper
    }
}
/// Wall-clock time in the countdown's time zone; nil on a countdown means day precision.
public struct CountdownTime: Codable, Equatable, Sendable, CustomStringConvertible {
    public var hour: Int
    public var minute: Int
    public var second: Int
    public init(hour: Int = 0, minute: Int = 0, second: Int = 0) { self.hour = hour; self.minute = minute; self.second = second }
    public var isValid: Bool { (0...23).contains(hour) && (0...59).contains(minute) && (0...59).contains(second) }
    public var description: String { String(format: "%02d:%02d:%02d", hour, minute, second) }
}
public struct CountdownReminder: Codable, Equatable, Sendable {
    public var daysBefore: [Int]
    public var hour: Int
    public var minute: Int
    /// Positive natural-day counts from the original date. Optional for old records.
    public var milestoneDays: [Int]?
    /// Optional so existing local documents and CloudKit payloads remain readable.
    public var anniversaries: Bool?
    public var dayInterval: Int?
    public var milestones: [Int] { get { milestoneDays ?? [] } set { milestoneDays = newValue } }
    public var isEnabled: Bool { !daysBefore.isEmpty || !milestones.isEmpty || anniversaries == true || dayInterval != nil }
    public init(daysBefore: [Int] = [], hour: Int = 9, minute: Int = 0, milestoneDays: [Int]? = nil, anniversaries: Bool? = nil, dayInterval: Int? = nil) {
        self.daysBefore = daysBefore; self.hour = hour; self.minute = minute; self.milestoneDays = milestoneDays
        self.anniversaries = anniversaries; self.dayInterval = dayInterval
    }
}
public struct CountdownCategory: Codable, Identifiable, Equatable, Sendable {
    public var id: UUID
    public var name: String
    public init(id: UUID = UUID(), name: String) { self.id = id; self.name = name }
    public static let defaults: [Self] = ["纪念日", "工作", "生活"].enumerated().map {
        Self(id: UUID(uuidString: String(format: "00000000-0000-4000-8000-%012d", $0.offset + 1))!, name: $0.element)
    }
}
public struct Countdown: Codable, Identifiable, Equatable, Sendable {
    public var id: UUID
    public var title: String
    public var anchorDate: CivilDate
    public var calendar: CountdownCalendar = .gregorian
    public var recurrence: CountdownRepeat = .none
    /// nil follows the system time zone, including after travel.
    public var timeZoneIdentifier: String?
    public var categoryID: UUID?
    public var notes = ""
    public var pinned = false
    public var reminder = CountdownReminder()
    public var targetTime: CountdownTime?
    public var includesStartDay: Bool?
    public var cardColor: CountdownCardColor?
    /// Identifies a one-time conversion, without linking subsequent edits to the source.
    public var sourceIdentifier: String?
    public init(id: UUID = UUID(), title: String = "", date: CivilDate = CivilDate(.now)) {
        self.id = id; self.title = title; self.anchorDate = date
    }
    public func timeZone(system: TimeZone = .current) -> TimeZone { timeZoneIdentifier.flatMap(TimeZone.init(identifier:)) ?? system }
    public func validate() throws {
        guard !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, title.count <= 200, notes.count <= 20_000,
              (1901...2099).contains(anchorDate.year), anchorDate.date(in: timeZone()) != nil,
              timeZoneIdentifier == nil || TimeZone(identifier: timeZoneIdentifier!) != nil,
              (0...23).contains(reminder.hour), (0...59).contains(reminder.minute),
              targetTime?.isValid != false,
              reminder.dayInterval.map({ (1...100_000).contains($0) }) ?? true,
              reminder.milestones.count <= 60, reminder.milestones.allSatisfy({ (1...100_000).contains($0) }),
              Set(reminder.milestones).count == reminder.milestones.count,
              reminder.daysBefore.allSatisfy({ [0, 1, 3, 7].contains($0) }), Set(reminder.daysBefore).count == reminder.daysBefore.count else {
            throw ShikeError.message("请填写名称与有效日期（1901–2099），并检查时区和提醒时间。")
        }
    }
}
public struct LunarDate: Codable, Equatable, Sendable {
    public let month: Int
    public let day: Int
    public let isLeapMonth: Bool
}
public enum CountdownDates {
    public static func calendar(_ entry: Countdown, systemZone: TimeZone = .current) -> Calendar {
        var c = Calendar(identifier: entry.calendar == .chinese ? .chinese : .gregorian)
        c.timeZone = entry.timeZone(system: systemZone); return c
    }
    public static func lunarDate(_ entry: Countdown, systemZone: TimeZone = .current) -> LunarDate? {
        var c = Calendar(identifier: .chinese); c.timeZone = entry.timeZone(system: systemZone)
        guard let anchor = entry.anchorDate.date(in: c.timeZone) else { return nil }
        let p = c.dateComponents(in: c.timeZone, from: anchor)
        return LunarDate(month: p.month!, day: p.day!, isLeapMonth: p.isLeapMonth ?? false)
    }
    /// The next occurrence on or after the supplied natural day. Never precedes the original date.
    public static func next(_ entry: Countdown, onOrAfter reference: Date, systemZone: TimeZone = .current) -> Date? {
        let c = calendar(entry, systemZone: systemZone)
        guard let anchor = entry.anchorDate.date(in: c.timeZone) else { return nil }
        let day = max(anchor, c.startOfDay(for: reference))
        if entry.recurrence == .none { return anchor >= day ? anchor : nil }
        if entry.recurrence == .weekly {
            let elapsed = c.dateComponents([.day], from: anchor, to: day).day ?? 0
            return c.date(byAdding: .day, value: (7 - elapsed % 7) % 7, to: day)
        }
        let unit: Calendar.Component = entry.recurrence == .yearly ? .year : .month
        guard var period = c.dateInterval(of: unit, for: day)?.start else { return nil }
        let original = c.dateComponents(in: c.timeZone, from: anchor)
        // A candidate can only be in the current or next period; extra bounded iterations
        // also accommodate rare time zones that have skipped a civil day.
        for _ in 0..<4 {
            var monthStart = period
            if unit == .year {
                guard let end = c.date(byAdding: .year, value: 1, to: period) else { return nil }
                var cursor = period, ordinary: Date?, leap: Date?
                while cursor < end {
                    let p = c.dateComponents(in: c.timeZone, from: cursor)
                    if p.month == original.month { if p.isLeapMonth == true { leap = cursor } else { ordinary = cursor } }
                    guard let following = c.date(byAdding: .month, value: 1, to: cursor), following > cursor else { break }
                    cursor = following
                }
                guard let chosen = (original.isLeapMonth == true ? leap ?? ordinary : ordinary) else { return nil }
                monthStart = chosen
            }
            if let range = c.range(of: .day, in: .month, for: monthStart),
               let candidate = c.date(byAdding: .day, value: min(original.day!, range.count) - 1, to: monthStart), candidate >= day { return candidate }
            guard let following = c.date(byAdding: unit, value: 1, to: period), following > period else { return nil }
            period = following
        }
        return nil
    }
    public static func occurrences(_ entry: Countdown, in interval: DateInterval, limit: Int = 400, systemZone: TimeZone = .current) -> [Date] {
        let c = calendar(entry, systemZone: systemZone)
        var result: [Date] = [], cursor = interval.start
        while result.count < limit, let d = next(entry, onOrAfter: cursor, systemZone: systemZone), d < interval.end {
            if d >= interval.start { result.append(d) }
            guard let following = c.date(byAdding: .day, value: 1, to: d), following > cursor else { break }
            cursor = following
        }
        return result
    }
    public static func days(from: Date, to: Date, timeZone: TimeZone) -> Int {
        var c = Calendar(identifier: .gregorian); c.timeZone = timeZone
        return c.dateComponents([.day], from: c.startOfDay(for: from), to: c.startOfDay(for: to)).day ?? 0
    }
    public static func distance(_ entry: Countdown, now: Date = .now, systemZone: TimeZone = .current) -> Int {
        let zone = entry.timeZone(system: systemZone)
        let target = next(entry, onOrAfter: now, systemZone: systemZone) ?? entry.anchorDate.date(in: zone) ?? now
        return days(from: now, to: target, timeZone: zone)
    }
    public static func elapsedDays(_ entry: Countdown, now: Date = .now, systemZone: TimeZone = .current) -> Int {
        let zone = entry.timeZone(system: systemZone)
        let value = days(from: entry.anchorDate.date(in: zone) ?? now, to: now, timeZone: zone)
        return value >= 0 && entry.includesStartDay == true ? value + 1 : value
    }
    public static func instant(_ entry: Countdown, on day: Date, systemZone: TimeZone = .current) -> Date? {
        let c = calendar(entry, systemZone: systemZone)
        let t = entry.targetTime ?? CountdownTime()
        // A spring-forward gap moves forward preserving minutes/seconds; a repeated
        // autumn time uses its first occurrence. Never use the device zone implicitly.
        return c.nextDate(after: c.startOfDay(for: day).addingTimeInterval(-1),
                          matching: DateComponents(hour: t.hour, minute: t.minute, second: t.second),
                          matchingPolicy: .nextTimePreservingSmallerComponents, repeatedTimePolicy: .first)
    }
    public static func nextInstant(_ entry: Countdown, onOrAfter now: Date, systemZone: TimeZone = .current) -> Date? {
        let c = calendar(entry, systemZone: systemZone)
        guard let day = next(entry, onOrAfter: now, systemZone: systemZone), let value = instant(entry, on: day, systemZone: systemZone) else { return nil }
        if value >= now { return value }
        guard entry.recurrence != .none, let tomorrow = c.date(byAdding: .day, value: 1, to: day),
              let following = next(entry, onOrAfter: tomorrow, systemZone: systemZone) else { return nil }
        return instant(entry, on: following, systemZone: systemZone)
    }
    public static func targetDescription(_ entry: Countdown) -> String {
        entry.anchorDate.description + (entry.targetTime.map { " " + $0.description } ?? "")
    }
    public static func milestoneDate(_ count: Int, entry: Countdown, systemZone: TimeZone = .current) -> Date? {
        guard (1...100_000).contains(count) else { return nil }
        let c = calendar(entry, systemZone: systemZone)
        guard let anchor = entry.anchorDate.date(in: c.timeZone) else { return nil }
        return c.date(byAdding: .day, value: count - (entry.includesStartDay == true ? 1 : 0), to: anchor)
    }
    public static func label(_ entry: Countdown, now: Date = .now) -> String {
        CountdownDisplayValue(entry, now: now).label
    }
}

/// A temporary presentation choice; it is never stored with the countdown.
public enum CountdownCountUnit: CaseIterable, Sendable {
    case days, weeks, months, years
    public var title: String {
        switch self { case .days: return "天"; case .weeks: return "周"; case .months: return "个月"; case .years: return "年" }
    }
    public var next: Self {
        switch self { case .days: return .weeks; case .weeks: return .months; case .months: return .years; case .years: return .days }
    }
}

/// Structured presentation shared by cards and widgets; the stored countdown is unchanged.
public struct CountdownCountComponent: Equatable, Sendable {
    public let value: Int
    public let unit: CountdownCountUnit
}

public struct CountdownDisplayValue: Equatable, Sendable {
    public enum Phase: Sendable { case upcoming, today, elapsed }
    public let phase: Phase
    public let days: Int
    public let time: String?
    public let target: Date
    public let date: CivilDate
    public let unit: CountdownCountUnit
    public let count: Int
    public let remainder: String?
    public let components: [CountdownCountComponent]
    public var status: String { phase == .today ? "就是今天" : phase == .elapsed ? "已经" : "还有" }
    public var label: String {
        if phase == .today && unit == .days { return status }
        return "\(status) \(count) \(unit.title)" + (remainder.map { " " + $0 } ?? "") + (time.map { " " + $0 } ?? "")
    }
    public init(_ entry: Countdown, now: Date = .now, systemZone: TimeZone = .current, unit: CountdownCountUnit = .days) {
        self.unit = unit
        let zone = entry.timeZone(system: systemZone)
        let anchor = entry.anchorDate.date(in: zone) ?? now
        let dayTime: String?
        if entry.targetTime != nil {
            target = CountdownDates.nextInstant(entry, onOrAfter: now, systemZone: systemZone)
                ?? CountdownDates.instant(entry, on: anchor, systemZone: systemZone) ?? anchor
            let interval = target.timeIntervalSince(now)
            let seconds = Int(interval > 0 ? ceil(interval) : floor(-interval))
            phase = interval >= 0 ? .upcoming : .elapsed
            days = seconds / 86_400
            dayTime = String(format: "%02d:%02d:%02d", seconds % 86_400 / 3_600, seconds % 3_600 / 60, seconds % 60)
        } else {
            target = CountdownDates.next(entry, onOrAfter: now, systemZone: systemZone) ?? anchor
            let distance = CountdownDates.days(from: now, to: target, timeZone: zone)
            let inclusive = distance <= 0 && entry.recurrence == .none && entry.includesStartDay == true
            phase = inclusive || distance < 0 ? .elapsed : distance == 0 ? .today : .upcoming
            days = inclusive ? CountdownDates.elapsedDays(entry, now: now, systemZone: systemZone) : abs(distance)
            dayTime = nil
        }
        date = CivilDate(target, timeZone: zone)
        switch unit {
        case .days:
            count = days; remainder = nil; time = dayTime
            components = [.init(value: days, unit: .days)]
        case .weeks:
            count = days / 7; remainder = days % 7 == 0 ? nil : "\(days % 7) 天"; time = dayTime
            components = [.init(value: days / 7, unit: .weeks), .init(value: days % 7, unit: .days)]
        case .months, .years:
            let calendar = CountdownDates.calendar(entry, systemZone: systemZone)
            let start: Date
            var end: Date
            if entry.targetTime != nil {
                start = min(now, target)
                let seconds = abs(target.timeIntervalSince(now)).rounded(phase == .upcoming ? .up : .down)
                end = start.addingTimeInterval(seconds)
            } else {
                start = calendar.startOfDay(for: min(now, target))
                end = calendar.startOfDay(for: max(now, target))
                if phase == .elapsed && entry.recurrence == .none && entry.includesStartDay == true {
                    end = calendar.date(byAdding: .day, value: 1, to: end) ?? end
                }
            }
            let fields: Set<Calendar.Component> = unit == .years ? [.year, .month, .day, .hour, .minute, .second] : [.month, .day, .hour, .minute, .second]
            let parts = calendar.dateComponents(fields, from: start, to: end)
            count = max(0, unit == .years ? parts.year ?? 0 : parts.month ?? 0)
            components = [.init(value: count, unit: unit)]
                + (unit == .years ? [.init(value: max(0, parts.month ?? 0), unit: .months)] : [])
                + [.init(value: max(0, parts.day ?? 0), unit: .days)]
            var rest: [String] = []
            if unit == .years, let months = parts.month, months > 0 { rest.append("\(months) 个月") }
            if let days = parts.day, days > 0 { rest.append("\(days) 天") }
            remainder = rest.isEmpty ? nil : rest.joined(separator: " ")
            time = entry.targetTime == nil ? nil : String(format: "%02d:%02d:%02d", parts.hour ?? 0, parts.minute ?? 0, parts.second ?? 0)
        }
    }
}

public struct CountdownNotice: Identifiable, Equatable, Sendable {
    public let id: String
    public let countdownID: UUID
    public let title: String
    public let fireAt: Date
    public let daysBefore: Int
    public var milestoneDay: Int? = nil
    public var anniversaryYear: Int? = nil
}
public enum CountdownNotifications {
    public static func plan(_ entries: [Countdown], now: Date = .now, limit: Int = 60, systemZone: TimeZone = .current) -> [CountdownNotice] {
        guard limit > 0 else { return [] }
        var result: [CountdownNotice] = []
        for entry in entries where entry.reminder.isEnabled {
            let c = CountdownDates.calendar(entry, systemZone: systemZone)
            let anchor = entry.anchorDate.date(in: c.timeZone) ?? now
            guard let end = c.date(byAdding: .year, value: max(1, limit + 1), to: max(now, anchor)),
                  let start = c.date(byAdding: .day, value: -1, to: now) else { continue }
            for date in CountdownDates.occurrences(entry, in: DateInterval(start: c.startOfDay(for: start), end: end), limit: limit + 8, systemZone: systemZone) {
                for offset in Set(entry.reminder.daysBefore) {
                    guard let day = c.date(byAdding: .day, value: -offset, to: date),
                          let fire = c.date(bySettingHour: entry.reminder.hour, minute: entry.reminder.minute, second: 0, of: day), fire > now else { continue }
                    result.append(CountdownNotice(id: "countdown.\(entry.id).\(CivilDate(date, timeZone: c.timeZone)).\(offset)", countdownID: entry.id, title: entry.title, fireAt: fire, daysBefore: offset))
                }
            }
            for count in Set(entry.reminder.milestones) {
                guard let day = CountdownDates.milestoneDate(count, entry: entry, systemZone: systemZone),
                      let fire = c.date(bySettingHour: entry.reminder.hour, minute: entry.reminder.minute, second: 0, of: day), fire > now else { continue }
                result.append(CountdownNotice(id: "countdown.\(entry.id).milestone.\(count)", countdownID: entry.id, title: entry.title,
                                              fireAt: fire, daysBefore: 0, milestoneDay: count))
            }
            if entry.reminder.anniversaries == true, let anchorYear = c.dateInterval(of: .year, for: anchor)?.start {
                var annual = entry; annual.recurrence = .yearly
                for date in CountdownDates.occurrences(annual, in: DateInterval(start: c.startOfDay(for: now), end: end), limit: limit + 1, systemZone: systemZone) {
                    guard let year = c.dateInterval(of: .year, for: date)?.start,
                          let years = c.dateComponents([.year], from: anchorYear, to: year).year, years > 0,
                          let fire = c.date(bySettingHour: entry.reminder.hour, minute: entry.reminder.minute, second: 0, of: date), fire > now else { continue }
                    result.append(CountdownNotice(id: "countdown.\(entry.id).anniversary.\(years)", countdownID: entry.id, title: entry.title,
                                                  fireAt: fire, daysBefore: 0, anniversaryYear: years))
                }
            }
            if let step = entry.reminder.dayInterval, (1...100_000).contains(step) {
                let elapsed = max(0, CountdownDates.elapsedDays(entry, now: now, systemZone: systemZone))
                // Include today's multiple if its reminder time has not passed yet.
                let first = max(1, (elapsed + step - 1) / step)
                for multiple in first..<(first + limit + 1) {
                    let count = multiple * step
                    guard let date = c.date(byAdding: .day, value: count - (entry.includesStartDay == true ? 1 : 0), to: anchor),
                          let fire = c.date(bySettingHour: entry.reminder.hour, minute: entry.reminder.minute, second: 0, of: date), fire > now else { continue }
                    result.append(CountdownNotice(id: "countdown.\(entry.id).milestone.\(count)", countdownID: entry.id, title: entry.title,
                                                  fireAt: fire, daysBefore: 0, milestoneDay: count))
                }
            }
        }
        // A milestone, anniversary and ordinary reminder can coincide. Keep their
        // descriptions together in one notification for this entry and instant.
        var unique: [UUID: [Date: CountdownNotice]] = [:]
        for notice in result {
            var combined = notice
            if let previous = unique[notice.countdownID]?[notice.fireAt] {
                combined = CountdownNotice(id: min(notice.id, previous.id), countdownID: notice.countdownID, title: notice.title,
                                           fireAt: notice.fireAt, daysBefore: min(notice.daysBefore, previous.daysBefore),
                                           milestoneDay: notice.milestoneDay ?? previous.milestoneDay,
                                           anniversaryYear: notice.anniversaryYear ?? previous.anniversaryYear)
            }
            unique[notice.countdownID, default: [:]][notice.fireAt] = combined
        }
        return Array(unique.values.flatMap(\.values).sorted { $0.fireAt == $1.fireAt ? $0.id < $1.id : $0.fireAt < $1.fireAt }.prefix(limit))
    }
}

/// One CloudKit record per user record; deletion is a persistent tombstone.
public struct CountdownRecord: Codable, Equatable, Identifiable, Sendable {
    public enum Kind: String, Codable, Sendable { case countdown, category }
    public var id: UUID
    public var kind: Kind
    public var updatedAt: Date
    public var revision: UUID
    public var deleted: Bool
    public var countdown: Countdown?
    public var category: CountdownCategory?
    public init(_ entry: Countdown, now: Date = .now) {
        id = entry.id; kind = .countdown; updatedAt = now; revision = UUID(); deleted = false; countdown = entry
    }
    public init(_ value: CountdownCategory, now: Date = .now) {
        id = value.id; kind = .category; updatedAt = now; revision = UUID(); deleted = false; category = value
    }
    public func wins(over other: Self) -> Bool {
        if updatedAt != other.updatedAt { return updatedAt > other.updatedAt }
        return revision.uuidString > other.revision.uuidString
    }
    public func validate() throws {
        guard (kind == .countdown && category == nil && (deleted || countdown?.id == id)) ||
              (kind == .category && countdown == nil && (deleted || category?.id == id)) else { throw ShikeError.message("倒数日记录格式无效。") }
        if let countdown, !deleted { try countdown.validate() }
        if let category, !deleted, category.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || category.name.count > 60 {
            throw ShikeError.message("分类名称须为 1–60 字。")
        }
    }
    public static func merge(_ local: [Self], _ incoming: [Self]) -> [Self] {
        var map = Dictionary(uniqueKeysWithValues: local.map { ($0.id, $0) })
        for record in incoming where map[record.id] == nil || record.wins(over: map[record.id]!) { map[record.id] = record }
        return map.values.sorted { $0.id.uuidString < $1.id.uuidString }
    }
}
