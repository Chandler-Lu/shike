import XCTest
import EventKit
import ShikeCore
@testable import Shike

final class CalendarInteractionTests: XCTestCase {
    @MainActor func testNativeDeletingCurrentAndFutureKeepsEarlierAndUnrelatedEvents() async throws {
        #if targetEnvironment(simulator)
        let service = CalendarService(useDemo: false); try await service.requestAccess()
        let source = try XCTUnwrap(service.store.sources.first(where: { $0.sourceType == .local }) ?? service.store.defaultCalendarForNewEvents?.source)
        for allDay in [false, true] {
            let group = EKCalendar(for: .event, eventStore: service.store); group.title = "Shike Future Deletion Test"; group.source = source
            try service.store.saveCalendar(group, commit: true)
            defer { try? service.store.removeCalendar(group, commit: true) }
            let calendar = Calendar.current, day = Calendar.current.startOfDay(for: .now)
            let event = EKEvent(eventStore: service.store); event.calendar = group; event.title = "重复日程"
            event.startDate = day.addingTimeInterval(allDay ? 0 : 36000)
            event.endDate = allDay ? calendar.date(byAdding: .day, value: 1, to: day)! : event.startDate.addingTimeInterval(3600)
            event.isAllDay = allDay
            event.recurrenceRules = [EKRecurrenceRule(recurrenceWith: .daily, interval: 1, end: EKRecurrenceEnd(occurrenceCount: 3))]
            try service.store.save(event, span: .thisEvent)
            let other = EKEvent(eventStore: service.store); other.calendar = group; other.title = "另一项日程"
            other.startDate = day.addingTimeInterval(72000); other.endDate = other.startDate.addingTimeInterval(3600)
            try service.store.save(other, span: .thisEvent); service.refresh()
            let range = DateInterval(start: day, end: calendar.date(byAdding: .day, value: 4, to: day)!)
            let before = try await service.events(in: range, calendarIDs: [group.calendarIdentifier])
            let repeated = before.filter(\.isRecurring)
            XCTAssertEqual(repeated.count, 3)
            let selected = try service.currentSnapshot(try XCTUnwrap(repeated.dropFirst().first))
            XCTAssertTrue(selected.isRecurring)
            try service.deleteOccurrence(selected, scope: .futureOccurrences)
            let after = try await service.events(in: range, calendarIDs: [group.calendarIdentifier])
            XCTAssertEqual(after.map(\.title), ["重复日程", "另一项日程"])
            XCTAssertEqual(after.first?.start, repeated.first?.start)
        }
        #endif
    }

    @MainActor func testDeletionRejectsChangedEventAndInvalidFutureScope() async throws {
        let start = Date.now
        let original = CalendarEventSnapshot(eventID: "event", itemID: "event", calendarID: "test-work", title: "最新标题", start: start, end: start.addingTimeInterval(3600))
        let service = CalendarService(useDemo: true, fixtureEvents: [original])
        var stale = original; stale.title = "旧标题"
        XCTAssertThrowsError(try service.deleteOccurrence(stale))
        XCTAssertThrowsError(try service.deleteOccurrence(original, scope: .futureOccurrences))
        let remaining = try await service.events(in: DateInterval(start: start, duration: 7200))
        XCTAssertEqual(remaining, [original])
        try service.deleteOccurrence(original)
        XCTAssertThrowsError(try service.deleteOccurrence(original))
    }

