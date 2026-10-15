import XCTest
@testable import ShikeCore

final class CountdownTests: XCTestCase {
    let shanghai = TimeZone(identifier: "Asia/Shanghai")!
    func date(_ value: String, zone: TimeZone? = nil) -> Date { ExtractionDecoder.parseDate(value, allDay: true, timeZone: zone ?? shanghai)! }
    func entry(_ value: String, repeat frequency: CountdownRepeat = .none, lunar: Bool = false) -> Countdown {
        var v = Countdown(title: "纪念日", date: CivilDate(date(value), timeZone: shanghai))
        v.timeZoneIdentifier = shanghai.identifier; v.recurrence = frequency; v.calendar = lunar ? .chinese : .gregorian; return v
    }
    func testNaturalDaysAndOriginalAnchor() {
        let v = entry("2026-10-14")
        XCTAssertEqual(CountdownDates.distance(v, now: date("2026-10-13")), 1)
        XCTAssertEqual(CountdownDates.distance(v, now: date("2026-10-14").addingTimeInterval(80000)), 0)
        XCTAssertEqual(CountdownDates.distance(v, now: date("2026-10-15")), -1)
        XCTAssertEqual(CountdownDates.label(v, now: date("2026-10-14")), "就是今天")
        let annual = entry("2000-10-14", repeat: .yearly)
        XCTAssertEqual(CountdownDates.next(annual, onOrAfter: date("2026-10-15")), date("2027-10-14"))
        XCTAssertEqual(annual.anchorDate.description, "2000-10-14")
    }
    func testCountUnitsKeepRemaindersAndUseCalendarMonthsAndYears() {
        let past = entry("2024-01-31"), now = date("2025-03-02")
        XCTAssertEqual(CountdownDisplayValue(past, now: now, unit: .weeks).label, "已经 56 周 4 天")
        XCTAssertEqual(CountdownDisplayValue(past, now: now, unit: .months).label, "已经 13 个月 2 天")
        XCTAssertEqual(CountdownDisplayValue(past, now: now, unit: .years).label, "已经 1 年 1 个月 2 天")
        XCTAssertEqual(CountdownDisplayValue(entry("2025-02-28"), now: date("2024-02-29"), unit: .years).label, "还有 1 年")
        XCTAssertEqual(CountdownDisplayValue(entry("2026-10-15"), now: date("2026-10-14"), unit: .months).label, "还有 0 个月 1 天")
        XCTAssertEqual(CountdownDisplayValue(entry("2026-10-14"), now: date("2026-10-14"), unit: .weeks).label, "就是今天 0 周")
    }
    func testCountUnitsRespectInclusiveDaysRecurrenceAndLunarMonths() {
        var past = entry("2026-01-01"); past.includesStartDay = true
        XCTAssertEqual(CountdownDisplayValue(past, now: date("2026-01-31"), unit: .months).label, "已经 1 个月")
        XCTAssertEqual(CountdownDisplayValue(past, now: date("2026-01-08"), unit: .weeks).label, "已经 1 周 1 天")
        past.recurrence = .yearly
        XCTAssertEqual(CountdownDisplayValue(past, now: date("2026-12-01"), unit: .months).label, "还有 1 个月")
        let lunar = entry("2023-02-20", lunar: true)
        XCTAssertEqual(CountdownDisplayValue(lunar, now: date("2023-03-22"), unit: .months).label, "已经 1 个月")
        let lunarYear = entry("2023-01-22", lunar: true)
        XCTAssertEqual(CountdownDisplayValue(lunarYear, now: date("2024-02-10"), unit: .months).label, "已经 13 个月")
        XCTAssertEqual(CountdownDisplayValue(lunarYear, now: date("2024-02-10"), unit: .years).label, "已经 1 年")
    }
    func testCountUnitsPreserveSecondsAndEntryTimeZoneAcrossDST() {
        var precise = entry("2026-04-01"); precise.targetTime = CountdownTime(hour: 12, minute: 34, second: 56)
        let now = date("2026-03-01").addingTimeInterval(10 * 3600 + 20 * 60 + 30)
        XCTAssertEqual(CountdownDisplayValue(precise, now: now, unit: .months).label, "还有 1 个月 02:14:26")
        XCTAssertEqual(CountdownDisplayValue(precise, now: now, unit: .years).label, "还有 0 年 1 个月 02:14:26")
        let la = TimeZone(identifier: "America/Los_Angeles")!
        precise.timeZoneIdentifier = la.identifier; precise.targetTime = CountdownTime(hour: 12)
        let beforeDST = date("2026-03-01", zone: la).addingTimeInterval(12 * 3600)
        XCTAssertEqual(CountdownDisplayValue(precise, now: beforeDST, systemZone: shanghai, unit: .months).label, "还有 1 个月 00:00:00")
        precise.anchorDate = CivilDate(year: 2026, month: 3, day: 1); precise.includesStartDay = true
        let afterDST = date("2026-04-01", zone: la).addingTimeInterval(12 * 3600)
        XCTAssertEqual(CountdownDisplayValue(precise, now: afterDST, systemZone: shanghai, unit: .months).label, "已经 1 个月 00:00:00", "Precise durations do not add an inclusive natural day")
    }
    func testMonthlyClampsWithoutDrifting() {
        let v = entry("2024-01-31", repeat: .monthly)
        let values = CountdownDates.occurrences(v, in: DateInterval(start: date("2024-02-01"), end: date("2024-05-01")))
        XCTAssertEqual(values, [date("2024-02-29"), date("2024-03-31"), date("2024-04-30")])
        XCTAssertEqual(CountdownDates.next(v, onOrAfter: date("2025-02-01")), date("2025-02-28"))
    }
    func testLeapYearAndNewYear() {
        let v = entry("2024-02-29", repeat: .yearly)
        XCTAssertEqual(CountdownDates.next(v, onOrAfter: date("2025-01-01")), date("2025-02-28"))
        XCTAssertEqual(CountdownDates.next(v, onOrAfter: date("2028-01-01")), date("2028-02-29"))
        XCTAssertEqual(CountdownDates.distance(entry("2027-01-01"), now: date("2026-12-31")), 1)
    }
    func testWeeklyNeverPrecedesAnchorAndExclusiveRangeEnd() {
        let v = entry("2026-10-14", repeat: .weekly)
        XCTAssertEqual(CountdownDates.next(v, onOrAfter: date("2020-01-01")), date("2026-10-14"))
        XCTAssertEqual(CountdownDates.occurrences(v, in: DateInterval(start: date("2026-10-14"), end: date("2026-10-28"))), [date("2026-10-14"), date("2026-10-21")])
    }
    func testLunarLeapMonthFallsBackAndKeepsLeapAnchor() {
        let v = entry("2023-03-22", repeat: .yearly, lunar: true)
        XCTAssertEqual(CountdownDates.lunarDate(v)?.month, 2)
        XCTAssertEqual(CountdownDates.lunarDate(v)?.isLeapMonth, true)
        XCTAssertEqual(CountdownDates.next(v, onOrAfter: date("2024-01-01")), date("2024-03-10"))
        XCTAssertEqual(CountdownDates.lunarDate(v)?.isLeapMonth, true)
        let monthly = entry("2023-02-20", repeat: .monthly, lunar: true)
        XCTAssertEqual(CountdownDates.next(monthly, onOrAfter: date("2023-03-01")), date("2023-03-22"))
    }
    func testLunarThirtiethUsesLastDay() {
        let v = entry("2024-02-09", repeat: .yearly, lunar: true)
        XCTAssertEqual(CountdownDates.lunarDate(v)?.day, 30)
        XCTAssertEqual(CountdownDates.next(v, onOrAfter: date("2025-01-01")), date("2025-01-28"))
    }
    func testDSTAndFollowingSystemZone() {
        let la = TimeZone(identifier: "America/Los_Angeles")!
        let a = date("2026-03-08", zone: la), b = date("2026-03-09", zone: la)
        XCTAssertEqual(b.timeIntervalSince(a), 23 * 3600)
        XCTAssertEqual(CountdownDates.days(from: a, to: b, timeZone: la), 1)
        let fall = date("2026-11-01", zone: la), next = date("2026-11-02", zone: la)
        XCTAssertEqual(next.timeIntervalSince(fall), 25 * 3600)
        XCTAssertEqual(CountdownDates.days(from: fall, to: next, timeZone: la), 1)
        var v = entry("2026-10-14"); v.timeZoneIdentifier = nil
        let instant = date("2026-10-14")
        XCTAssertEqual(CountdownDates.distance(v, now: instant, systemZone: shanghai), 0)
        XCTAssertEqual(CountdownDates.distance(v, now: instant, systemZone: la), 1)
    }
    func testCivilDateRejectsInvalidValuesAndKeepsStringEncoding() throws {
        XCTAssertThrowsError(try JSONDecoder().decode(CivilDate.self, from: Data("\"2025-02-29\"".utf8)))
        XCTAssertThrowsError(try JSONDecoder().decode(CivilDate.self, from: Data("\"2026-1-01\"".utf8)))
        XCTAssertEqual(String(decoding: try JSONEncoder().encode(CivilDate(year: 2026, month: 10, day: 14)), as: UTF8.self), "\"2026-10-14\"")
    }
    func testNotificationQueueOrdersCapsAndReplans() {
        var a = entry("2026-10-14", repeat: .weekly); a.reminder.daysBefore = [0, 1, 3, 7]
        var b = entry("2026-10-15", repeat: .weekly); b.reminder.daysBefore = [0]
        let now = date("2026-10-14").addingTimeInterval(10 * 3600)
        let plan = CountdownNotifications.plan([a,b], now: now)
        XCTAssertEqual(plan.count, 60)
        XCTAssertTrue(plan.allSatisfy { $0.fireAt > now })
        XCTAssertEqual(plan.map(\.fireAt), plan.map(\.fireAt).sorted())
        XCTAssertEqual(Set(plan.map(\.id)).count, 60)
        XCTAssertFalse(CountdownNotifications.plan([a], now: now).contains { $0.countdownID == b.id })
        XCTAssertTrue(CountdownNotifications.plan([], now: now).isEmpty)
    }
    func testNotificationTimeAcrossDST() {
        var v = entry("2026-03-09"); v.timeZoneIdentifier = "America/Los_Angeles"; v.reminder.daysBefore = [1]
        let now = date("2026-03-07", zone: v.timeZone())
        let notice = CountdownNotifications.plan([v], now: now).first!
        var c = Calendar(identifier: .gregorian); c.timeZone = v.timeZone()
        XCTAssertEqual(c.component(.hour, from: notice.fireAt), 9)
        XCTAssertEqual(CivilDate(notice.fireAt, timeZone: v.timeZone()).description, "2026-03-08")
    }
    func testInclusiveCountsAndCustomMilestonesFollowCivilDays() throws {
        var v = entry("2025-01-01"); v.reminder.milestones = [520, 1314]
        let anchor = date("2025-01-01")
        let ordinary = CountdownNotifications.plan([v], now: anchor)
        XCTAssertEqual(ordinary.map(\.milestoneDay), [520, 1314])
        XCTAssertEqual(CountdownDates.days(from: anchor, to: ordinary[0].fireAt, timeZone: shanghai), 520)
        v.includesStartDay = true
        XCTAssertEqual(CountdownDates.label(v, now: anchor), "已经 1 天")
        XCTAssertEqual(CountdownDates.label(v, now: date("2025-01-02")), "已经 2 天")
        XCTAssertEqual(CountdownDates.label(v, now: date("2024-12-31")), "还有 1 天")
        let inclusive = CountdownNotifications.plan([v], now: anchor)
        XCTAssertEqual(CountdownDates.days(from: anchor, to: inclusive[0].fireAt, timeZone: shanghai), 519)
        XCTAssertEqual(CountdownNotifications.plan([v], now: inclusive[0].fireAt).map(\.milestoneDay), [1314])
        v.reminder.milestones = [0]; XCTAssertThrowsError(try v.validate())
        v.reminder.milestones = [520, 520]; XCTAssertThrowsError(try v.validate())
        v.reminder.milestones = [100001]; XCTAssertThrowsError(try v.validate())
    }
    func testPrecisionToSecondsAndRecurrenceAfterTodaysTime() throws {
        var v = entry("2026-10-14"); v.targetTime = CountdownTime(hour: 12, minute: 34, second: 56)
        let target = date("2026-10-14").addingTimeInterval(12 * 3600 + 34 * 60 + 56)
        XCTAssertEqual(CountdownDates.nextInstant(v, onOrAfter: target.addingTimeInterval(-1)), target)
        XCTAssertEqual(CountdownDates.label(v, now: target.addingTimeInterval(-1)), "还有 0 天 00:00:01")
        XCTAssertEqual(CountdownDates.label(v, now: target.addingTimeInterval(1)), "已经 0 天 00:00:01")
        v.includesStartDay = true
        XCTAssertEqual(CountdownDates.label(v, now: target.addingTimeInterval(1)), "已经 0 天 00:00:01")
        v.recurrence = .weekly
        XCTAssertEqual(CountdownDates.nextInstant(v, onOrAfter: target.addingTimeInterval(1)), target.addingTimeInterval(7 * 86400))
        XCTAssertEqual(CountdownDates.next(v, onOrAfter: target.addingTimeInterval(1)), date("2026-10-14"), "Calendar overlay remains on the natural day")
        v.targetTime?.second = 60; XCTAssertThrowsError(try v.validate())
    }
    func testPreciseTimeDSTGapAndRepeatedTimePolicy() throws {
        let la = TimeZone(identifier: "America/Los_Angeles")!
        var v = entry("2026-03-08"); v.timeZoneIdentifier = la.identifier; v.targetTime = CountdownTime(hour: 2, minute: 30, second: 15)
        var c = Calendar(identifier: .gregorian); c.timeZone = la
        let instant = try XCTUnwrap(CountdownDates.instant(v, on: date("2026-03-08", zone: la)))
        XCTAssertEqual(c.component(.hour, from: instant), 3)
        XCTAssertEqual(c.component(.minute, from: instant), 30)
        XCTAssertEqual(c.component(.second, from: instant), 15)
        v.anchorDate = CivilDate(year: 2026, month: 11, day: 1); v.targetTime = CountdownTime(hour: 1, minute: 30)
        let repeated = try XCTUnwrap(CountdownDates.instant(v, on: date("2026-11-01", zone: la)))
        XCTAssertEqual(la.secondsFromGMT(for: repeated), -7 * 3600)
        v.reminder.milestones = [1]; v.includesStartDay = true
        XCTAssertEqual(CivilDate(CountdownNotifications.plan([v], now: date("2026-10-31", zone: la)).first!.fireAt, timeZone: la), v.anchorDate)
    }
    func testOldRecordsDecodeWithNewOptionsOffAndNewRecordsRoundTrip() throws {
        var v = entry("2026-10-14")
        var old = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(v)) as? [String: Any])
        old.removeValue(forKey: "targetTime"); old.removeValue(forKey: "includesStartDay")
        let restored = try JSONDecoder().decode(Countdown.self, from: JSONSerialization.data(withJSONObject: old))
        XCTAssertNil(restored.targetTime); XCTAssertNil(restored.includesStartDay); XCTAssertTrue(restored.reminder.milestones.isEmpty)
        v.targetTime = CountdownTime(hour: 23, minute: 59, second: 59); v.includesStartDay = true; v.reminder.milestones = [520,1314]
        XCTAssertEqual(try JSONDecoder().decode(Countdown.self, from: JSONEncoder().encode(v)), v)
        let oldPreferences = Data(#"{"visibleDays":3}"#.utf8)
        XCTAssertNil(try JSONDecoder().decode(CalendarPreferences.self, from: oldPreferences).countdownLayout)
    }
    func testRecordMergeIsCommutativeAndDeletionDoesNotResurrect() {
        let a = CountdownRecord(entry("2026-10-14"), now: date("2026-01-01"))
        var b = a; b.deleted = true; b.countdown = nil; b.updatedAt = date("2026-01-02")
        let c = CountdownRecord(entry("2026-10-15"))
        XCTAssertEqual(CountdownRecord.merge([a,c], [b]), CountdownRecord.merge([b], [a,c]))
        XCTAssertTrue(CountdownRecord.merge([b], [a]).first!.deleted)
        var d = a; d.revision = UUID(uuidString: "FFFFFFFF-FFFF-4FFF-8FFF-FFFFFFFFFFFF")!
        var e = a; e.revision = UUID(uuidString: "00000000-0000-4000-8000-000000000000")!
        XCTAssertEqual(CountdownRecord.merge([d], [e]), CountdownRecord.merge([e], [d]))
        XCTAssertEqual(CountdownRecord.merge([d], [e]).first?.revision, d.revision)
    }
    func testExportAllowlistAndUnicodeRoundTrip() throws {
        let sentinel = "DO-NOT-EXPORT-CREDENTIAL"
        var session = ImportSession(); session.text = "中文原文\n第二行 🐱"; session.pendingImages = ["/private/secret.png"]
        session.planning = PlanningConversation(goal: "一起看书", now: date("2026-10-14"), timeZone: shanghai)
        session.planning?.turns = [PlanningTurn(role: "user", text: "明晚\n九点", options: ["可以"])]
        var draft = EventDraft(); draft.title = "阅读"; draft.eventIdentifier = sentinel; draft.calendarItemIdentifier = sentinel
        draft.calendarID = "local-calendar-token"; draft.notes = "手动修改的备注"; draft.saveError = sentinel; session.drafts = [draft]
        let profile = APIProfile(name: "示例接口", configuration: .init(baseURL: "https://user:\(sentinel)@example.com/v1?key=\(sentinel)#\(sentinel)", model: "example"), credentialID: sentinel)
        let preferences = AppDataExport.PreferencesData(iCloudEnabled: false, categoryRoutingEnabled: true, defaultCalendar: nil, categoryCalendars: [:], activeProfileID: profile.id, calendar: CalendarPreferences())
        var v = entry("2023-03-22", repeat: .yearly, lunar: true); v.categoryID = CountdownCategory.defaults[0].id
        v.targetTime = CountdownTime(hour: 13, minute: 14, second: 52); v.includesStartDay = true; v.reminder.milestones = [520,1314]
        v.reminder.anniversaries = true; v.reminder.dayInterval = 500
        let export = AppDataExport(exportedAt: date("2026-10-14"), version: "1.0", build: "1", preferences: preferences, profiles: [profile], prompts: .init(extraction: "自定义\n规则"), countdowns: [v], categories: CountdownCategory.defaults, sessions: [session], calendarReferences: ["local-calendar-token": .init(title: "个人", account: "iCloud")])
        let data = try export.data(), text = String(decoding: data, as: UTF8.self)
        for forbidden in [sentinel, "credentialID", "pendingImages", "/private/", "local-calendar-token", "eventIdentifier", "calendarItemIdentifier", "engineState", "saveError"] { XCTAssertFalse(text.contains(forbidden), forbidden) }
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(Set(json.keys), Set(["format","schemaVersion","exportedAt","app","preferences","apiProfiles","prompts","countdowns","countdownCategories","importSessions"]))
        XCTAssertEqual(json["format"] as? String, "shike-export")
        XCTAssertEqual(json["schemaVersion"] as? Int, 1)
        let exportedSessions = try XCTUnwrap(json["importSessions"] as? [[String: Any]])
        XCTAssertEqual(exportedSessions.first?["text"] as? String, session.text)
        XCTAssertTrue(text.contains("2026-10-13T16:00:00Z"))
        XCTAssertTrue(text.contains("https://example.com/v1"))
        if let path = ProcessInfo.processInfo.environment["SHIKE_EXPORT_FIXTURE"] { try data.write(to: URL(fileURLWithPath: path), options: .atomic) }
    }
}
