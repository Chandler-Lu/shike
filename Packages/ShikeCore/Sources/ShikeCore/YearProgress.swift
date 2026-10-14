import Foundation

/// Completed Gregorian calendar days, rather than elapsed 24-hour intervals.
public struct YearProgress: Equatable, Sendable {
    public let year: Int
    public let elapsedDays: Int
    public let totalDays: Int
    public var fraction: Double { Double(elapsedDays) / Double(totalDays) }

    public init(now: Date = .now, timeZone: TimeZone = .current) {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        year = calendar.component(.year, from: now)
        totalDays = calendar.range(of: .day, in: .year, for: now)?.count ?? 365
        elapsedDays = min(totalDays - 1, max(0, (calendar.ordinality(of: .day, in: .year, for: now) ?? 1) - 1))
    }
}
