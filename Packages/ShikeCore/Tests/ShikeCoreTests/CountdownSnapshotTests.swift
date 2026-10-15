import XCTest
@testable import ShikeCore

final class CountdownSnapshotTests: XCTestCase {
    let zone = TimeZone(identifier: "Asia/Shanghai")!
    func testDisplaySnapshotOmitsPrivateFieldsAndKeepsDateSemantics() throws {
        var value = Countdown(title: "一起看书", date: CivilDate(year: 2020, month: 2, day: 29))
        value.notes = "PRIVATE-NOTES"; value.reminder = CountdownReminder(daysBefore: [0], anniversaries: true, dayInterval: 100)
        value.targetTime = CountdownTime(hour: 13, minute: 14, second: 52); value.recurrence = .yearly
        value.includesStartDay = true; value.timeZoneIdentifier = zone.identifier
        let snapshot = CountdownSnapshot(entries: [value], revision: 1)
        let data = try JSONEncoder().encode(snapshot), text = String(decoding: data, as: UTF8.self)
        XCTAssertFalse(text.contains("PRIVATE-NOTES")); XCTAssertFalse(text.contains("reminder")); XCTAssertFalse(text.contains("api"))
        let decoded = try JSONDecoder().decode(CountdownSnapshot.self, from: data); try decoded.validate()
        let restored = try XCTUnwrap(decoded.items.first?.countdown)
        XCTAssertEqual(restored.targetTime, value.targetTime); XCTAssertEqual(restored.recurrence, .yearly)
        XCTAssertEqual(restored.includesStartDay, true)
        XCTAssertEqual(CountdownDates.label(restored), CountdownDates.label(value))
    }
    func testFilterRenameDeleteAndOrdering() {
        var group = CountdownCategory(name: "生活")
        let now = CivilDate(year: 2026, month: 10, day: 14).date(in: zone)!
        var past = Countdown(title: "过去", date: CivilDate(year: 2026, month: 10, day: 13))
        var future = Countdown(title: "未来", date: CivilDate(year: 2026, month: 10, day: 18))
        past.categoryID = group.id; future.pinned = true
        var snapshot = CountdownSnapshot(entries: [past, future], categories: [group])
        XCTAssertEqual(snapshot.entries(in: "all", now: now, systemZone: zone).map(\.title), ["未来", "过去"])
        XCTAssertEqual(snapshot.entries(in: group.id.uuidString).map(\.title), ["过去"])
        XCTAssertEqual(snapshot.entries(in: "none").map(\.title), ["未来"])
        group.name = "个人生活"; snapshot.categories = [group]
        XCTAssertEqual(snapshot.name(for: group.id.uuidString), "个人生活")
        snapshot = CountdownSnapshot(entries: [past, future], categories: [])
        XCTAssertNil(snapshot.name(for: group.id.uuidString)); XCTAssertTrue(snapshot.entries(in: group.id.uuidString).isEmpty)
        XCTAssertEqual(snapshot.entries(in: "none").count, 2)
    }
    func testRejectsOldMessagesAndInvalidSnapshots() throws {
        var snapshot = CountdownSnapshot(revision: 10)
        XCTAssertFalse(snapshot.accepts(CountdownSnapshot(revision: 9)))
        XCTAssertFalse(snapshot.accepts(snapshot)); XCTAssertTrue(snapshot.accepts(CountdownSnapshot(revision: 11)))
        snapshot.version = 2; XCTAssertThrowsError(try snapshot.validate())
    }
    func testTimelineUsesCalendarDaysAcrossDSTAndExactTarget() {
        let zone = TimeZone(identifier: "America/New_York")!
        let now = CivilDate(year: 2026, month: 3, day: 8).date(in: zone)!
        var entry = Countdown(title: "周年", date: CivilDate(year: 2026, month: 3, day: 8))
        entry.timeZoneIdentifier = zone.identifier; entry.targetTime = CountdownTime(hour: 13); entry.recurrence = .yearly
        let dates = CountdownPresentation.timelineDates([entry], now: now, systemZone: zone)
        XCTAssertTrue(dates.contains(CivilDate(year: 2026, month: 3, day: 9).date(in: zone)!))
        XCTAssertTrue(dates.contains(now.addingTimeInterval(23 * 3600)))
        XCTAssertTrue(dates.contains(CountdownDates.nextInstant(entry, onOrAfter: now)!.addingTimeInterval(1)))
        XCTAssertEqual(dates, Array(Set(dates)).sorted()); XCTAssertLessThanOrEqual(dates.count, 70)
    }
    func testDeepLinksRoundTripAndRejectOtherActions() {
        let route = CountdownRoute(group: UUID().uuidString, id: UUID())
        XCTAssertEqual(CountdownRoute(url: route.url), route)
        XCTAssertNil(CountdownRoute(url: URL(string: "https://countdowns?group=all")!))
        XCTAssertNil(CountdownRoute(url: URL(string: "shike://countdowns?group=wrong")!))
        XCTAssertNil(CountdownRoute(url: URL(string: "shike://countdowns?id=wrong")!))
    }

