import XCTest
@testable import ShikeCore

final class CountdownConversionTests: XCTestCase {
    private func date(_ text: String) -> Date { ISO8601DateFormatter().date(from: text)! }
    func testFlightUsesLocalStartDateAndPreservesDetailsWithoutEnablingPrecision() throws {
        var draft = EventDraft(); draft.title = "上海飞北京"
        draft.start = date("2026-10-20T00:30:00+08:00"); draft.end = date("2026-10-20T02:30:00+08:00")
        draft.timeZoneIdentifier = "Asia/Shanghai"; draft.location = "虹桥机场"; draft.notes = "提前两小时出发"
        let result = try CountdownConversion.from(draft)
        XCTAssertEqual(result.anchorDate, CivilDate(year: 2026, month: 10, day: 20))
        XCTAssertEqual(result.timeZoneIdentifier, "Asia/Shanghai")
        XCTAssertEqual(CountdownDisplayValue(result, now: date("2026-10-17T12:00:00+08:00")).count, 3)
        XCTAssertTrue(result.notes.contains("00:30:00")); XCTAssertTrue(result.notes.contains("02:30:00"))
        XCTAssertTrue(result.notes.contains("虹桥机场")); XCTAssertTrue(result.notes.contains("提前两小时出发"))
        XCTAssertNil(result.targetTime); XCTAssertNil(result.categoryID); XCTAssertNil(result.cardColor)
        XCTAssertNil(result.includesStartDay); XCTAssertEqual(result.recurrence, .none); XCTAssertFalse(result.reminder.isEnabled)
        XCTAssertEqual(result.sourceIdentifier, CountdownConversion.sourceIdentifier(for: draft))
    }
    func testAllDayMultiDayAndPastEventsKeepTheirCivilStart() throws {
        let event = CalendarEventSnapshot(eventID: "a", itemID: "a", calendarID: "work", title: "旅行",
            start: date("2026-10-20T00:00:00+08:00"), end: date("2026-10-23T00:00:00+08:00"), allDay: true, timeZone: "Asia/Shanghai")
        let result = try CountdownConversion.from(event, fallbackZone: TimeZone(identifier: "America/Los_Angeles")!)
        XCTAssertEqual(result.anchorDate.description, "2026-10-20")
        XCTAssertTrue(result.notes.contains("2026-10-22")); XCTAssertFalse(result.notes.contains("2026-10-23"))
        XCTAssertEqual(CountdownDisplayValue(result, now: date("2026-10-24T12:00:00+08:00")).phase, .elapsed)
        var next = event; next.start = next.start.addingTimeInterval(86400); next.end = next.end.addingTimeInterval(86400)
        XCTAssertNotEqual(result.sourceIdentifier, try CountdownConversion.from(next).sourceIdentifier)
        XCTAssertEqual(result.sourceIdentifier, try CountdownConversion.from(event).sourceIdentifier)
    }
    func testEndDateAndCalendarAreNotRequiredAndOldDataCanDecode() throws {
        var draft = EventDraft(); draft.title = "出发"
        XCTAssertThrowsError(try CountdownConversion.from(draft))
        draft.start = date("2026-10-20T08:00:00+08:00")
        let converted = try CountdownConversion.from(draft)
        let data = try JSONEncoder().encode(converted)
        XCTAssertEqual(try JSONDecoder().decode(Countdown.self, from: data), converted)
        var old = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        old.removeValue(forKey: "sourceIdentifier")
        XCTAssertNil(try JSONDecoder().decode(Countdown.self, from: JSONSerialization.data(withJSONObject: old)).sourceIdentifier)
    }
}
