import XCTest
import UIKit
import EventKit
import UniformTypeIdentifiers
import ShikeCore
@testable import Shike

final class NativeServiceTests: XCTestCase {
    @MainActor func testPromptSettingsPersistSyncAndResetIndependently() throws {
        let defaults = try consentDefaults(), cloud = MemoryCloudStore()
        let a = Preferences(defaults: defaults, cloud: cloud)
        try a.setPrompt("只提取明确的事项", for: .extraction)
        try a.setPrompt("晚间优先安排学习", for: .planning)
        XCTAssertEqual(Preferences(defaults: defaults).promptSettings, a.promptSettings)
        // Prompt-only configuration must not be mistaken for a fresh, empty install.
        try a.setCloudEnabled(true)
        XCTAssertNotNil(cloud.payload)
        let b = Preferences(defaults: try consentDefaults(), cloud: cloud)
        try b.setCloudEnabled(true)
        XCTAssertEqual(b.promptSettings, a.promptSettings)
        try b.setPrompt(PromptPurpose.extraction.defaultText, for: .extraction)
        a.checkCloudSync()
        XCTAssertNil(a.promptSettings.extraction)
        XCTAssertEqual(a.promptSettings.planning, "晚间优先安排学习")
        XCTAssertThrowsError(try a.setPrompt(String(repeating: "字", count: 12001), for: .planning))
        XCTAssertEqual(a.promptSettings.planning, "晚间优先安排学习")
    }

    @MainActor func testPlanningControllerGatesActualTransportAndPersistsAnswers() async throws {
        let defaults = try consentDefaults(), preferences = Preferences(defaults: try consentDefaults())
        let configuration = APIConfiguration(baseURL: "https://planning.example/v1", model: "test-model")
        try preferences.saveProfile(id: nil, name: "测试安排", configuration: configuration, key: "fixture-key")
        try preferences.setPrompt("安排偏好-marker", for: .planning)
        defer {
            for profile in preferences.profiles { if let id = profile.credentialID { try? KeychainStore.saveProfileKey("", id: id, synchronizable: false) } }
        }
        PlanningNativeTransport.reset()
        let config = URLSessionConfiguration.ephemeral; config.protocolClasses = [PlanningNativeTransport.self]
        let urlSession = URLSession(configuration: config); defer { urlSession.invalidateAndCancel() }
        let now = Date.now
        let event = CalendarEventSnapshot(eventID: "private-event-identifier", itemID: "private-item", calendarID: "test-work", title: "Private existing meeting", start: now.addingTimeInterval(3600), end: now.addingTimeInterval(7200), notes: "private-event-notes")
        let store = try SessionStore(inMemory: true)
        let environment = AppEnvironment(preferences: preferences, calendars: CalendarService(useDemo: true, fixtureEvents: [event]), store: store,
            consent: ExtractionConsentStore(defaults: defaults), llmClient: LLMClient(session: urlSession))
        var session = ImportSession(); session.text = "读完一本书"
        let controller = ImportController(environment: environment, session: session)
        controller.openPlanning(); controller.advancePlanning()
        XCTAssertEqual(controller.consentRequest?.includesPlanning, true)
        XCTAssertEqual(controller.consentRequest?.includesAvailability, true)
        XCTAssertEqual(PlanningNativeTransport.requests.count, 0)
        controller.declineExtraction(); XCTAssertTrue(controller.session.planning!.turns.isEmpty)
        controller.advancePlanning(); controller.allowExtraction(); try await waitForOperation(controller)
        XCTAssertNil(controller.errorMessage); XCTAssertEqual(PlanningNativeTransport.requests.count, 1)
        XCTAssertEqual(controller.session.planning?.turns.count, 1)
        controller.advancePlanning(answer: "半小时"); try await waitForOperation(controller)
        XCTAssertEqual(controller.session.planning?.turns.count, 3)
        XCTAssertEqual(try store.all().first?.planning, controller.session.planning)
        let request = try XCTUnwrap(PlanningNativeTransport.requests.first)
        XCTAssertTrue(request.contains("availableIntervals")); XCTAssertTrue(request.contains("读完一本书"))
        XCTAssertTrue(request.contains("安排偏好-marker"))
        for forbidden in ["Private existing meeting", "private-event-notes", "private-event-identifier", "private-item"] { XCTAssertFalse(request.contains(forbidden)) }
        environment.consent.revokeAll(); controller.advancePlanning(answer: "换到下午")
        XCTAssertNotNil(controller.consentRequest); XCTAssertEqual(PlanningNativeTransport.requests.count, 2)
    }

