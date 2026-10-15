import Foundation

/// Display-only data: never carries notes, reminders, CloudKit state, or API credentials.
public struct CountdownDisplayItem: Codable, Equatable, Identifiable, Sendable {
    public var id: UUID
    public var title: String
    public var anchorDate: CivilDate
    public var calendar: CountdownCalendar
    public var recurrence: CountdownRepeat
    public var timeZoneIdentifier: String?
    public var categoryID: UUID?
    public var pinned: Bool
    public var targetTime: CountdownTime?
    public var includesStartDay: Bool?
    public init(_ value: Countdown) {
        id = value.id; title = value.title; anchorDate = value.anchorDate; calendar = value.calendar
        recurrence = value.recurrence; timeZoneIdentifier = value.timeZoneIdentifier; categoryID = value.categoryID
        pinned = value.pinned; targetTime = value.targetTime; includesStartDay = value.includesStartDay
    }
    public var countdown: Countdown {
        var value = Countdown(id: id, title: title, date: anchorDate)
        value.calendar = calendar; value.recurrence = recurrence; value.timeZoneIdentifier = timeZoneIdentifier
        value.categoryID = categoryID; value.pinned = pinned; value.targetTime = targetTime; value.includesStartDay = includesStartDay
        return value
    }
}

public struct CountdownSnapshot: Codable, Equatable, Sendable {
    public var version = 1
    public var revision: Int64
    public var generatedAt: Date
    public var categories: [CountdownCategory]
    public var items: [CountdownDisplayItem]
    public init(entries: [Countdown] = [], categories: [CountdownCategory] = [], revision: Int64 = 0, generatedAt: Date = .now) {
        self.revision = revision; self.generatedAt = generatedAt
        self.categories = categories.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        let ids = Set(categories.map(\.id))
        items = entries.map { value in
            var item = CountdownDisplayItem(value)
            if let id = item.categoryID, !ids.contains(id) { item.categoryID = nil }
            return item
        }.sorted { $0.id.uuidString < $1.id.uuidString }
    }
    public func validate() throws {
        guard version == 1, revision >= 0, Set(items.map(\.id)).count == items.count,
              Set(categories.map(\.id)).count == categories.count,
              categories.allSatisfy({ !$0.name.isEmpty && $0.name.count <= 100 }) else {
            throw ShikeError.message("倒数日展示数据无效，请重新同步。")
        }
        for item in items { try item.countdown.validate() }
    }
    public func name(for group: String) -> String? {
        if group == "all" { return "全部日子" }
        if group == "none" { return "未分类" }
        return categories.first { $0.id.uuidString == group }?.name
    }
    public func entries(in group: String, now: Date = .now, systemZone: TimeZone = .current) -> [Countdown] {
        guard name(for: group) != nil else { return [] }
        return CountdownPresentation.sorted(items.filter {
            group == "all" || (group == "none" ? $0.categoryID == nil : $0.categoryID?.uuidString == group)
        }.map(\.countdown), now: now, systemZone: systemZone)
    }
    public func hasSameContent(as other: Self) -> Bool { categories == other.categories && items == other.items }
    public func accepts(_ incoming: Self) -> Bool { incoming.version == 1 && incoming.revision > revision }
}

public enum CountdownPresentation {
    public static func sorted(_ entries: [Countdown], now: Date = .now, systemZone: TimeZone = .current) -> [Countdown] {
        entries.sorted {
            if $0.pinned != $1.pinned { return $0.pinned }
            let a = CountdownDates.distance($0, now: now, systemZone: systemZone)
            let b = CountdownDates.distance($1, now: now, systemZone: systemZone)
            if a != b { return a >= 0 && b < 0 || (a >= 0) == (b >= 0) && abs(a) < abs(b) }
            return $0.id.uuidString < $1.id.uuidString
        }
    }
    /// Bounded predictable changes, including local midnights and exact-time recurrences.
    public static func timelineDates(_ entries: [Countdown], now: Date, systemZone: TimeZone = .current) -> [Date] {
        var dates: Set<Date> = [now]
        let end = now.addingTimeInterval(7 * 86_400)
        let zones = Set(entries.map { $0.timeZone(system: systemZone).identifier }).union([systemZone.identifier])
        for zone in zones {
            var c = Calendar(identifier: .gregorian); c.timeZone = TimeZone(identifier: zone) ?? systemZone
            var day = c.startOfDay(for: now)
            for _ in 0..<8 {
                guard let next = c.date(byAdding: .day, value: 1, to: day), next <= end else { break }
                dates.insert(next); day = next
            }
        }
        for entry in entries where entry.targetTime != nil {
            var cursor = now
            for _ in 0..<8 {
                guard let target = CountdownDates.nextInstant(entry, onOrAfter: cursor, systemZone: systemZone), target < end else { break }
                cursor = target.addingTimeInterval(1); dates.insert(cursor)
            }
        }
        return Array(dates.sorted().prefix(70))
    }
}