    func testWidgetReservesBothDirectionsAndSmallSecondary() {
        let now = CivilDate(year: 2026, month: 10, day: 14).date(in: zone)!
        var entries = (1...8).map { offset in
            Countdown(title: "期待\(offset)", date: CivilDate(year: 2026, month: 10, day: 14 + offset))
        }
        var memory = Countdown(title: "在一起", date: CivilDate(year: 2022, month: 11, day: 23))
        memory.pinned = true; entries.append(memory)
        let selection = CountdownWidgetSelection(entries, limitPerSection: 1, now: now, systemZone: zone)
        XCTAssertEqual(selection.primary?.id, memory.id)
        XCTAssertEqual(selection.secondary?.id, entries.first?.id)
        XCTAssertEqual(selection.upcoming.map(\.title), ["期待1"])
        XCTAssertEqual(selection.elapsed.map(\.title), ["在一起"])
        XCTAssertEqual(selection.remainingCount, 7)
    }

    func testWidgetUsesFullCapacityForOneDirectionAndStablePinOrdering() {
        let now = CivilDate(year: 2026, month: 10, day: 14).date(in: zone)!
        let older = Countdown(title: "更早", date: CivilDate(year: 2024, month: 1, day: 1))
        var recent = Countdown(title: "最近", date: CivilDate(year: 2026, month: 10, day: 13))
        var pinned = Countdown(title: "置顶", date: CivilDate(year: 2020, month: 1, day: 1)); pinned.pinned = true
        recent.includesStartDay = true
        let result = CountdownWidgetSelection([older, recent, pinned], limitPerSection: 1, now: now, systemZone: zone)
        XCTAssertTrue(result.upcoming.isEmpty)
        XCTAssertEqual(result.elapsed.map(\.id), [pinned.id, recent.id])
        XCTAssertEqual(result.secondary?.id, recent.id)
        let empty = CountdownWidgetSelection([], limitPerSection: 3, now: now, systemZone: zone)
        XCTAssertNil(empty.primary); XCTAssertNil(empty.secondary); XCTAssertEqual(empty.visibleCount, 0)
        let single = CountdownWidgetSelection([recent], limitPerSection: 3, now: now, systemZone: zone)
        XCTAssertNil(single.secondary); XCTAssertEqual(single.remainingCount, 0)
    }

    func testSpecifiedPairKeepsChosenOrderRegardlessOfDatesAndPins() {
        let now = CivilDate(year: 2026, month: 10, day: 14).date(in: zone)!
        let near = Countdown(title: "三天后", date: CivilDate(year: 2026, month: 10, day: 17))
        var far = Countdown(title: "十天后", date: CivilDate(year: 2026, month: 10, day: 24)); far.pinned = true
        let recent = Countdown(title: "昨天", date: CivilDate(year: 2026, month: 10, day: 13))
        var older = Countdown(title: "十天前", date: CivilDate(year: 2026, month: 10, day: 4)); older.pinned = true
        for (a, b) in [(far, near), (older, near), (older, recent)] {
            for pair in [[a, b], [b, a]] {
                let result = CountdownWidgetSelection(pair, limitPerSection: 1, now: now, systemZone: zone, preserveOrder: true)
                XCTAssertEqual(result.primary?.id, pair[0].id)
                XCTAssertEqual(result.secondary?.id, pair[1].id)
                XCTAssertEqual(result.visibleCount, 2)
                XCTAssertEqual(result.remainingCount, 0)
            }
        }
    }

    func testSpecifiedPairKeepsChosenOrderAfterExactTargetPassesAndAtMidnight() {
        let day = CivilDate(year: 2026, month: 10, day: 14).date(in: zone)!
        var morning = Countdown(title: "上午", date: CivilDate(year: 2026, month: 10, day: 14))
        morning.timeZoneIdentifier = zone.identifier; morning.targetTime = CountdownTime(hour: 10, minute: 0)
        var afternoon = morning; afternoon.id = UUID(); afternoon.title = "下午"; afternoon.targetTime = CountdownTime(hour: 14, minute: 0)
        let values = [afternoon, morning]
        for hour in [9, 11, 15] {
            let result = CountdownWidgetSelection(values, limitPerSection: 1, now: day.addingTimeInterval(Double(hour) * 3600), systemZone: zone, preserveOrder: true)
            XCTAssertEqual(result.primary?.id, afternoon.id)
            XCTAssertEqual(result.secondary?.id, morning.id)
        }
        let today = Countdown(title: "今天", date: CivilDate(year: 2026, month: 10, day: 14))
        let tomorrow = Countdown(title: "明天", date: CivilDate(year: 2026, month: 10, day: 15))
        for offset in [86399.0, 86400.0] {
            let result = CountdownWidgetSelection([today, tomorrow], limitPerSection: 1, now: day.addingTimeInterval(offset), systemZone: zone, preserveOrder: true)
            XCTAssertEqual(result.primary?.id, today.id)
            XCTAssertEqual(result.secondary?.id, tomorrow.id)
        }
    }