    @MainActor func testConversionReadsReadonlyEventButCannotDeleteItAndRejectsStaleDeletion() async throws {
        let start = Date.now
        let readonly = CalendarEventSnapshot(eventID: "ro", itemID: "ro", calendarID: "test-readonly", title: "节日", start: start, end: start.addingTimeInterval(3600))
        var writable = readonly; writable.eventID = "rw"; writable.itemID = "rw"; writable.calendarID = "test-work"
        let service = CalendarService(useDemo: true, fixtureEvents: [readonly, writable])
        let snapshot = try service.currentSnapshot(readonly)
        XCTAssertEqual(try CountdownConversion.from(snapshot).title, "节日")
        XCTAssertThrowsError(try service.deleteOccurrence(readonly))
        try service.reschedule(writable, to: DateInterval(start: start.addingTimeInterval(3600), duration: 3600))
        XCTAssertThrowsError(try service.deleteOccurrence(writable))
        let events = try await service.events(in: DateInterval(start: start, duration: 86400))
        XCTAssertEqual(events.count, 2)
        let moved = try XCTUnwrap(events.first { $0.eventID == "rw" })
        try service.deleteOccurrence(moved)
        let remaining = try await service.events(in: DateInterval(start: start, duration: 86400))
        XCTAssertEqual(remaining.map(\.eventID), ["ro"])
    }
    @MainActor func testNativeConvertedOccurrenceDeletionPreservesRecurringSeries() async throws {
        #if targetEnvironment(simulator)
        let service = CalendarService(useDemo: false); try await service.requestAccess()
        let source = try XCTUnwrap(service.store.sources.first(where: { $0.sourceType == .local }) ?? service.store.defaultCalendarForNewEvents?.source)
        let group = EKCalendar(for: .event, eventStore: service.store); group.title = "Shike Conversion Test"; group.source = source
        try service.store.saveCalendar(group, commit: true)
        defer { try? service.store.removeCalendar(group, commit: true) }
        let day = Calendar.current.startOfDay(for: .now)
        let event = EKEvent(eventStore: service.store); event.calendar = group; event.title = "每日出行"
        event.startDate = day.addingTimeInterval(36000); event.endDate = event.startDate.addingTimeInterval(3600)
        event.recurrenceRules = [EKRecurrenceRule(recurrenceWith: .daily, interval: 1, end: EKRecurrenceEnd(occurrenceCount: 3))]
        try service.store.save(event, span: .thisEvent); service.refresh()
        let range = DateInterval(start: day, duration: 4 * 86400)
        let before = try await service.events(in: range, calendarIDs: [group.calendarIdentifier])
        XCTAssertEqual(before.count, 3)
        let selected = try service.currentSnapshot(before[1]), days = CountdownStore(inMemory: true)
        try days.insertConverted([CountdownConversion.from(selected)])
        try service.deleteOccurrence(selected)
        let after = try await service.events(in: range, calendarIDs: [group.calendarIdentifier])
        XCTAssertEqual(after.map(\.start), [before[0].start, before[2].start])
        XCTAssertEqual(days.entries.count, 1)
        #endif
    }
    func testPagingDistinguishesShortDragFlickAndFullSwipe() {
        XCTAssertEqual(CalendarPaging.direction(distance: 12, velocity: 700, width: 390), 0)
        XCTAssertEqual(CalendarPaging.direction(distance: -30, velocity: -100, width: 390), 0)
        XCTAssertEqual(CalendarPaging.direction(distance: -30, velocity: -600, width: 390), 1)
        XCTAssertEqual(CalendarPaging.direction(distance: 180, velocity: 0, width: 390), -1)
    }
    func testCachedWindowRejectsChangedFiltersAndDatesOutsideCoverage() {
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        let cache = CalendarWindowCache(range: DateInterval(start: start, duration: 7 * 86400), key: "work|Shanghai|revision1")
        let nextDay = DateInterval(start: start.addingTimeInterval(86400), duration: 86400)
        XCTAssertTrue(cache.covers(nextDay, key: cache.key))
        XCTAssertFalse(cache.covers(nextDay, key: "personal|Shanghai|revision1"))
        XCTAssertFalse(cache.covers(nextDay, key: "work|Shanghai|revision2"))
        XCTAssertFalse(cache.covers(DateInterval(start: start.addingTimeInterval(7 * 86400), duration: 86400), key: cache.key))
    }
    func testPreparedDaysInvalidateMovedEventsAndKeepCivilCountdownDates() throws {
        let zone = try XCTUnwrap(TimeZone(identifier: "Asia/Shanghai"))
        var calendar = Calendar(identifier: .gregorian); calendar.timeZone = zone
        let day = calendar.date(from: DateComponents(year: 2026, month: 10, day: 17))!
        let tomorrow = calendar.date(byAdding: .day, value: 1, to: day)!
        var event = CalendarEventSnapshot(eventID: "meeting", itemID: "meeting", calendarID: "work", title: "会议", start: day.addingTimeInterval(36000), end: day.addingTimeInterval(39600))
        var countdown = Countdown(title: "纪念日", date: CivilDate(year: 2026, month: 10, day: 17))
        countdown.timeZoneIdentifier = "Pacific/Honolulu"
        let cache = CalendarDayCache()
        cache.update(events: [event], countdowns: [countdown], timeZone: zone)
        XCTAssertEqual(cache.content(for: day).placements.map(\.event.id), [event.id])
        XCTAssertEqual(cache.content(for: day).countdowns.map(\.id), [countdown.id])
        XCTAssertTrue(cache.content(for: tomorrow).events.isEmpty)
        event.start = tomorrow.addingTimeInterval(36000); event.end = event.start.addingTimeInterval(3600)
        cache.update(events: [event], countdowns: [], timeZone: zone)
        XCTAssertTrue(cache.content(for: day).events.isEmpty)
        XCTAssertTrue(cache.content(for: day).countdowns.isEmpty)
        XCTAssertEqual(cache.content(for: tomorrow).placements.map(\.start), [event.start])
        cache.update(events: [], countdowns: [], timeZone: zone)
        XCTAssertTrue(cache.content(for: tomorrow).events.isEmpty)
    }