/// Reserve space for both directions instead of truncating a future-first list.
/// This selection is local to widgets; phone and Watch list ordering stays intact.
public struct CountdownWidgetSelection: Sendable {
    public let upcoming: [Countdown]
    public let elapsed: [Countdown]
    public let primary: Countdown?
    public let secondary: Countdown?
    public let totalCount: Int
    public var visibleCount: Int { upcoming.count + elapsed.count }
    public var remainingCount: Int { max(0, totalCount - visibleCount) }
    public init(_ entries: [Countdown], limitPerSection: Int, now: Date, systemZone: TimeZone = .current, preserveOrder: Bool = false) {
        let ordered = preserveOrder ? entries : CountdownPresentation.sorted(entries, now: now, systemZone: systemZone)
        let values = Dictionary(uniqueKeysWithValues: entries.map { ($0.id, CountdownDisplayValue($0, now: now, systemZone: systemZone)) })
        func distance(_ entry: Countdown) -> Double {
            let value = values[entry.id]!
            // Natural-day events remain "today" all day, even closer to tomorrow's midnight.
            if entry.targetTime == nil {
                return Double(abs(CountdownDates.days(from: now, to: value.target, timeZone: entry.timeZone(system: systemZone)))) * 86_400
            }
            return abs(value.target.timeIntervalSince(now))
        }
        func section(_ elapsed: Bool) -> [Countdown] {
            let matching = ordered.filter { (values[$0.id]!.phase == .elapsed) == elapsed }
            if preserveOrder { return matching }
            return matching.sorted {
                if $0.pinned != $1.pinned { return $0.pinned }
                let a = distance($0), b = distance($1)
                return a != b ? a < b : $0.id.uuidString < $1.id.uuidString
            }
        }
        let future = section(false), past = section(true)
        let limit = max(0, limitPerSection)
        upcoming = Array(future.prefix(past.isEmpty ? limit * 2 : limit))
        elapsed = Array(past.prefix(future.isEmpty ? limit * 2 : limit))
        totalCount = entries.count
        primary = ordered.first
        if preserveOrder {
            secondary = ordered.dropFirst().first
        } else if let first = ordered.first {
            secondary = (values[first.id]!.phase == .elapsed ? future.first : past.first)
                ?? ordered.first { $0.id != first.id }
        } else { secondary = nil }
    }
}

public struct CountdownRoute: Equatable, Sendable {
    public let group: String
    public let id: UUID?
    public init(group: String = "all", id: UUID? = nil) { self.group = group; self.id = id }
    public init?(url: URL) {
        guard url.scheme == "shike", url.host == "countdowns", url.path.isEmpty || url.path == "/",
              let parts = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return nil }
        let group = parts.queryItems?.first { $0.name == "group" }?.value ?? "all"
        guard group == "all" || group == "none" || UUID(uuidString: group) != nil else { return nil }
        let rawID = parts.queryItems?.first { $0.name == "id" }?.value
        if let rawID, UUID(uuidString: rawID) == nil { return nil }
        self.init(group: UUID(uuidString: group)?.uuidString ?? group, id: rawID.flatMap(UUID.init(uuidString:)))
    }
    public var url: URL {
        var parts = URLComponents(); parts.scheme = "shike"; parts.host = "countdowns"
        parts.queryItems = [URLQueryItem(name: "group", value: group)]
        if let id { parts.queryItems?.append(URLQueryItem(name: "id", value: id.uuidString)) }
        return parts.url!
    }
}