    @MainActor func testRefreshingReferenceDatePersistsWithoutChangingInputDraftsOrCreationTime() async throws {
        let start = Date.now.addingTimeInterval(86400), end = start.addingTimeInterval(86400)
        let controller = try planningController(events: [], range: DateInterval(start: start, end: end), timeZone: .current,
            response: #"{"events":[{"title":"测试会议","start":"2030-01-01T10:00:00+08:00","end":"2030-01-01T11:00:00+08:00","allDay":false}]}"#)
        controller.session.planning = nil
        controller.session.createdAt = Date(timeIntervalSince1970: 1_600_000_000)
        controller.session.text = "明天下午开会"
        controller.session.drafts = [reviewEvent("原有草稿")]; controller.session.hasParsed = true
        let before = controller.session, reference = Date(timeIntervalSince1970: 1_800_000_000)
        controller.refreshReferenceDate(now: reference)
        XCTAssertEqual(controller.session.createdAt, before.createdAt)
        XCTAssertEqual(controller.session.text, before.text); XCTAssertEqual(controller.session.drafts, before.drafts)
        XCTAssertEqual(try controller.environment.store?.all().first?.effectiveReferenceDate, reference)
        XCTAssertTrue(PlanningNativeTransport.requests.isEmpty, "更新时间不应自动调用模型")
        controller.parse(); controller.allowExtraction(); try await waitForOperation(controller)
        XCTAssertNil(controller.errorMessage)
        let request = try XCTUnwrap(PlanningNativeTransport.requests.last)
        XCTAssertTrue(request.contains(ISO8601DateFormatter().string(from: reference)))
        XCTAssertFalse(request.contains(ISO8601DateFormatter().string(from: before.createdAt)))
        controller.busyMessage = "正在提取"
        controller.refreshReferenceDate(now: reference.addingTimeInterval(3600))
        XCTAssertEqual(controller.session.effectiveReferenceDate, reference, "请求进行中不应更改参考时间")
    }

    @MainActor func testPlanningConsentDoesNotInheritOldTextOrCalendarGrants() throws {
        let defaults = try consentDefaults()
        let configuration = APIConfiguration(baseURL: "https://example.com/v1", model: "model")
        let text = try ExtractionConsent(configuration: configuration, includesCalendarNames: true)
        defaults.set([text.serviceURL: 2], forKey: "shike.extractionConsent.v1")
        let consent = ExtractionConsentStore(defaults: defaults)
        XCTAssertTrue(consent.allows(text))
        let planning = try ExtractionConsent(configuration: configuration, includesCalendarNames: true, includesPlanning: true)
        let availability = try ExtractionConsent(configuration: configuration, includesCalendarNames: true, includesPlanning: true, includesAvailability: true)
        XCTAssertFalse(consent.allows(planning)); consent.grant(planning)
        XCTAssertTrue(consent.allows(planning)); XCTAssertFalse(consent.allows(availability))
        consent.grant(availability); XCTAssertTrue(consent.allows(availability))
        consent.revokeAll(); XCTAssertFalse(consent.allows(text))
    }

    @MainActor func testPlanningAvailabilityIgnoresAllDayButPreservesTimedOccupancy() async throws {
        let zone = TimeZone(identifier: "Asia/Shanghai")!
        var calendar = Calendar(identifier: .gregorian); calendar.timeZone = zone
        let start = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: .now))!
        let end = calendar.date(byAdding: .day, value: 3, to: start)!
        let allDay = CalendarEventSnapshot(eventID: "private-all-day", itemID: "private-all-day", calendarID: "test-readonly",
            title: "Private all-day reminder", start: start, end: end.addingTimeInterval(-1), allDay: true, timeZone: zone.identifier)
        let meeting = CalendarEventSnapshot(eventID: "meeting", itemID: "meeting", calendarID: "test-work", title: "会议",
            start: start.addingTimeInterval(10 * 3600), end: start.addingTimeInterval(11 * 3600))
        var free = meeting; free.eventID = "free"; free.blocksTime = false
        var fullDayTimed = meeting; fullDayTimed.start = start; fullDayTimed.end = start.addingTimeInterval(86400)
        let fullRange = DateInterval(start: start, end: end)
        let scenarios: [([CalendarEventSnapshot], [DateInterval])] = [
            ([], [fullRange]), ([allDay], [fullRange]), ([allDay, free], [fullRange]),
            ([allDay, meeting], [DateInterval(start: start, end: meeting.start), DateInterval(start: meeting.end, end: end)]),
            ([allDay, fullDayTimed], [DateInterval(start: fullDayTimed.end, end: end)])
        ]
        for (events, expected) in scenarios {
            let controller = try planningController(events: events, range: fullRange, timeZone: zone)
            controller.advancePlanning(); controller.allowExtraction(); try await waitForOperation(controller)
            XCTAssertNil(controller.errorMessage)
            let raw = try XCTUnwrap(PlanningNativeTransport.requests.last)
            let body = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(raw.utf8)) as? [String: Any])
            let messages = try XCTUnwrap(body["messages"] as? [[String: Any]])
            let input = try XCTUnwrap(messages.last?["content"] as? String)
            let context = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(input.utf8)) as? [String: Any])
            let intervals = try XCTUnwrap(context["availableIntervals"] as? [[String: String]])
            let iso = ISO8601DateFormatter()
            let actual = try intervals.map { value in
                DateInterval(start: try XCTUnwrap(value["start"].flatMap(iso.date)), end: try XCTUnwrap(value["end"].flatMap(iso.date)))
            }
            XCTAssertEqual(actual, expected)
            XCTAssertFalse(raw.contains(allDay.title)); XCTAssertFalse(raw.contains(allDay.eventID))
            let visible = try await controller.environment.calendars.events(in: fullRange)
            XCTAssertEqual(visible.filter(\.allDay), events.filter(\.allDay), "全天日程仍应能被日历读取和显示")
        }
    }

    @MainActor func testPlanningAllDayProposalsDoNotConflictDuringGenerationEditingOrSave() async throws {
        let zone = TimeZone(identifier: "Asia/Shanghai")!
        var calendar = Calendar(identifier: .gregorian); calendar.timeZone = zone
        let start = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: .now))!
        let end = calendar.date(byAdding: .day, value: 1, to: start)!
        let range = DateInterval(start: start, end: end), iso = ISO8601DateFormatter()
        let meetingStart = start.addingTimeInterval(10 * 3600), meetingEnd = start.addingTimeInterval(11 * 3600)
        let allDay = CalendarEventSnapshot(eventID: "all-day", itemID: "all-day", calendarID: "test-work",
            title: "已有全天提醒", start: start, end: end, allDay: true, timeZone: zone.identifier)
        let meeting = CalendarEventSnapshot(eventID: "meeting", itemID: "meeting", calendarID: "test-work",
            title: "已有会议", start: meetingStart, end: meetingEnd)
        let proposals: [[String: Any]] = [
            ["title": "全天纪念", "start": CivilDate(start, timeZone: zone).description, "end": CivilDate(end, timeZone: zone).description, "allDay": true],
            ["title": "上午阅读", "start": iso.string(from: meetingStart), "end": iso.string(from: meetingEnd), "allDay": false],
            ["title": "午间阅读", "start": iso.string(from: start.addingTimeInterval(12 * 3600)), "end": iso.string(from: start.addingTimeInterval(13 * 3600)), "allDay": false]
        ]
        let response = String(decoding: try JSONSerialization.data(withJSONObject: ["kind": "proposal", "message": "已安排", "events": proposals]), as: UTF8.self)
        for hasTimedConflict in [false, true] {
            let controller = try planningController(events: hasTimedConflict ? [allDay, meeting] : [allDay], range: range, timeZone: zone, response: response)
            controller.advancePlanning(); controller.allowExtraction(); try await waitForOperation(controller)
            XCTAssertNil(controller.errorMessage); XCTAssertEqual(controller.session.drafts.count, 3)
            guard controller.session.drafts.count == 3 else { continue }
            XCTAssertFalse(controller.session.drafts[0].needsReview)
            XCTAssertEqual(controller.session.drafts[1].needsReview, hasTimedConflict)
            XCTAssertFalse(controller.session.drafts[2].needsReview)
            if hasTimedConflict {
                controller.saveSelected(); try await waitForOperation(controller)
                let review = try XCTUnwrap(controller.reviewDraft)
                XCTAssertEqual(review.title, "上午阅读")
                XCTAssertTrue(review.reviewNotes.contains { $0.contains("已有会议") })
                XCTAssertFalse(review.reviewNotes.contains { $0.contains("已有全天提醒") || $0.contains("全天纪念") })
                XCTAssertEqual(controller.session.savedCount, 0)
                continue
            }
            // Editing two timed suggestions into a conflict must still require review.
            let original = controller.session.drafts[2]
            controller.session.drafts[2].start = meetingStart.addingTimeInterval(1800)
            controller.saveSelected(); try await waitForOperation(controller)
            XCTAssertNotNil(controller.review); XCTAssertEqual(controller.session.savedCount, 0)
            XCTAssertTrue(try XCTUnwrap(controller.reviewDraft).reviewNotes.contains { $0.contains("本次安排") })
            controller.cancelReview(); controller.session.drafts[2] = original
            controller.saveSelected(); try await waitForOperation(controller)
            XCTAssertNil(controller.review); XCTAssertNil(controller.errorMessage)
            XCTAssertEqual(controller.session.savedCount, 3)
            XCTAssertTrue(controller.session.drafts[0].isAllDay)
        }
    }

    @MainActor func testRestartPlanningPreservesRangeAndCalendarsButClearsGoalAnswersAndDrafts() throws {
        let start = Date.now.addingTimeInterval(86400), end = start.addingTimeInterval(3 * 86400)
        let controller = try planningController(events: [], range: DateInterval(start: start, end: end), timeZone: TimeZone(identifier: "Asia/Shanghai")!)
        var preferences = controller.environment.preferences.calendarPreferences
        preferences.planningCalendars = []
        controller.environment.preferences.setCalendarPreferences(preferences)
        controller.session.planning?.turns = [PlanningTurn(role: "user", text: "每次半小时")]
        controller.session.planning?.hasProposal = true
        controller.session.hasParsed = true
        controller.session.drafts = [reviewEvent("旧方案")]
        let original = controller.session
        controller.restartPlanning()
        XCTAssertNotEqual(controller.session.id, original.id)
        XCTAssertTrue(controller.session.text.isEmpty)
        XCTAssertEqual(controller.session.displayTitle, "未填写的安排")
        XCTAssertEqual(controller.session.planning?.goal, "")
        XCTAssertEqual(controller.session.planning?.turns, [])
        XCTAssertEqual(controller.session.planning?.start, start)
        XCTAssertEqual(controller.session.planning?.end, end)
        XCTAssertEqual(controller.session.referenceTimeZone, original.referenceTimeZone)
        XCTAssertTrue(controller.session.drafts.isEmpty)
        XCTAssertFalse(controller.session.hasParsed)
        XCTAssertEqual(controller.environment.preferences.calendarPreferences.planningCalendars, [])
        XCTAssertTrue(PlanningNativeTransport.requests.isEmpty)
        let stored = try XCTUnwrap(controller.environment.store).all()
        XCTAssertEqual(stored.first { $0.id == original.id }?.drafts, original.drafts)
        XCTAssertEqual(stored.first { $0.id == controller.session.id }?.planning, controller.session.planning)
        // Editing the next goal at home must retain the explicitly selected range.
        controller.session.text = "学习摄影"
        controller.openPlanning()
        XCTAssertEqual(controller.session.planning?.goal, "学习摄影")
        XCTAssertEqual(controller.session.planning?.start, start)
        XCTAssertEqual(controller.session.planning?.end, end)
    }

    @MainActor func testPlanningWithNoReferenceCalendarsSendsFullAvailability() async throws {
        let start = Date.now.addingTimeInterval(86400), end = start.addingTimeInterval(86400)
        let event = CalendarEventSnapshot(eventID: "busy", itemID: "busy", calendarID: "test-work", title: "忙碌", start: start, end: end)
        let controller = try planningController(events: [event], range: DateInterval(start: start, end: end), timeZone: .current)
        var preferences = controller.environment.preferences.calendarPreferences
        preferences.planningCalendars = []
        controller.environment.preferences.setCalendarPreferences(preferences)
        controller.advancePlanning(); controller.allowExtraction(); try await waitForOperation(controller)
        XCTAssertNil(controller.errorMessage)
        let request = try XCTUnwrap(PlanningNativeTransport.requests.last)
        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(request.utf8)) as? [String: Any])
        let messages = try XCTUnwrap(body["messages"] as? [[String: Any]])
        let input = try XCTUnwrap(messages.last?["content"] as? String)
        let context = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(input.utf8)) as? [String: Any])
        let intervals = try XCTUnwrap(context["availableIntervals"] as? [[String: String]])
        XCTAssertEqual(intervals.count, 1)
        let iso = ISO8601DateFormatter()
        XCTAssertEqual(try XCTUnwrap(intervals.first?["start"].flatMap(iso.date)).timeIntervalSince1970, start.timeIntervalSince1970, accuracy: 1)
        XCTAssertEqual(try XCTUnwrap(intervals.first?["end"].flatMap(iso.date)).timeIntervalSince1970, end.timeIntervalSince1970, accuracy: 1)
    }

    @MainActor private func planningController(events: [CalendarEventSnapshot], range: DateInterval, timeZone: TimeZone,
                                               response: String? = nil) throws -> ImportController {
        let preferences = Preferences(defaults: try consentDefaults())
        let configuration = APIConfiguration(baseURL: "https://planning.example/v1", model: "test-model")
        try preferences.saveProfile(id: nil, name: "测试安排", configuration: configuration, key: "fixture-key")
        let credential = try XCTUnwrap(preferences.activeProfile?.credentialID)
        addTeardownBlock { try? KeychainStore.saveProfileKey("", id: credential, synchronizable: false) }
        let config = URLSessionConfiguration.ephemeral; config.protocolClasses = [PlanningNativeTransport.self]
        let transport = URLSession(configuration: config)
        addTeardownBlock { transport.invalidateAndCancel() }
        PlanningNativeTransport.reset(response: response)
        let environment = AppEnvironment(preferences: preferences, calendars: CalendarService(useDemo: true, fixtureEvents: events),
            store: try SessionStore(inMemory: true), consent: ExtractionConsentStore(defaults: try consentDefaults()),
            llmClient: LLMClient(session: transport), modelJobs: ModelJobCenter(platformEnabled: false))
        var session = ImportSession(); session.text = "安排全天纪念和阅读"; session.referenceTimeZone = timeZone.identifier
        var plan = PlanningConversation(goal: session.text, now: range.start, timeZone: timeZone)
        plan.start = range.start; plan.end = range.end; session.planning = plan
        return ImportController(environment: environment, session: session)
    }

    @MainActor func testCalendarQueriesIncludeReadonlyAndRespectEmptySelectionAndBoundaries() async throws {
        let start = Date.now, end = start.addingTimeInterval(3600)
        let event = CalendarEventSnapshot(eventID: "readonly", itemID: "r", calendarID: "test-readonly", title: "只读", start: start, end: end)
        let service = CalendarService(useDemo: true, fixtureEvents: [event])
        XCTAssertEqual(service.readableCalendars.count, 3); XCTAssertEqual(service.calendars.count, 2)
        let all = try await service.events(in: DateInterval(start: start, end: end))
        XCTAssertEqual(all, [event])
        let empty = try await service.events(in: DateInterval(start: start, end: end), calendarIDs: [])
        XCTAssertTrue(empty.isEmpty)
        let adjacent = try await service.events(in: DateInterval(start: end, end: end.addingTimeInterval(60)))
        XCTAssertTrue(adjacent.isEmpty)
    }

    @MainActor func testPlanningConflictsRequireAcknowledgementAndRecheckBeforeSave() async throws {
        let start = Date.now.addingTimeInterval(7200), end = start.addingTimeInterval(1800)
        let service = CalendarService(useDemo: true, fixtureEvents: [CalendarEventSnapshot(eventID: "busy", itemID: "busy", calendarID: "test-work", title: "已有会议", start: start, end: end)])
        let environment = AppEnvironment(preferences: Preferences(defaults: try consentDefaults()), calendars: service, store: try SessionStore(inMemory: true))
        var session = ImportSession(); session.text = "阅读"; session.planning = PlanningConversation(goal: session.text)
        var draft = EventDraft(); draft.title = "阅读"; draft.start = start; draft.end = end; draft.calendarID = "test-calendar"
        session.drafts = [draft]
        let controller = ImportController(environment: environment, session: session)
        controller.saveSelected(); try await waitForOperation(controller)
        XCTAssertNotNil(controller.review); XCTAssertEqual(controller.session.savedCount, 0)
        XCTAssertTrue(try XCTUnwrap(controller.reviewDraft).reviewNotes.contains { $0.contains("已有会议") })
        // A second event arrives while the user is reviewing the first conflict.
        var newEvent = draft; newEvent.title = "刚加入的约会"; newEvent.calendarID = "test-work"
        _ = try service.save(newEvent)
        try controller.confirmReview(try XCTUnwrap(controller.reviewDraft)); try await waitForOperation(controller)
        XCTAssertEqual(controller.session.savedCount, 0)
        XCTAssertTrue(try XCTUnwrap(controller.reviewDraft).reviewNotes.contains { $0.contains("刚加入的约会") })
        try controller.confirmReview(try XCTUnwrap(controller.reviewDraft)); try await waitForOperation(controller)
        XCTAssertNil(controller.review); XCTAssertEqual(controller.session.savedCount, 1)
        controller.saveSelected(); try await waitForOperation(controller)
        XCTAssertEqual(controller.session.savedCount, 1)
    }

    @MainActor func testCalendarPreferencesRoundTripThroughCloudWithoutLocalCalendarIDs() throws {
        let cloud = MemoryCloudStore()
        let a = Preferences(defaults: try consentDefaults(), cloud: cloud)
        try a.setCloudEnabled(true)
        var settings = CalendarPreferences(); settings.visibleDays = 7
        settings.visibleCalendars = [CalendarReference(title: "只读", account: "订阅")]
        settings.planningCalendars = []; settings.timeZoneIdentifier = "Asia/Shanghai"
        a.setCalendarPreferences(settings)
        let b = Preferences(defaults: try consentDefaults(), cloud: cloud)
        try b.setCloudEnabled(true)
        XCTAssertEqual(b.calendarPreferences, settings)
        XCTAssertFalse(String(decoding: try XCTUnwrap(cloud.payload), as: UTF8.self).contains("calendarID"))
    }

    @MainActor func testTimelinePackingClipsCrossDayAndSeparatesOverlaps() {
        let start = Date.now, end = start.addingTimeInterval(86400)
        let events = [CalendarEventSnapshot(eventID: "a", itemID: "a", calendarID: "c", title: "跨天", start: start.addingTimeInterval(-3600), end: start.addingTimeInterval(1800)),
                      CalendarEventSnapshot(eventID: "b", itemID: "b", calendarID: "c", title: "重叠", start: start, end: start.addingTimeInterval(3600)),
                      CalendarEventSnapshot(eventID: "c", itemID: "c", calendarID: "c", title: "独立", start: start.addingTimeInterval(7200), end: start.addingTimeInterval(9000))]
        let placements = TimelinePlacement.make(events: events, start: start, end: end)
        XCTAssertEqual(placements[0].start, start)
        XCTAssertEqual(placements.map(\.lanes), [2, 2, 1])
        XCTAssertNotEqual(placements[0].lane, placements[1].lane)
    }

    @MainActor func testQuickActionRoutingConsumesEachRequestOnce() {
        let router = QuickImportRouter()
        XCTAssertFalse(router.receive(UIApplicationShortcutItem(type: "unknown", localizedTitle: "unknown")))
        XCTAssertTrue(router.receive(UIApplicationShortcutItem(type: QuickImportAction.clipboard.rawValue, localizedTitle: "粘贴")))
        let id = router.pending!.id
        router.consume(UUID()); XCTAssertNotNil(router.pending)
        router.consume(id); XCTAssertNil(router.pending)
        XCTAssertTrue(router.receive(UIApplicationShortcutItem(type: QuickImportAction.latestPhoto.rawValue, localizedTitle: "最近图片")))
        XCTAssertNotEqual(router.pending?.id, id)
    }

    @MainActor private func consentDefaults() throws -> UserDefaults {
        let suite = "Shike.ConsentTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        addTeardownBlock { UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite) }
        return defaults
    }

    @MainActor func testConsentSeparatesRecipientsAndScopesAndSharesRevocation() throws {
        let defaults = try consentDefaults()
        let app = ExtractionConsentStore(defaults: defaults), share = ExtractionConsentStore(defaults: defaults)
        let config = APIConfiguration(baseURL: "https://example.com/v1", model: "model")
        let text = try ExtractionConsent(configuration: config, includesCalendarNames: false)
        let calendars = try ExtractionConsent(configuration: config, includesCalendarNames: true)
        XCTAssertFalse(app.allows(text)); app.grant(text)
        XCTAssertTrue(share.allows(text)); XCTAssertFalse(share.allows(calendars))
        share.grant(calendars); XCTAssertTrue(app.allows(calendars)); XCTAssertTrue(app.allows(text))
        let other = try ExtractionConsent(configuration: APIConfiguration(baseURL: "https://example.com/proxy/v1"), includesCalendarNames: false)
        XCTAssertFalse(app.allows(other))
        share.revokeAll(); XCTAssertFalse(app.allows(text)); XCTAssertFalse(app.allows(calendars))
    }

    func testConsentNormalizesEndpointsWithoutLosingProxyBoundaries() throws {
        func scope(_ url: String, _ format: APIFormat = .openAI) throws -> ExtractionConsent {
            try ExtractionConsent(configuration: APIConfiguration(baseURL: url, model: "new-model", format: format), includesCalendarNames: false)
        }
        XCTAssertEqual(try scope("https://EXAMPLE.com:443"), try scope("https://example.com/v1/chat/completions/"))
        XCTAssertEqual(try scope("https://example.com/v1beta", .gemini), try scope("https://example.com/v1beta/models/old:generateContent", .gemini))
        XCTAssertNotEqual(try scope("https://example.com/tenant-a/v1"), try scope("https://example.com/tenant-b/v1"))
        XCTAssertNotEqual(try scope("https://a.example.com"), try scope("https://b.example.com"))
        XCTAssertThrowsError(try scope("https://user:password@example.com"))
        XCTAssertThrowsError(try scope("http://example.com"))
    }

    @MainActor func testConsentGatesActualTransportAndReparseAndRevocation() async throws {
        let defaults = try consentDefaults(), preferences = Preferences(defaults: try consentDefaults())
        let configuration = APIConfiguration(baseURL: "https://consent.example/v1", model: "test-model")
        try preferences.saveProfile(id: nil, name: "测试", configuration: configuration, key: "fixture-key")
        defer {
            for profile in preferences.profiles {
                if let id = profile.credentialID { try? KeychainStore.saveProfileKey("", id: id, synchronizable: false) }
            }
        }
        ConsentTransport.reset()
        let config = URLSessionConfiguration.ephemeral; config.protocolClasses = [ConsentTransport.self]
        let urlSession = URLSession(configuration: config)
        defer { urlSession.invalidateAndCancel() }
        let consent = ExtractionConsentStore(defaults: defaults)
        let environment = AppEnvironment(preferences: preferences, calendars: CalendarService(useDemo: true),
                                         store: try SessionStore(inMemory: true), consent: consent, llmClient: LLMClient(session: urlSession))
        var session = ImportSession(); session.text = "明天下午两点开会"; session.drafts = [reviewEvent("原有草稿")]
        let controller = ImportController(environment: environment, session: session)
        controller.parse(); XCTAssertNotNil(controller.consentRequest); XCTAssertFalse(controller.isBusy)
        XCTAssertEqual(ConsentTransport.requestCount, 0)
        controller.declineExtraction(); XCTAssertEqual(controller.session.drafts, session.drafts)
        XCTAssertEqual(ConsentTransport.requestCount, 0)
        controller.parse(); controller.allowExtraction(); try await waitForOperation(controller)
        XCTAssertNil(controller.errorMessage); XCTAssertEqual(ConsentTransport.requestCount, 1)
        controller.parse(); XCTAssertNil(controller.consentRequest); try await waitForOperation(controller)
        XCTAssertEqual(ConsentTransport.requestCount, 2)
        preferences.setCategoryRouting(true); controller.parse()
        XCTAssertEqual(controller.consentRequest?.includesCalendarNames, true)
        XCTAssertEqual(ConsentTransport.requestCount, 2)
        controller.allowExtraction(); try await waitForOperation(controller)
        XCTAssertEqual(ConsentTransport.requestCount, 3)
        consent.revokeAll(); controller.parse()
        XCTAssertNotNil(controller.consentRequest); XCTAssertEqual(ConsentTransport.requestCount, 3)
    }

    @MainActor func testConsentDoesNotApproveChangedConfiguration() throws {
        let preferences = Preferences(defaults: try consentDefaults())
        preferences.configuration = APIConfiguration(baseURL: "https://first.example/v1", model: "model")
        let consent = ExtractionConsentStore(defaults: try consentDefaults())
        let environment = AppEnvironment(preferences: preferences, calendars: CalendarService(useDemo: true),
                                         store: try SessionStore(inMemory: true), consent: consent)
        let controller = ImportController(environment: environment)
        controller.session.text = "明天开会"; controller.parse()
        let first = try XCTUnwrap(controller.consentRequest)
        preferences.configuration = APIConfiguration(baseURL: "https://second.example/v1", model: "model")
        controller.allowExtraction()
        XCTAssertEqual(controller.consentRequest?.host, "second.example")
        XCTAssertFalse(consent.allows(first)); XCTAssertFalse(consent.allows(try XCTUnwrap(controller.consentRequest)))
        XCTAssertFalse(controller.isBusy)
        preferences.setCategoryRouting(true); controller.allowExtraction()
        XCTAssertEqual(controller.consentRequest?.includesCalendarNames, true)
        XCTAssertFalse(controller.isBusy)
    }

    func testReleaseLegalResourcesAndDeviceConfiguration() throws {
        let policy = try String(contentsOf: XCTUnwrap(Bundle.main.url(forResource: "PrivacyPolicy", withExtension: "txt")), encoding: .utf8)
        XCTAssertTrue(policy.contains("shike@yeslu.cn"))
        XCTAssertNotNil(Bundle.main.url(forResource: "OFL", withExtension: "txt"))
        #if targetEnvironment(macCatalyst)
        XCTAssertEqual(Bundle.main.object(forInfoDictionaryKey: "DTPlatformName") as? String, "macosx")
        #else
        XCTAssertEqual(Bundle.main.object(forInfoDictionaryKey: "UIDeviceFamily") as? [Int], [1, 2])
        #endif
        XCTAssertEqual(Bundle.main.object(forInfoDictionaryKey: "ITSAppUsesNonExemptEncryption") as? Bool, false)
    }

    @MainActor private func reviewController(_ drafts: [EventDraft]) throws -> ImportController {
        let suite = "Shike.ReviewTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        addTeardownBlock { UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite) }
        let environment = AppEnvironment(preferences: Preferences(defaults: defaults), calendars: CalendarService(useDemo: true),
                                         store: try SessionStore(inMemory: true), consent: ExtractionConsentStore(defaults: defaults))
        var session = ImportSession(); session.text = "测试核对流程"; session.hasParsed = true; session.drafts = drafts
        return ImportController(environment: environment, session: session)
    }

    private func reviewEvent(_ title: String, needsReview: Bool = true) -> EventDraft {
        var draft = EventDraft(); draft.title = title; draft.start = .now; draft.end = draft.start!.addingTimeInterval(3600)
        draft.calendarID = "test-calendar"; draft.needsReview = needsReview
        return draft
    }

    @MainActor private func waitForOperation(_ controller: ImportController) async throws {
        for _ in 0..<100 where controller.isBusy { try await Task.sleep(for: .milliseconds(20)) }
        XCTAssertFalse(controller.isBusy)
    }

    @MainActor func testGuidedReviewPersistsProgressAndWritesOnlyAfterLastConfirmation() async throws {
        let first = reviewEvent("第一条"), second = reviewEvent("第二条")
        let ready = reviewEvent("已核对", needsReview: false)
        var ignored = EventDraft(); ignored.selected = false
        var saved = reviewEvent("已保存"); saved.eventIdentifier = "saved-fixture"
        let controller = try reviewController([first, ready, ignored, second, saved])
        controller.saveSelected()
        XCTAssertEqual(controller.review?.pendingIDs, [first.id, second.id])
        controller.saveSelected()
        try controller.confirmReview(first)
        XCTAssertEqual(controller.session.savedCount, 1)
        XCTAssertFalse(controller.session.drafts[0].needsReview)
        XCTAssertThrowsError(try controller.confirmReview(first))
        controller.cancelReview()
        let stored = try XCTUnwrap(controller.environment.store?.all().first)
        let restored = ImportController(environment: controller.environment, session: stored)
        restored.saveSelected()
        XCTAssertEqual(restored.review?.pendingIDs, [second.id])
        try restored.confirmReview(second)
        restored.saveSelected() // A repeated tap must not start another write.
        try await waitForOperation(restored)
        XCTAssertNil(restored.review)
        XCTAssertEqual(restored.session.savedCount, 4)
        XCTAssertEqual(restored.information, "已将 3 个日程加入日历。")
        XCTAssertEqual(Set(restored.session.drafts.compactMap(\.eventIdentifier)).count, 4)
        XCTAssertFalse(restored.session.drafts[2].isSaved)
    }

    @MainActor func testGuidedReviewSkipRequiresExplicitSaveForRemainingEvents() async throws {
        let ready = reviewEvent("直接加入", needsReview: false)
        var pending = reviewEvent("暂不加入")
        let controller = try reviewController([ready, pending])
        controller.saveSelected()
        pending.notes = "稍后确认"
        try controller.skipReview(pending)
        XCTAssertNotNil(controller.review)
        XCTAssertNil(controller.reviewDraft)
        XCTAssertEqual(controller.reviewSaveCount, 1)
        XCTAssertEqual(controller.session.savedCount, 0)
        XCTAssertFalse(controller.isBusy)
        XCTAssertFalse(controller.session.drafts[1].selected)
        XCTAssertTrue(controller.session.drafts[1].needsReview)
        XCTAssertEqual(controller.session.drafts[1].notes, "稍后确认")
        try controller.finishReview()
        try await waitForOperation(controller)
        XCTAssertEqual(controller.session.savedCount, 1)
        XCTAssertFalse(controller.session.drafts[1].isSaved)
    }

    @MainActor func testGuidedReviewSkipAllAndCancelNeverWrite() throws {
        let first = reviewEvent("第一条"), second = reviewEvent("第二条")
        let controller = try reviewController([first, second])
        controller.saveSelected(); controller.cancelReview()
        XCTAssertTrue(controller.session.drafts.allSatisfy(\.needsReview))
        controller.saveSelected()
        try controller.skipReview(first); try controller.skipReview(second)
        XCTAssertNil(controller.review)
        XCTAssertEqual(controller.session.savedCount, 0)
        XCTAssertFalse(controller.isBusy)
        XCTAssertTrue(controller.session.drafts.allSatisfy { !$0.selected })
    }

    @MainActor func testGuidedReviewBlocksInvalidFieldsAndInterruptedWrites() async throws {
        var draft = EventDraft(); draft.needsReview = true; draft.saveAttemptInProgress = true
        let controller = try reviewController([draft])
        controller.saveSelected()
        XCTAssertThrowsError(try controller.confirmReview(draft))
        XCTAssertEqual(controller.reviewDraft?.id, draft.id)
        draft.title = "修正后的日程"; draft.start = .now; draft.end = draft.start
        draft.calendarID = "test-calendar"
        XCTAssertThrowsError(try controller.confirmReview(draft))
        draft.end = draft.start!.addingTimeInterval(3600)
        XCTAssertThrowsError(try controller.confirmReview(draft)) // Confirming suggestions cannot clear interrupted intent.
        draft.saveAttemptInProgress = false; draft.calendarID = "deleted-calendar"
        XCTAssertThrowsError(try controller.confirmReview(draft))
        XCTAssertEqual(controller.session.savedCount, 0)
        draft.calendarID = "test-calendar"
        try controller.confirmReview(draft)
        try await waitForOperation(controller)
        XCTAssertEqual(controller.session.savedCount, 1)
    }

    @MainActor func testGuidedReviewRechecksEarlierDraftsBeforeWriting() async throws {
        let first = reviewEvent("第一条"), second = reviewEvent("第二条")
        let controller = try reviewController([first, second])
        controller.saveSelected(); try controller.confirmReview(first)
        controller.session.drafts[0].calendarID = "unavailable-calendar"
        try controller.confirmReview(second)
        XCTAssertEqual(controller.review?.pendingIDs, [first.id])
        XCTAssertEqual(controller.session.savedCount, 0)
        var fixed = try XCTUnwrap(controller.reviewDraft); fixed.calendarID = "test-work"
        try controller.confirmReview(fixed)
        try await waitForOperation(controller)
        XCTAssertEqual(controller.session.savedCount, 2)
    }

    @MainActor func testValidDraftsSaveWithoutReviewAndParseFailureKeepsDrafts() async throws {
        let draft = reviewEvent("已核对", needsReview: false)
        let controller = try reviewController([draft])
        controller.parse() // Empty fixture configuration fails locally, without a network request.
        try await waitForOperation(controller)
        XCTAssertNotNil(controller.errorMessage)
        XCTAssertEqual(controller.session.drafts, [draft])
        let configuration = APIConfiguration(baseURL: "https://cancel.example/v1", model: "fixture")
        controller.environment.preferences.configuration = configuration
        controller.environment.consent.grant(try ExtractionConsent(configuration: configuration, includesCalendarNames: false))
        controller.parse(); controller.cancel()
        try await waitForOperation(controller)
        XCTAssertNil(controller.errorMessage)
        XCTAssertEqual(controller.session.drafts, [draft])
        controller.saveSelected()
        XCTAssertNil(controller.review)
        try await waitForOperation(controller)
        XCTAssertEqual(controller.session.savedCount, 1)
        controller.parse()
        XCTAssertFalse(controller.isBusy)
        XCTAssertEqual(controller.session.savedCount, 1)
    }

    @MainActor func testBlankAndDuplicateProfilesPersistAndSyncIndependently() throws {
        let suite = "Shike.DuplicateProfileTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite)); let cloud = MemoryCloudStore()
        let secondSuite = suite + ".second"
        let secondDefaults = try XCTUnwrap(UserDefaults(suiteName: secondSuite))
        let preferences = Preferences(defaults: defaults, cloud: cloud)
        var credentials = Set<String>()
        defer {
            for id in credentials {
                try? KeychainStore.saveProfileKey("", id: id, synchronizable: false)
                try? KeychainStore.saveProfileKey("", id: id, synchronizable: true)
            }
            defaults.removePersistentDomain(forName: suite)
            secondDefaults.removePersistentDomain(forName: secondSuite)
        }
        try preferences.createBlankProfile()
        let blank = try XCTUnwrap(preferences.activeProfile)
        XCTAssertEqual(blank.configuration, APIConfiguration())
        XCTAssertNil(blank.credentialID)
        XCTAssertEqual(try preferences.profileKey(blank), "")
        try preferences.saveProfile(id: nil, name: "Claude", configuration: APIConfiguration(baseURL: "https://example.com/custom", model: "fixture", format: .claude), key: "original-fixture-key")
        let original = try XCTUnwrap(preferences.activeProfile)
        credentials.insert(try XCTUnwrap(original.credentialID))
        try preferences.duplicateProfile(original.id)
        let copy = try XCTUnwrap(preferences.activeProfile)
        credentials.insert(try XCTUnwrap(copy.credentialID))
        XCTAssertNotEqual(copy.id, original.id)
        XCTAssertNotEqual(copy.credentialID, original.credentialID)
        XCTAssertEqual(copy.configuration, original.configuration)
        XCTAssertEqual(copy.name, "Claude 副本")
        XCTAssertEqual(try preferences.profileKey(copy), "original-fixture-key")
        try preferences.saveProfile(id: copy.id, name: copy.name, configuration: APIConfiguration(baseURL: "https://backup.example/custom", model: "backup", format: .gemini), key: "changed-fixture-key")
        credentials.insert(try XCTUnwrap(preferences.activeProfile?.credentialID))
        XCTAssertEqual(try preferences.profileKey(original), "original-fixture-key")
        XCTAssertEqual(preferences.profiles.first { $0.id == original.id }?.configuration, original.configuration)
        try preferences.duplicateProfile(original.id)
        credentials.insert(try XCTUnwrap(preferences.activeProfile?.credentialID))
        XCTAssertEqual(preferences.activeProfile?.name, "Claude 副本 2")
        try preferences.setCloudEnabled(true)
        preferences.profiles.compactMap(\.credentialID).forEach { credentials.insert($0) }
        preferences.selectProfile(blank.id)
        let restored = Preferences(defaults: secondDefaults, cloud: cloud)
        let snapshot = try JSONDecoder().decode(CloudSettingsSnapshot.self, from: XCTUnwrap(cloud.payload))
        XCTAssertEqual(snapshot.profiles?.count, 4)
        XCTAssertEqual(snapshot.activeProfileID, blank.id)
        try restored.setCloudEnabled(true)
        XCTAssertEqual(restored.profiles.count, 4)
        XCTAssertEqual(restored.activeProfile?.configuration, APIConfiguration())
        try restored.duplicateProfile(original.id)
        credentials.insert(try XCTUnwrap(restored.activeProfile?.credentialID))
        XCTAssertEqual(try restored.profileKey(XCTUnwrap(restored.activeProfile)), "original-fixture-key")
        XCTAssertEqual(restored.activeProfile?.name, "Claude 副本 3")
    }

    @MainActor func testMultipleProfilesKeepFormatsAndCredentialsIsolated() throws {
        let suite = "Shike.ProfileTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        let preferences = Preferences(defaults: defaults)
        defer {
            for profile in preferences.profiles { if let id = profile.credentialID { try? KeychainStore.saveProfileKey("", id: id, synchronizable: false) } }
            defaults.removePersistentDomain(forName: suite)
        }
        try preferences.saveProfile(id: nil, name: "Claude 代理", configuration: APIConfiguration(baseURL: "https://claude.example/custom", model: "claude-fixture", format: .claude), key: "claude-test-key")
        let claude = try XCTUnwrap(preferences.activeProfile)
        try preferences.saveProfile(id: nil, name: "Gemini 代理", configuration: APIConfiguration(baseURL: "https://gemini.example/custom", model: "gemini-fixture", format: .gemini), key: "gemini-test-key")
        let gemini = try XCTUnwrap(preferences.activeProfile)
        XCTAssertEqual(preferences.profiles.count, 2)
        XCTAssertEqual(try preferences.profileKey(claude), "claude-test-key")
        XCTAssertEqual(try preferences.profileKey(gemini), "gemini-test-key")
        preferences.selectProfile(claude.id)
        let restored = Preferences(defaults: defaults)
        XCTAssertEqual(restored.configuration.format, .claude)
        XCTAssertEqual(restored.activeProfileID, claude.id)
        XCTAssertEqual(restored.configuration.baseURL, "https://claude.example/custom")
        preferences.deleteProfile(claude.id)
        XCTAssertEqual(preferences.activeProfileID, gemini.id)
        try KeychainStore.saveProfileKey("", id: XCTUnwrap(claude.credentialID), synchronizable: false)
    }

    @MainActor func testCloudSyncTransfersAllProfilesAndSelectedProvider() throws {
        let suite = "Shike.ProfileCloudTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite)); let cloud = MemoryCloudStore()
        let preferences = Preferences(defaults: defaults, cloud: cloud)
        var credentials = Set<String>()
        defer {
            for id in credentials {
                try? KeychainStore.saveProfileKey("", id: id, synchronizable: false)
                try? KeychainStore.saveProfileKey("", id: id, synchronizable: true)
            }
            defaults.removePersistentDomain(forName: suite)
        }
        for format in APIFormat.allCases {
            try preferences.saveProfile(id: nil, name: format.title, configuration: APIConfiguration(baseURL: "https://example.com", model: "fixture", format: format), key: "test-key-\(format.rawValue)")
            credentials.insert(try XCTUnwrap(preferences.activeProfile?.credentialID))
        }
        try preferences.setCloudEnabled(true)
        preferences.profiles.compactMap(\.credentialID).forEach { credentials.insert($0) }
        let outgoing = try JSONDecoder().decode(CloudSettingsSnapshot.self, from: XCTUnwrap(cloud.payload))
        XCTAssertEqual(outgoing.profiles?.count, 3)
        XCTAssertEqual(outgoing.configuration.format, .gemini)
        XCTAssertFalse(String(data: cloud.payload!, encoding: .utf8)!.contains("test-key-"))
        for profile in preferences.profiles { XCTAssertEqual(try preferences.profileKey(profile), "test-key-\(profile.configuration.format.rawValue)") }
        try preferences.setCloudEnabled(false)
        for profile in preferences.profiles { XCTAssertEqual(try preferences.profileKey(profile), "test-key-\(profile.configuration.format.rawValue)") }
    }

    @MainActor func testEmptyInstallationWaitsForCloudInsteadOfPublishingDefaults() throws {
        guard try KeychainStore.readLocal().isEmpty else { throw XCTSkip("Preserving a configured local key") }
        let suite = "Shike.CloudTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let cloud = MemoryCloudStore()
        let preferences = Preferences(defaults: defaults, cloud: cloud)
        try preferences.setCloudEnabled(true)
        XCTAssertTrue(preferences.iCloudEnabled)
        XCTAssertNil(cloud.payload)
        let snapshot = CloudSettingsSnapshot(configuration: APIConfiguration(baseURL: "https://example.com/v1", model: "existing-cloud-model"), credentialID: nil,
                                             defaultCalendar: nil, categoryRoutingEnabled: false, categoryCalendars: [:])
        cloud.payload = try JSONEncoder().encode(snapshot)
        preferences.receiveCloudChanges(reason: NSUbiquitousKeyValueStoreInitialSyncChange)
        XCTAssertEqual(preferences.configuration.model, "existing-cloud-model")
    }

    @MainActor func testCloudRestoreAndPublishWithPortableCalendarMapping() throws {
        let suite = "Shike.CloudTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let cloud = MemoryCloudStore()
        let reference = CalendarReference(title: "工作", account: "iCloud")
        let snapshot = CloudSettingsSnapshot(configuration: APIConfiguration(baseURL: "https://example.com/v1", model: "synced-model"), credentialID: "fixture-missing-key",
                                             defaultCalendar: reference, categoryRoutingEnabled: true, categoryCalendars: ["work": reference])
        cloud.payload = try JSONEncoder().encode(snapshot)
        let preferences = Preferences(defaults: defaults, cloud: cloud)
        preferences.updateCalendars([CalendarChoice(id: "this-device-id", title: "工作", account: "iCloud", color: .blue)])
        try preferences.setCloudEnabled(true)
        XCTAssertEqual(preferences.configuration.model, "synced-model")
        XCTAssertEqual(preferences.defaultCalendarID, "this-device-id")
        XCTAssertEqual(preferences.categoryCalendars["work"], "this-device-id")
        XCTAssertEqual(defaults.string(forKey: "cloudCredentialID"), "fixture-missing-key")
        XCTAssertThrowsError(try preferences.save(configuration: snapshot.configuration, key: ""), "A delayed key must not be erased by saving an empty field")
        preferences.setCategoryRouting(false)
        let outgoing = try JSONDecoder().decode(CloudSettingsSnapshot.self, from: XCTUnwrap(cloud.payload))
        XCTAssertFalse(outgoing.categoryRoutingEnabled)
        XCTAssertEqual(outgoing.defaultCalendar, reference)
        XCTAssertEqual(outgoing.credentialID, snapshot.credentialID)
    }

    @MainActor func testCloudExternalUpdatesAndOptOut() throws {
        guard try KeychainStore.readLocal().isEmpty else { throw XCTSkip("Preserving a configured local key") }
        let suite = "Shike.CloudTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let cloud = MemoryCloudStore()
        var snapshot = CloudSettingsSnapshot(configuration: APIConfiguration(baseURL: "https://example.com", model: "first-model"),
                                             credentialID: nil, defaultCalendar: nil, categoryRoutingEnabled: false, categoryCalendars: [:])
        cloud.payload = try JSONEncoder().encode(snapshot)
        let preferences = Preferences(defaults: defaults, cloud: cloud)
        try preferences.setCloudEnabled(true)
        snapshot.revision = UUID(); snapshot.updatedAt = .now.addingTimeInterval(1); snapshot.configuration.model = "remote-change"
        cloud.payload = try JSONEncoder().encode(snapshot)
        preferences.receiveCloudChanges(reason: NSUbiquitousKeyValueStoreServerChange)
        XCTAssertEqual(preferences.configuration.model, "remote-change")
        try preferences.setCloudEnabled(false)
        snapshot.revision = UUID(); snapshot.updatedAt = .now.addingTimeInterval(2); snapshot.configuration.model = "ignored-after-opt-out"
        cloud.payload = try JSONEncoder().encode(snapshot)
        preferences.receiveCloudChanges(reason: NSUbiquitousKeyValueStoreServerChange)
        XCTAssertEqual(preferences.configuration.model, "remote-change")
        XCTAssertFalse(preferences.iCloudEnabled)
    }

    @MainActor func testCloudUnavailableOrMalformedDoesNotReplaceLocalSettings() throws {
        let suite = "Shike.CloudTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set("local-model", forKey: "model")
        let cloud = MemoryCloudStore(); cloud.accountAvailable = false
        let preferences = Preferences(defaults: defaults, cloud: cloud)
        XCTAssertThrowsError(try preferences.setCloudEnabled(true))
        XCTAssertFalse(preferences.iCloudEnabled)
        cloud.accountAvailable = true; cloud.payload = Data("bad-payload".utf8)
        XCTAssertThrowsError(try preferences.setCloudEnabled(true))
        XCTAssertEqual(preferences.configuration.model, "local-model")
        XCTAssertFalse(preferences.iCloudEnabled)
    }

    func testSynchronizableKeychainRoundTripIsSeparateFromLocalCredential() throws {
        let local = try KeychainStore.readLocal()
        let id = "test-" + UUID().uuidString
        defer { try? KeychainStore.saveCloud("", id: id) }
        try KeychainStore.saveCloud("test-only-synced-key", id: id)
        XCTAssertEqual(try KeychainStore.readCloud(id: id), "test-only-synced-key")
        XCTAssertEqual(try KeychainStore.readLocal(), local)
        try KeychainStore.saveCloud("", id: id)
        XCTAssertTrue(try KeychainStore.readCloud(id: id).isEmpty)
    }

    @MainActor func testCategoryPreferencesPersistForSharedReaders() throws {
        let suite = "Shike.CategoryTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let preferences = Preferences(defaults: defaults)
        XCTAssertFalse(preferences.categoryRoutingEnabled)
        preferences.setCategoryRouting(true)
        preferences.setCategoryCalendar("calendar-work", for: .work)
        let otherReader = Preferences(defaults: defaults)
        XCTAssertTrue(otherReader.categoryRoutingEnabled)
        XCTAssertEqual(otherReader.categoryCalendars["work"], "calendar-work")
        preferences.setCategoryRouting(false)
        preferences.setCategoryCalendar("", for: .work)
        otherReader.reload()
        XCTAssertFalse(otherReader.categoryRoutingEnabled)
        XCTAssertNil(otherReader.categoryCalendars["work"])
    }

    func testTextProvidersSupportStringFileAndUTF16() async throws {
        let expected = "明天下午两点开会\nMeeting room A"
        let plain = try await ItemLoader.load([NSItemProvider(object: expected as NSString)])
        XCTAssertEqual(plain.0, expected); XCTAssertTrue(plain.1.isEmpty)
        let path = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".txt")
        try Data(expected.utf8).write(to: path)
        defer { try? FileManager.default.removeItem(at: path) }
        let file = NSItemProvider(item: path as NSURL, typeIdentifier: UTType.utf8PlainText.identifier)
        let fromFile = try await ItemLoader.load([file])
        XCTAssertEqual(fromFile.0, expected)
        let utf16 = NSItemProvider()
        utf16.registerDataRepresentation(forTypeIdentifier: UTType.utf16PlainText.identifier, visibility: .all) { completion in
            completion(expected.data(using: .utf16), nil); return nil
        }
        let fromUTF16 = try await ItemLoader.load([utf16])
        XCTAssertEqual(fromUTF16.0, expected)
    }

    func testSharedKeychainRoundTrip() throws {
        guard try KeychainStore.read().isEmpty else { throw XCTSkip("Preserving an existing configured key") }
        defer { try? KeychainStore.save("") }
        try KeychainStore.save("test-only-keychain-fixture")
        XCTAssertEqual(try KeychainStore.read(), "test-only-keychain-fixture")
        try KeychainStore.save("updated-test-only-fixture")
        XCTAssertEqual(try KeychainStore.read(), "updated-test-only-fixture")
        try KeychainStore.save("")
        XCTAssertTrue(try KeychainStore.read().isEmpty)
    }

    @MainActor func testVisionRecognizesChineseAndEnglishFixture() async throws {
        let format = UIGraphicsImageRendererFormat(); format.scale = 1
        let image = UIGraphicsImageRenderer(size: CGSize(width: 1200, height: 360), format: format).image { context in
            UIColor.white.setFill(); context.fill(CGRect(x: 0, y: 0, width: 1200, height: 360))
            let text = "2026年12月15日 产品评审\n14:00 - 15:00\nMeeting Room A"
            (text as NSString).draw(in: CGRect(x: 50, y: 40, width: 1100, height: 300), withAttributes: [.font: UIFont.systemFont(ofSize: 50), .foregroundColor: UIColor.black])
        }
        let text = try await OCRService.recognize(try XCTUnwrap(image.pngData()))
        XCTAssertTrue(text.contains("评审"), text)
        XCTAssertTrue(text.contains("14:00"), text)
        XCTAssertTrue(text.contains("Meeting"), text)
    }

    @MainActor func testVisionRejectsBlankImage() async throws {
        let image = UIGraphicsImageRenderer(size: CGSize(width: 200, height: 200)).image { context in
            UIColor.white.setFill(); context.fill(CGRect(x: 0, y: 0, width: 200, height: 200))
        }
        do { _ = try await OCRService.recognize(try XCTUnwrap(image.pngData())); XCTFail("Blank image accepted") }
        catch { XCTAssertTrue(error.localizedDescription.contains("没有识别到文字")) }
    }

    @MainActor func testUIImageShareProviderProducesRecognizableImageFile() async throws {
        let format = UIGraphicsImageRendererFormat(); format.scale = 1
        let image = UIGraphicsImageRenderer(size: CGSize(width: 800, height: 200), format: format).image { context in
            UIColor.white.setFill(); context.fill(CGRect(x: 0, y: 0, width: 800, height: 200))
            ("分享图片 14:00" as NSString).draw(at: CGPoint(x: 35, y: 45), withAttributes: [.font: UIFont.systemFont(ofSize: 48), .foregroundColor: UIColor.black])
        }
        let (_, files) = try await ItemLoader.load([NSItemProvider(object: image)])
        defer { files.forEach(ImageStaging.remove) }
        let file = try XCTUnwrap(files.first)
        let text = try await OCRService.recognizeFile(ImageStaging.url(for: file))
        XCTAssertTrue(text.contains("14:00"), text)
    }

    @MainActor func testSessionStoreUpdatesAndRestoresDrafts() throws {
        let store = try SessionStore(inMemory: true)
        var session = ImportSession(source: "分享")
        session.text = "待办内容"; session.pendingImages = ["fixture.image"]
        try store.save(session)
        XCTAssertEqual(try store.all().count, 1)
        session.text = "修改后的内容"
        try store.save(session)
        XCTAssertEqual(try store.all().first?.text, "修改后的内容")
        XCTAssertEqual(try store.all().first?.pendingImages.count, 1)
        try store.delete(session.id)
        XCTAssertTrue(try store.all().isEmpty)
    }

    @MainActor func testEventKitCreateUpdateMoveAndRemove() async throws {
        let service = CalendarService()
        try await service.requestAccess()
        let source = service.store.sources.first(where: { $0.sourceType == .local }) ?? service.store.defaultCalendarForNewEvents?.source
        guard let source else { throw XCTSkip("Simulator has no calendar source") }
        let first = EKCalendar(for: .event, eventStore: service.store)
        first.title = "Shike Automated Test A"; first.source = source
        let second = EKCalendar(for: .event, eventStore: service.store)
        second.title = "Shike Automated Test B"; second.source = source
        try service.store.saveCalendar(first, commit: true)
        try service.store.saveCalendar(second, commit: true)
        defer {
            try? service.store.removeCalendar(first, commit: true)
            try? service.store.removeCalendar(second, commit: true)
        }
        service.refresh()
        var draft = EventDraft()
        draft.title = "Native EventKit fixture"
        draft.start = Date().addingTimeInterval(3600); draft.end = draft.start?.addingTimeInterval(1800)
        draft.calendarID = first.calendarIdentifier; draft.reminderMinutes = 15
        let saved = try service.save(draft)
        let snapshots = try await service.events(in: DateInterval(start: draft.start!.addingTimeInterval(-1), end: draft.end!), calendarIDs: [first.calendarIdentifier])
        XCTAssertEqual(snapshots.count, 1)
        XCTAssertEqual(snapshots.first?.title, draft.title)
        let resolved = try service.editableEvent(XCTUnwrap(snapshots.first))
        XCTAssertEqual(resolved.eventIdentifier, saved.eventIdentifier)
        XCTAssertNotNil(saved.eventIdentifier)
        var edit = try service.latest(saved)
        XCTAssertEqual(edit.title, draft.title)
        XCTAssertEqual(edit.reminderMinutes, 15)
        edit.title = "Updated fixture"; edit.location = "Room B"; edit.calendarID = second.calendarIdentifier
        let updated = try service.save(edit, updatingExisting: true)
        let latest = try service.latest(updated)
        XCTAssertEqual(latest.title, "Updated fixture")
        XCTAssertEqual(latest.location, "Room B")
        XCTAssertEqual(latest.calendarID, second.calendarIdentifier)
        let predicate = service.store.predicateForEvents(withStart: draft.start!.addingTimeInterval(-60), end: draft.end!.addingTimeInterval(60), calendars: [first, second])
        XCTAssertEqual(service.store.events(matching: predicate).count, 1, "Editing must not create a second event")
        let event = try XCTUnwrap(service.store.event(withIdentifier: updated.eventIdentifier!))
        try service.store.remove(event, span: .thisEvent)
        XCTAssertThrowsError(try service.latest(updated))
    }
}