    @MainActor func testNativeAllDayWithInclusiveEndRemainsVisible() async throws {
        let service = CalendarService(useDemo: false); try await service.requestAccess()
        let source = try XCTUnwrap(service.store.sources.first(where: { $0.sourceType == .local }) ?? service.store.defaultCalendarForNewEvents?.source)
        let group = EKCalendar(for: .event, eventStore: service.store)
        group.title = "Shike Inclusive All Day Test"; group.source = source
        try service.store.saveCalendar(group, commit: true)
        defer { try? service.store.removeCalendar(group, commit: true) }
        let calendar = Calendar.current, day = Calendar.current.startOfDay(for: .now)
        let tomorrow = calendar.date(byAdding: .day, value: 1, to: day)!
        let event = EKEvent(eventStore: service.store)
        event.calendar = group; event.title = "当天结束的全天日程"
        event.startDate = day; event.endDate = tomorrow.addingTimeInterval(-1); event.isAllDay = true
        try service.store.save(event, span: .thisEvent)
        service.refresh()
        let found = try await service.events(in: DateInterval(start: day, end: tomorrow), calendarIDs: [group.calendarIdentifier])
        let snapshot = try XCTUnwrap(found.first)
        XCTAssertTrue(snapshot.allDay)
        XCTAssertEqual(snapshot.interval(in: .current), DateInterval(start: day, end: tomorrow), "Native interval: \(snapshot.start) - \(snapshot.end), zone: \(snapshot.timeZone)")
        var draft = EventDraft(); draft.title = "应用创建全天日程"; draft.start = day; draft.end = tomorrow
        draft.isAllDay = true; draft.calendarID = group.calendarIdentifier; draft.needsReview = false
        let saved = try service.save(draft)
        let native = try XCTUnwrap(service.store.event(withIdentifier: XCTUnwrap(saved.eventIdentifier)))
        XCTAssertTrue(native.isAllDay, "native dates \(String(describing: native.startDate)) - \(String(describing: native.endDate))")
        let created = try await service.events(in: DateInterval(start: day, end: tomorrow), calendarIDs: [group.calendarIdentifier])
        XCTAssertEqual(created.filter(\.allDay).count, 2)
        let latest = try service.latest(saved)
        XCTAssertEqual(latest.start, draft.start); XCTAssertEqual(latest.end, draft.end)
        let updated = try service.save(latest, updatingExisting: true)
        let afterUpdate = try service.latest(updated)
        XCTAssertTrue(afterUpdate.isAllDay)
        XCTAssertEqual(afterUpdate.start, draft.start); XCTAssertEqual(afterUpdate.end, draft.end)
        for identifier in ["Pacific/Honolulu", "Pacific/Kiritimati", "America/New_York"] {
            var local = Calendar(identifier: .gregorian); local.timeZone = TimeZone(identifier: identifier)!
            draft.timeZoneIdentifier = identifier
            draft.start = local.date(from: DateComponents(year: 2026, month: 3, day: 8))
            draft.end = local.date(byAdding: .day, value: 2, to: draft.start!)
            let saved = try service.save(draft)
            let read = try service.latest(saved)
            XCTAssertTrue(read.isAllDay)
            XCTAssertEqual(read.start, draft.start, identifier); XCTAssertEqual(read.end, draft.end, identifier)
            XCTAssertTrue(read.validationMessages.isEmpty)
        }
    }
    @MainActor func testNativeQueryIncludesSingleMultiDayAndRepeatingAllDayEvents() async throws {
        let service = CalendarService(useDemo: false); try await service.requestAccess()
        guard let source = service.store.sources.first(where: { $0.sourceType == .local }) ?? service.store.defaultCalendarForNewEvents?.source else { throw XCTSkip("No EventKit source") }
        let group = EKCalendar(for: .event, eventStore: service.store)
        group.title = "Shike All Day Test"; group.source = source
        try service.store.saveCalendar(group, commit: true)
        defer { try? service.store.removeCalendar(group, commit: true) }
        let calendar = Calendar.current, day = Calendar.current.startOfDay(for: .now)
        for (title, span) in [("单日全天", 1), ("跨日全天", 3), ("重复全天", 1)] {
            let event = EKEvent(eventStore: service.store)
            event.calendar = group; event.title = title
            event.startDate = day; event.endDate = calendar.date(byAdding: .day, value: span, to: day)!
            event.isAllDay = true
            event.availability = .free
            if title == "重复全天" {
                event.recurrenceRules = [EKRecurrenceRule(recurrenceWith: .daily, interval: 1, end: EKRecurrenceEnd(occurrenceCount: 3))]
            }
            try service.store.save(event, span: .thisEvent)
        }
        service.refresh()
        let end = calendar.date(byAdding: .day, value: 4, to: day)!
        let found = try await service.events(in: DateInterval(start: day, end: end), calendarIDs: [group.calendarIdentifier])
        XCTAssertEqual(found.count, 5)
        XCTAssertTrue(found.allSatisfy(\.allDay))
        let tomorrow = calendar.date(byAdding: .day, value: 1, to: day)!
        let onFirstDay = found.filter { Scheduling.overlaps($0.interval(in: .current), DateInterval(start: day, end: tomorrow)) }
        XCTAssertEqual(Set(onFirstDay.map(\.title)), ["单日全天", "跨日全天", "重复全天"])
        let single = try XCTUnwrap(found.first { $0.title == "单日全天" })
        XCTAssertFalse(Scheduling.overlaps(single.interval(in: .current), DateInterval(start: tomorrow, end: end)))
    }
    func testTimelineUsesActualHoursAcrossDSTAndPreservesDurationWhenMoving() throws {
        let zone = try XCTUnwrap(TimeZone(identifier: "America/New_York"))
        var calendar = Calendar(identifier: .gregorian); calendar.timeZone = zone
        let day = calendar.date(from: DateComponents(year: 2026, month: 3, day: 8))!
        let geometry = CalendarTimelineGeometry(days: [day, calendar.date(byAdding: .day, value: 1, to: day)!], columnWidth: 200, hourHeight: 60, timeZone: zone)
        let afterSkippedHour = geometry.date(at: CGPoint(x: 50, y: 120))
        XCTAssertEqual(calendar.component(.hour, from: afterSkippedHour), 3)
        XCTAssertEqual(calendar.component(.minute, from: geometry.date(at: CGPoint(x: 50, y: 132))), 15)
        let start = calendar.date(bySettingHour: 9, minute: 0, second: 0, of: day)!
        let event = CalendarEventSnapshot(eventID: "event", itemID: "event", calendarID: "c", title: "会议", start: start, end: start.addingTimeInterval(5400))
        let moved = geometry.moving(event, from: CGPoint(x: 50, y: 480), to: CGPoint(x: 250, y: 540))
        XCTAssertEqual(calendar.component(.day, from: moved.start), 9)
        XCTAssertEqual(calendar.component(.hour, from: moved.start), 10)
        XCTAssertEqual(moved.duration, 5400)
    }

