import XCTest
@testable import ShikeCore

final class AppDataImportTests: XCTestCase {
    func fixture() -> AppDataExport {
        var entry = Countdown(title: "在一起", date: CivilDate(year: 2020, month: 5, day: 20))
        entry.reminder = CountdownReminder(anniversaries: true, dayInterval: 500)
        entry.includesStartDay = true; entry.targetTime = CountdownTime(hour: 13, minute: 14, second: 52)
        var session = ImportSession(); session.text = "私密原文"
        var draft = EventDraft(); draft.title = "会议"; draft.eventIdentifier = "DEVICE-EVENT-ID"
        draft.calendarID = "LOCAL-ID"; session.drafts = [draft]
        return AppDataExport(version: "1.0", build: "4", preferences: .init(iCloudEnabled: true, categoryRoutingEnabled: true,
            defaultCalendar: nil, categoryCalendars: [:], activeProfileID: "test", calendar: CalendarPreferences()),
            profiles: [APIProfile(id: "test", name: "测试接口", configuration: APIConfiguration(baseURL: "https://example.com", model: "example"), credentialID: "PRIVATE-CREDENTIAL")],
            prompts: .init(extraction: "自定义规则"), countdowns: [entry], categories: CountdownCategory.defaults,
            sessions: [session], calendarReferences: ["LOCAL-ID": .init(title: "工作", account: "iCloud")])
    }
    func testExportImportRoundTripKeepsRemindersAndDoesNotRecreateSavedEvents() throws {
        let data = try fixture().data(), imported = try AppDataImport(data: data)
        XCTAssertEqual(imported.backup.countdowns.first?.countdown.reminder.dayInterval, 500)
        XCTAssertEqual(imported.backup.countdowns.first?.countdown.targetTime?.second, 52)
        XCTAssertEqual(imported.backup.countdowns.first?.countdown.includesStartDay, true)
        XCTAssertEqual(imported.prompts.extraction, "自定义规则")
        let session = try XCTUnwrap(imported.sessions(calendars: ["NEW-ID": .init(title: "工作", account: "iCloud")]).first)
        let draft = try XCTUnwrap(session.drafts.first)
        XCTAssertEqual(draft.calendarID, "NEW-ID"); XCTAssertNil(draft.eventIdentifier)
        XCTAssertFalse(draft.isSaved); XCTAssertFalse(draft.selected); XCTAssertTrue(draft.needsReview)
        XCTAssertEqual(draft.restoredFromSavedEvent, true)
        XCTAssertFalse(String(decoding: data, as: UTF8.self).contains("PRIVATE-CREDENTIAL"))
        XCTAssertFalse(String(decoding: data, as: UTF8.self).contains("DEVICE-EVENT-ID"))
    }
    func testRejectsUnknownFormatVersionDuplicatesAndMalformedDate() throws {
        let json = try JSONSerialization.jsonObject(with: fixture().data()) as! [String: Any]
        for (key, value) in [("format", "foreign" as Any), ("schemaVersion", 999 as Any)] {
            var modified = json; modified[key] = value
            XCTAssertThrowsError(try AppDataImport(data: JSONSerialization.data(withJSONObject: modified)))
        }
        var modified = json
        let items = json["countdowns"] as! [[String: Any]]
        modified["countdowns"] = items + items
        XCTAssertThrowsError(try AppDataImport(data: JSONSerialization.data(withJSONObject: modified)))
        var entry = items[0]; entry["anchorDate"] = "2026-02-30"; modified["countdowns"] = [entry]
        XCTAssertThrowsError(try AppDataImport(data: JSONSerialization.data(withJSONObject: modified)))
        XCTAssertThrowsError(try AppDataImport(data: Data("{}".utf8)))
    }
    func testMissingAndAmbiguousCalendarReferencesStayUnassigned() throws {
        let imported = try AppDataImport(data: fixture().data())
        XCTAssertNil(imported.sessions(calendars: [:]).first?.drafts.first?.calendarID)
        let reference = CalendarReference(title: "工作", account: "iCloud")
        XCTAssertNil(imported.sessions(calendars: ["a": reference, "b": reference]).first?.drafts.first?.calendarID)
    }
    func testRejectsCredentialsHiddenInImportedEndpoint() throws {
        var json = try JSONSerialization.jsonObject(with: fixture().data()) as! [String: Any]
        var profiles = json["apiProfiles"] as! [[String: Any]]
        profiles[0]["baseURL"] = "https://example.com?key=private"; json["apiProfiles"] = profiles
        XCTAssertThrowsError(try AppDataImport(data: JSONSerialization.data(withJSONObject: json)))
    }
    func testOlderVersionOneBackupWithoutNewDisplayOptionsUsesDefaults() throws {
        var json = try JSONSerialization.jsonObject(with: fixture().data()) as! [String: Any]
        var entries = json["countdowns"] as! [[String: Any]]
        entries[0].removeValue(forKey: "includesStartDay"); entries[0].removeValue(forKey: "targetTime")
        json["countdowns"] = entries
        var preferences = json["preferences"] as! [String: Any]
        var calendar = preferences["calendar"] as! [String: Any]
        calendar.removeValue(forKey: "showCountdowns"); calendar.removeValue(forKey: "countdownLayout")
        preferences["calendar"] = calendar; json["preferences"] = preferences
        let imported = try AppDataImport(data: JSONSerialization.data(withJSONObject: json))
        XCTAssertFalse(imported.backup.countdowns[0].countdown.includesStartDay ?? false)
        XCTAssertNil(imported.backup.countdowns[0].countdown.targetTime)
    }
}
