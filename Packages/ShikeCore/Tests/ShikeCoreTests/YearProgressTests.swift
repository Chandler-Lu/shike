import XCTest
@testable import ShikeCore

final class YearProgressTests: XCTestCase {
    private let shanghai = TimeZone(identifier: "Asia/Shanghai")!
    private func instant(_ value: String) -> Date { ISO8601DateFormatter().date(from: value)! }

    func testOnlyCompletedDaysAndMatchingFraction() {
        let morning = YearProgress(now: instant("2026-10-14T00:00:00+08:00"), timeZone: shanghai)
        let evening = YearProgress(now: instant("2026-10-14T23:59:59+08:00"), timeZone: shanghai)
        XCTAssertEqual(morning, evening)
        XCTAssertEqual(morning.year, 2026)
        XCTAssertEqual(morning.elapsedDays, 286)
        XCTAssertEqual(morning.totalDays, 365)
        XCTAssertEqual(morning.fraction, 286.0 / 365, accuracy: 0.000001)
    }

    func testNewYearResetsAtLocalMidnight() {
        let end = YearProgress(now: instant("2026-12-31T23:59:59+08:00"), timeZone: shanghai)
        let start = YearProgress(now: instant("2027-01-01T00:00:00+08:00"), timeZone: shanghai)
        XCTAssertEqual(end.elapsedDays, 364)
        XCTAssertLessThan(end.fraction, 1)
        XCTAssertEqual(start.year, 2027)
        XCTAssertEqual(start.elapsedDays, 0)
        XCTAssertEqual(start.fraction, 0)
    }

    func testLeapDayAndGregorianCenturyRules() {
        let leapDay = YearProgress(now: instant("2024-02-29T12:00:00+08:00"), timeZone: shanghai)
        let march = YearProgress(now: instant("2024-03-01T00:00:00+08:00"), timeZone: shanghai)
        XCTAssertEqual(leapDay.totalDays, 366)
        XCTAssertEqual(leapDay.elapsedDays, 59)
        XCTAssertEqual(march.elapsedDays, 60)
        let end = YearProgress(now: instant("2024-12-31T23:59:59+08:00"), timeZone: shanghai)
        XCTAssertEqual(end.elapsedDays, 365)
        XCTAssertEqual(end.fraction, 365.0 / 366, accuracy: 0.000001)
        XCTAssertEqual(YearProgress(now: instant("2000-03-01T00:00:00+08:00"), timeZone: shanghai).totalDays, 366)
        XCTAssertEqual(YearProgress(now: instant("2100-03-01T00:00:00+08:00"), timeZone: shanghai).totalDays, 365)
    }

    func testSameInstantCanBelongToDifferentYears() {
        let date = instant("2027-01-01T00:00:00+08:00")
        let local = YearProgress(now: date, timeZone: shanghai)
        let west = YearProgress(now: date, timeZone: TimeZone(identifier: "America/Los_Angeles")!)
        XCTAssertEqual(local.year, 2027)
        XCTAssertEqual(local.elapsedDays, 0)
        XCTAssertEqual(west.year, 2026)
        XCTAssertEqual(west.elapsedDays, 364)
    }

    func testDSTCountsCalendarDaysRatherThanHours() {
        let zone = TimeZone(identifier: "America/Los_Angeles")!
        for (before, after, hours) in [
            ("2026-03-08T00:00:00-08:00", "2026-03-09T00:00:00-07:00", 23),
            ("2026-11-01T00:00:00-07:00", "2026-11-02T00:00:00-08:00", 25)
        ] {
            let a = instant(before), b = instant(after)
            XCTAssertEqual(b.timeIntervalSince(a), Double(hours * 3600))
            let first = YearProgress(now: a, timeZone: zone)
            let second = YearProgress(now: b, timeZone: zone)
            XCTAssertEqual(second.elapsedDays - first.elapsedDays, 1)
            XCTAssertEqual(second.totalDays, 365)
        }
    }
}