    func testAllDayMovePreservesCivilDaysAcrossDST() throws {
        let zone = try XCTUnwrap(TimeZone(identifier: "America/New_York"))
        var calendar = Calendar(identifier: .gregorian); calendar.timeZone = zone
        let start = calendar.date(from: DateComponents(year: 2026, month: 3, day: 7))!
        let end = calendar.date(byAdding: .day, value: 1, to: start)!
        let event = CalendarEventSnapshot(eventID: "all", itemID: "all", calendarID: "c", title: "全天", start: start, end: end, allDay: true, timeZone: zone.identifier)
        let geometry = CalendarTimelineGeometry(days: [start, end], columnWidth: 100, hourHeight: 60, timeZone: zone)
        let moved = geometry.moving(event, from: CGPoint(x: 50, y: 50), to: CGPoint(x: 150, y: 80))
        XCTAssertEqual(moved.duration, 23 * 3600)
        XCTAssertEqual(calendar.component(.hour, from: moved.start), 0)
        XCTAssertEqual(calendar.component(.hour, from: moved.end), 0)
        XCTAssertEqual(calendar.dateComponents([.day], from: moved.start, to: moved.end).day, 1)
    }

    @MainActor func testRescheduleRejectsReadonlyAndStaleSnapshots() async throws {
        let start = Date.now, end = start.addingTimeInterval(3600)
        let original = CalendarEventSnapshot(eventID: "editable", itemID: "editable", calendarID: "test-work", title: "保留内容", start: start, end: end, location: "地点", notes: "备注")
        var readonly = original; readonly.eventID = "readonly"; readonly.calendarID = "test-readonly"
        let service = CalendarService(useDemo: true, fixtureEvents: [original, readonly])
        let interval = DateInterval(start: start.addingTimeInterval(1800), end: end.addingTimeInterval(1800))
        XCTAssertThrowsError(try service.reschedule(readonly, to: interval))
        try service.reschedule(original, to: interval)
        XCTAssertThrowsError(try service.reschedule(original, to: interval))
        let values = try await service.events(in: DateInterval(start: start, end: end.addingTimeInterval(3600)))
        let updated = try XCTUnwrap(values.first { $0.eventID == original.eventID })
        XCTAssertEqual(updated.start, interval.start); XCTAssertEqual(updated.end, interval.end)
        XCTAssertEqual(updated.notes, original.notes); XCTAssertEqual(updated.location, original.location)
        XCTAssertEqual(values.count, 2)
    }