    func testWidgetTodayInclusiveAndRecurringBirthdayClassification() {
        let now = CivilDate(year: 2026, month: 10, day: 14).date(in: zone)!
        let today = Countdown(title: "今天", date: CivilDate(year: 2026, month: 10, day: 14))
        var inclusive = today; inclusive.id = UUID(); inclusive.includesStartDay = true
        var birthday = Countdown(title: "生日", date: CivilDate(year: 1998, month: 1, day: 6)); birthday.recurrence = .yearly
        XCTAssertEqual(CountdownDisplayValue(today, now: now, systemZone: zone).phase, .today)
        let count = CountdownDisplayValue(inclusive, now: now, systemZone: zone)
        XCTAssertEqual(count.phase, .elapsed); XCTAssertEqual(count.days, 1); XCTAssertEqual(count.label, "已经 1 天")
        let next = CountdownDisplayValue(birthday, now: now, systemZone: zone)
        XCTAssertEqual(next.phase, .upcoming); XCTAssertEqual(next.date, CivilDate(year: 2027, month: 1, day: 6))
        birthday.calendar = .chinese
        let lunar = CountdownDisplayValue(birthday, now: now, systemZone: zone)
        XCTAssertEqual(lunar.phase, .upcoming); XCTAssertGreaterThanOrEqual(lunar.target, now)
        let split = CountdownWidgetSelection([today, inclusive, birthday], limitPerSection: 3, now: now, systemZone: zone)
        XCTAssertEqual(Set(split.upcoming.map(\.id)), [today.id, birthday.id])
        XCTAssertEqual(split.elapsed.map(\.id), [inclusive.id])
    }

    func testExactTimeChangesSectionEvenWithinSameDay() {
        let morning = CivilDate(year: 2026, month: 10, day: 14).date(in: zone)!
        var event = Countdown(title: "出发", date: CivilDate(year: 2026, month: 10, day: 14))
        event.timeZoneIdentifier = zone.identifier; event.targetTime = CountdownTime(hour: 12, minute: 30, second: 17)
        let target = CountdownDates.instant(event, on: morning)!
        let before = CountdownDisplayValue(event, now: target.addingTimeInterval(-1))
        XCTAssertEqual(before.phase, .upcoming); XCTAssertEqual(before.time, "00:00:01")
        let after = CountdownDisplayValue(event, now: target.addingTimeInterval(1))
        XCTAssertEqual(after.phase, .elapsed); XCTAssertEqual(after.time, "00:00:01")
        XCTAssertEqual(CountdownWidgetSelection([event], limitPerSection: 1, now: target.addingTimeInterval(1)).elapsed.count, 1)
        XCTAssertTrue(CountdownPresentation.timelineDates([event], now: morning).contains(target.addingTimeInterval(1)))
        event.recurrence = .yearly
        XCTAssertEqual(CountdownDisplayValue(event, now: target.addingTimeInterval(1)).phase, .upcoming)
    }

    func testNaturalDayClassificationChangesAtLocalMidnight() {
        let midnight = CivilDate(year: 2026, month: 10, day: 15).date(in: zone)!
        var value = Countdown(title: "日子", date: CivilDate(year: 2026, month: 10, day: 14))
        value.timeZoneIdentifier = zone.identifier
        XCTAssertEqual(CountdownDisplayValue(value, now: midnight.addingTimeInterval(-1)).phase, .today)
        XCTAssertEqual(CountdownDisplayValue(value, now: midnight).label, "已经 1 天")
        XCTAssertTrue(CountdownPresentation.timelineDates([value], now: midnight.addingTimeInterval(-60)).contains(midnight))
        let future = Countdown(title: "远方", date: CivilDate(year: 2062, month: 3, day: 9))
        XCTAssertEqual(CountdownDisplayValue(future, now: midnight.addingTimeInterval(-86_400), systemZone: zone).days, 12_930)
        let tomorrow = Countdown(title: "明天", date: CivilDate(year: 2026, month: 10, day: 15))
        let lateEvening = midnight.addingTimeInterval(-60)
        let selection = CountdownWidgetSelection([tomorrow, value], limitPerSection: 1, now: lateEvening, systemZone: zone)
        XCTAssertEqual(selection.upcoming.first?.id, value.id)
    }
}