private final class ConsentTransport: URLProtocol {
    private static let lock = NSLock()
    private static var count = 0
    static var requestCount: Int { lock.lock(); defer { lock.unlock() }; return count }
    static func reset() { lock.lock(); count = 0; lock.unlock() }
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        Self.lock.lock(); Self.count += 1; Self.lock.unlock()
        let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: ["Content-Type": "application/json"])!
        let body = Data(#"{"choices":[{"message":{"content":"{\"events\":[]}"},"finish_reason":"stop"}]}"#.utf8)
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: body)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

@MainActor private final class MemoryCloudStore: CloudPreferencesStore {
    var accountAvailable = true
    var payload: Data?
    func data(forKey key: String) -> Data? { payload }
    func set(_ data: Data, forKey key: String) { payload = data }
    func synchronize() -> Bool { true }
}

private final class PlanningNativeTransport: URLProtocol {
    private static let lock = NSLock()
    private static var bodies: [String] = []
    private static let question = #"{"kind":"question","message":"每天什么时候方便？","options":["晚上","下午"]}"#
    private static var content = question
    static var requests: [String] { lock.lock(); defer { lock.unlock() }; return bodies }
    static func reset(response: String? = nil) { lock.lock(); bodies = []; content = response ?? question; lock.unlock() }
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        var data = request.httpBody ?? Data()
        if let stream = request.httpBodyStream {
            stream.open(); defer { stream.close() }
            var buffer = [UInt8](repeating: 0, count: 4096)
            while stream.hasBytesAvailable { let count = stream.read(&buffer, maxLength: buffer.count); if count <= 0 { break }; data.append(buffer, count: count) }
        }
        Self.lock.lock(); Self.bodies.append(String(decoding: data, as: UTF8.self)); let content = Self.content; Self.lock.unlock()
        let body = try! JSONSerialization.data(withJSONObject: ["choices": [["message": ["content": content], "finish_reason": "stop"]]])
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: body); client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}