    @MainActor func testNativeMovePreservesMetadataAndOnlyChangesSelectedRecurrence() async throws {
        let service = CalendarService(useDemo: false); try await service.requestAccess()
        guard let source = service.store.sources.first(where: { $0.sourceType == .local }) ?? service.store.defaultCalendarForNewEvents?.source else { throw XCTSkip("No EventKit source") }
        let calendar = EKCalendar(for: .event, eventStore: service.store)
        calendar.title = "Shike Gesture Test"; calendar.source = source
        try service.store.saveCalendar(calendar, commit: true)
        defer { try? service.store.removeCalendar(calendar, commit: true) }
        let start = Calendar.current.startOfDay(for: .now).addingTimeInterval(12 * 3600)
        let event = EKEvent(eventStore: service.store)
        event.calendar = calendar; event.title = "Recurring gesture fixture"
        event.startDate = start; event.endDate = start.addingTimeInterval(3600)
        event.notes = "keep notes"; event.location = "keep location"; event.url = URL(string: "https://example.com/calendar-test")
        event.alarms = [EKAlarm(relativeOffset: -900), EKAlarm(relativeOffset: -3600)]
        event.recurrenceRules = [EKRecurrenceRule(recurrenceWith: .daily, interval: 1, end: EKRecurrenceEnd(occurrenceCount: 3))]
        try service.store.save(event, span: .thisEvent); service.refresh()
        let interval = DateInterval(start: start.addingTimeInterval(-1), end: start.addingTimeInterval(3 * 86400))
        let before = try await service.events(in: interval, calendarIDs: [calendar.calendarIdentifier])
        XCTAssertEqual(before.count, 3)
        let occurrence = try XCTUnwrap(before.first)
        let newTime = DateInterval(start: occurrence.start.addingTimeInterval(1800), end: occurrence.end.addingTimeInterval(1800))
        try service.reschedule(occurrence, to: newTime)
        let after = try await service.events(in: interval, calendarIDs: [calendar.calendarIdentifier])
        XCTAssertEqual(after.count, 3)
        XCTAssertEqual(after.dropFirst().map(\.start), before.dropFirst().map(\.start))
        let moved = try service.editableEvent(XCTUnwrap(after.first))
        XCTAssertEqual(moved.startDate, newTime.start); XCTAssertEqual(moved.notes, "keep notes")
        XCTAssertEqual(moved.location, "keep location"); XCTAssertEqual(moved.alarms?.count, 2)
        XCTAssertEqual(moved.url, URL(string: "https://example.com/calendar-test"))
    }
}
