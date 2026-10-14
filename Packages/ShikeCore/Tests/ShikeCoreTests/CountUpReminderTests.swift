import XCTest
@testable import ShikeCore

final class CountUpReminderTests: XCTestCase {
    private let zone = TimeZone(identifier: "Asia/Shanghai")!
    private func date(_ year: Int, _ month: Int, _ day: Int) -> Date { CivilDate(year: year, month: month, day: day).date(in: zone)! }
    private func entry(_ year: Int, _ month: Int, _ day: Int) -> Countdown {
        var value = Countdown(title: "纪念日", date: CivilDate(year: year, month: month, day: day))
        value.timeZoneIdentifier = zone.identifier
        return value
    }
    func testAnnualReminderDoesNotChangeCountUpAndHandlesLeapDay() throws {
        var value = entry(2024, 2, 29); value.reminder.anniversaries = true
        let notices = CountdownNotifications.plan([value], now: date(2025, 1, 1), limit: 4)
        XCTAssertEqual(notices.map(\.anniversaryYear), [1, 2, 3, 4])
        XCTAssertEqual(CivilDate(notices[0].fireAt, timeZone: zone), CivilDate(year: 2025, month: 2, day: 28))
        XCTAssertEqual(CivilDate(notices[3].fireAt, timeZone: zone), CivilDate(year: 2028, month: 2, day: 29))
        XCTAssertEqual(value.recurrence, .none)
        value.includesStartDay = true
        XCTAssertEqual(CountdownNotifications.plan([value], now: date(2025, 1, 1), limit: 4), notices)
    }
    func testLunarAnniversaryUsesItsCalendarAndExcludesYearZero() {
        var value = entry(2023, 3, 22); value.calendar = .chinese; value.reminder.anniversaries = true
        let first = CountdownNotifications.plan([value], now: date(2023, 3, 21), limit: 1).first!
        XCTAssertEqual(first.anniversaryYear, 1)
        XCTAssertEqual(CivilDate(first.fireAt, timeZone: zone), CivilDate(year: 2024, month: 3, day: 10))
    }
    func testIntervalIncludesUpcomingTimeTodayAndSkipsDeliveredTime() {
        var value = entry(2026, 1, 1); value.reminder.dayInterval = 100
        let morning = date(2026, 4, 11).addingTimeInterval(8 * 3600)
        let notices = CountdownNotifications.plan([value], now: morning, limit: 3)
        XCTAssertEqual(notices.map(\.milestoneDay), [100, 200, 300])
        XCTAssertEqual(notices.first?.fireAt, date(2026, 4, 11).addingTimeInterval(9 * 3600))
        XCTAssertEqual(CountdownNotifications.plan([value], now: notices[0].fireAt, limit: 1).first?.milestoneDay, 200)
        value.includesStartDay = true
        XCTAssertEqual(CountdownNotifications.plan([value], now: date(2026, 4, 9), limit: 1).first?.fireAt, date(2026, 4, 10).addingTimeInterval(9 * 3600))
    }
    func testIntervalsAndExplicitMilestonesCoalesceWithAnniversaries() {
        var value = entry(2024, 1, 1)
        value.recurrence = .yearly; value.reminder.daysBefore = [0]
        value.reminder.anniversaries = true; value.reminder.dayInterval = 366; value.reminder.milestones = [366]
        let notices = CountdownNotifications.plan([value], now: date(2025, 1, 1), limit: 8)
        let first = notices.first!
        XCTAssertEqual(first.anniversaryYear, 1); XCTAssertEqual(first.milestoneDay, 366)
        XCTAssertEqual(notices.filter { $0.fireAt == first.fireAt }.count, 1)
        var other = value; other.id = UUID()
        let separate = CountdownNotifications.plan([value, other], now: date(2025, 1, 1), limit: 8)
        XCTAssertEqual(separate.filter { $0.fireAt == first.fireAt }.count, 2)
    }
    func testIntervalAcrossDSTAndRollingQueueCap() {
        let la = TimeZone(identifier: "America/Los_Angeles")!
        var value = entry(2026, 3, 6); value.timeZoneIdentifier = la.identifier; value.reminder.dayInterval = 1
        let start = value.anchorDate.date(in: la)!
        let notices = CountdownNotifications.plan([value], now: start)
        XCTAssertEqual(notices.count, 60)
        XCTAssertEqual(notices[1].fireAt.timeIntervalSince(notices[0].fireAt), 23 * 3600)
        XCTAssertEqual(CountdownDates.days(from: start, to: notices[0].fireAt, timeZone: la), 1)
        var calendar = Calendar(identifier: .gregorian); calendar.timeZone = la
        XCTAssertTrue(notices.allSatisfy { calendar.component(.hour, from: $0.fireAt) == 9 })
        XCTAssertEqual(CountdownNotifications.plan([value], now: notices.last!.fireAt, limit: 1).first?.milestoneDay, 61)
    }
    func testNewOptionsAreOptInValidatedAndSurviveSerialization() throws {
        let old = try JSONDecoder().decode(CountdownReminder.self, from: Data(#"{"daysBefore":[],"hour":9,"minute":0}"#.utf8))
        XCTAssertNil(old.anniversaries); XCTAssertNil(old.dayInterval); XCTAssertFalse(old.isEnabled)
        var value = entry(2020, 5, 20)
        value.reminder.anniversaries = true; value.reminder.dayInterval = 250
        XCTAssertTrue(value.reminder.isEnabled)
        XCTAssertEqual(try JSONDecoder().decode(Countdown.self, from: JSONEncoder().encode(value)), value)
        for invalid in [0, -100, 100001] { value.reminder.dayInterval = invalid; XCTAssertThrowsError(try value.validate()) }
        value.reminder.dayInterval = nil; value.reminder.anniversaries = false
        XCTAssertTrue(CountdownNotifications.plan([value], now: date(2026, 1, 1)).isEmpty)
    }
}
