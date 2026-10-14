import XCTest
@testable import ShikeCore
import Foundation

final class CoreTests: XCTestCase {
    let zone = TimeZone(identifier: "Asia/Shanghai")!

    func testEndpointNormalization() throws {
        for (input, expected) in [
            ("https://example.com", "https://example.com/v1/chat/completions"),
            ("https://example.com/v1/", "https://example.com/v1/chat/completions"),
            ("https://example.com/api/v3", "https://example.com/api/v3/chat/completions"),
            ("https://example.com/chat/completions", "https://example.com/chat/completions")
        ] { XCTAssertEqual(try APIConfiguration(baseURL: input).endpoint().absoluteString, expected) }
    }

    func testEndpointRejectsUnsafeOrAmbiguousAddresses() {
        for input in ["http://example.com", "https://user:password@example.com", "https://example.com?key=secret", "https://example.com#fragment", "example.com", ""] {
            XCTAssertThrowsError(try APIConfiguration(baseURL: input).endpoint(), input)
        }
    }

    func testModelsEndpointUsesSameConfiguredAPIRoot() throws {
        for (base, expected) in [
            ("https://example.com", "https://example.com/v1/models"),
            ("https://example.com/v1/", "https://example.com/v1/models"),
            ("https://example.com/api/v3/chat/completions", "https://example.com/api/v3/models"),
            ("https://example.com/chat/completions", "https://example.com/models")
        ] { XCTAssertEqual(try APIConfiguration(baseURL: base).modelsEndpoint().absoluteString, expected) }
        XCTAssertThrowsError(try APIConfiguration(baseURL: "http://example.com").modelsEndpoint())
    }

    func testCategoryRoutingRespectsOptInAndFallsBackForUnavailableCalendars() {
        let mapping = ["work": "work-calendar", "travel": "deleted-calendar"]
        let writable: Set<String> = ["personal-calendar", "work-calendar"]
        func route(_ category: EventCategory?, enabled: Bool = true, defaultID: String? = "personal-calendar") -> String? {
            CalendarRouting.preferredID(category: category, enabled: enabled, mapping: mapping, defaultID: defaultID, writableIDs: writable)
        }
        XCTAssertEqual(route(.work), "work-calendar")
        XCTAssertEqual(route(.work, enabled: false), "personal-calendar")
        XCTAssertEqual(route(.travel), "personal-calendar")
        XCTAssertEqual(route(.study), "personal-calendar")
        XCTAssertEqual(route(nil), "personal-calendar")
        XCTAssertNil(route(.other, defaultID: "deleted-calendar"))
    }

    func testCategoriesDecodeWithoutBreakingOlderDrafts() throws {
        let drafts = try decode(#"{"events":[{"title":"航班","category":"travel"},{"title":"会议","category":"unrecognized"},{"title":"旧内容"}]}"#)
        XCTAssertEqual(drafts.map(\.category), [.travel, .other, .other])
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(drafts[0])) as? [String: Any])
        object.removeValue(forKey: "category")
        let old = try JSONDecoder().decode(EventDraft.self, from: JSONSerialization.data(withJSONObject: object))
        XCTAssertNil(old.category)
        XCTAssertEqual(old.title, "航班")
    }

    func testPortableCalendarMatchingRequiresUniqueNameAndAccount() {
        let reference = CalendarReference(title: "工作", account: "iCloud")
        XCTAssertEqual(reference.matchingID(in: ["device-two-id": reference]), "device-two-id")
        XCTAssertNil(reference.matchingID(in: ["wrong-account": CalendarReference(title: "工作", account: "Exchange")]))
        XCTAssertNil(reference.matchingID(in: ["one": reference, "two": reference]))
    }

    func testCloudSettingsEncodeReferencesWithoutCredentialContentsOrLocalIDs() throws {
        let snapshot = CloudSettingsSnapshot(configuration: APIConfiguration(baseURL: "https://example.com/v1", model: "chat-model"),
                                             credentialID: "credential-reference", defaultCalendar: CalendarReference(title: "生活", account: "iCloud"),
                                             categoryRoutingEnabled: true, categoryCalendars: ["work": CalendarReference(title: "工作", account: "iCloud")])
        let data = try JSONEncoder().encode(snapshot)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertNil(object["apiKey"]); XCTAssertNil(object["key"]); XCTAssertNil(object["defaultCalendarID"])
        XCTAssertEqual(object["credentialID"] as? String, "credential-reference")
        XCTAssertEqual(try JSONDecoder().decode(CloudSettingsSnapshot.self, from: data), snapshot)
    }

    func testMultipleEventsAndSuggestedEndRequireReview() throws {
        let events = try decode(#"{"events":[{"title":"评审","start":"2026-10-14T14:00:00+08:00","end":null},{"title":"讨论","start":"2026-10-15T09:00:00+08:00","end":"2026-10-15T10:00:00+08:00"}]}"#)
        XCTAssertEqual(events.count, 2)
        XCTAssertEqual(events[0].end!.timeIntervalSince(events[0].start!), 3600)
        XCTAssertTrue(events[0].needsReview)
        XCTAssertFalse(events[1].needsReview)
        XCTAssertFalse(events[0].validationMessages.isEmpty)
        XCTAssertTrue(events[1].validationMessages.isEmpty)
    }

    func testMissingStartNeverFabricatesDate() throws {
        let event = try XCTUnwrap(decode(#"{"events":[{"title":"开会","start":null,"end":null,"needsReview":true,"reviewNotes":["缺少日期"]}]}"#).first)
        XCTAssertNil(event.start); XCTAssertNil(event.end)
        XCTAssertTrue(event.validationMessages.contains("请补充开始日期与时间"))
    }

    func testAllDayUsesCalendarArithmeticAcrossDST() throws {
        let events = try ExtractionDecoder.decode(#"{"events":[{"title":"休息","start":"2026-03-08","allDay":true,"timeZone":"America/New_York"}]}"#, timeZone: zone)
        XCTAssertEqual(events[0].end!.timeIntervalSince(events[0].start!), 23 * 3600)
        XCTAssertFalse(events[0].needsReview)
    }

    func testAllDayMultiDayHasExclusiveEnd() throws {
        let event = try XCTUnwrap(decode(#"{"events":[{"title":"出差","start":"2026-12-30","end":"2027-01-03","allDay":true,"timeZone":"Asia/Shanghai"}]}"#).first)
        XCTAssertEqual(event.end!.timeIntervalSince(event.start!), 4 * 24 * 3600)
    }

    func testInvalidAllDayEndRequiresCorrection() throws {
        let event = try XCTUnwrap(decode(#"{"events":[{"title":"出差","start":"2026-10-14","end":"2026-02-30","allDay":true}]}"#).first)
        XCTAssertNotNil(event.start)
        XCTAssertNil(event.end)
        XCTAssertFalse(event.validationMessages.isEmpty)
    }

    func testOffsetsPreserveInstantsAcrossMidnight() throws {
        let event = try XCTUnwrap(decode(#"{"events":[{"title":"跨时区会议","start":"2026-12-31T23:30:00-05:00","end":"2027-01-01T14:30:00+08:00"}]}"#).first)
        XCTAssertEqual(event.end!.timeIntervalSince(event.start!), 2 * 3600)
    }

    func testAllDayTimezoneChangeKeepsCalendarDates() throws {
        var event = try XCTUnwrap(decode(#"{"events":[{"title":"休假","start":"2026-10-14","end":"2026-10-16","allDay":true,"timeZone":"Asia/Shanghai"}]}"#).first)
        event.setTimeZone("America/New_York")
        var calendar = Calendar(identifier: .gregorian); calendar.timeZone = event.timeZone
        XCTAssertEqual(calendar.component(.day, from: event.start!), 14)
        XCTAssertEqual(calendar.component(.day, from: event.end!), 16)
        XCTAssertEqual(calendar.component(.hour, from: event.start!), 0)
    }

    func testTurningMidnightEndingEventIntoAllDayDoesNotAddDay() throws {
        var event = try XCTUnwrap(decode(#"{"events":[{"title":"工作","start":"2026-10-14T12:00:00+08:00","end":"2026-10-15T00:00:00+08:00","timeZone":"Asia/Shanghai"}]}"#).first)
        event.setAllDay(true)
        XCTAssertEqual(event.end!.timeIntervalSince(event.start!), 24 * 3600)
    }

    func testMalformedOrUnzonedDatesDoNotBecomeValidEvents() throws {
        let events = try decode(#"{"events":[{"title":"无时区","start":"2026-10-14T14:00:00","end":"2026-10-14T15:00:00"},{"title":"无效日期","start":"2026-02-30","allDay":true},{"title":"坏结束时间","start":"2026-10-14T14:00:00+08:00","end":"invalid"}]}"#)
        XCTAssertNil(events[0].start); XCTAssertNil(events[1].start); XCTAssertNil(events[2].end)
    }

    func testUnknownTimeZoneAndReminderNeedReview() throws {
        let event = try XCTUnwrap(decode(#"{"events":[{"title":"会议","start":"2026-10-14T14:00:00+08:00","end":"2026-10-14T15:00:00+08:00","timeZone":"Mars/Base","reminderMinutes":47}]}"#).first)
        XCTAssertEqual(event.timeZoneIdentifier, "Asia/Shanghai")
        XCTAssertTrue(event.needsReview); XCTAssertNil(event.reminderMinutes)
    }

    func testEmptyResultsAndFencedJSON() throws {
        XCTAssertTrue(try decode("{\"events\":[]}").isEmpty)
        XCTAssertTrue(try decode("```json\n{\"events\":[]}\n```").isEmpty)
    }

    func testBadSchemaAndProseRejected() {
        for text in ["hello", "{\"events\": [{\"name\":\"会议\"}]}", "{\"events\":null}"] {
            XCTAssertThrowsError(try decode(text))
        }
    }

    func testDraftValidationBlocksInvalidTimesAndInterruptedWrites() {
        var event = EventDraft()
        event.title = "日程"; event.start = Date(timeIntervalSince1970: 100); event.end = Date(timeIntervalSince1970: 99)
        XCTAssertTrue(event.validationMessages.contains("结束时间必须晚于开始时间"))
        event.end = Date(timeIntervalSince1970: 200)
        event.saveAttemptInProgress = true
        XCTAssertFalse(event.validationMessages.isEmpty)
    }

    func testSessionRoundTripPreservesRecoveryAndCalendarLinks() throws {
        var session = ImportSession(source: "分享")
        session.text = "会议"; session.pendingImages = ["fixture.image"]
        var event = EventDraft(); event.title = "会议"; event.eventIdentifier = "fixture-event-id"; event.saveAttemptInProgress = true
        session.drafts = [event]
        let restored = try JSONDecoder().decode(ImportSession.self, from: JSONEncoder().encode(session))
        XCTAssertEqual(session, restored)
    }

    func testSaveValidationSeparatesSuggestionsFromRequiredCorrections() {
        var draft = EventDraft()
        draft.needsReview = true
        draft.saveAttemptInProgress = true
        let issues = draft.saveValidationMessages(writableCalendarIDs: ["work"], confirmingSuggestions: true)
        XCTAssertTrue(issues.contains("请填写日程名称"))
        XCTAssertTrue(issues.contains("请补充开始日期与时间"))
        XCTAssertTrue(issues.contains("请补充结束日期与时间"))
        XCTAssertTrue(issues.contains("请选择目标日历"))
        XCTAssertTrue(issues.contains("上次保存被中断，请先核对系统日历"))
        XCTAssertFalse(issues.contains("请核对时间建议"))
        draft.title = "会议"; draft.start = .now; draft.end = draft.start!.addingTimeInterval(3600)
        draft.calendarID = "missing"; draft.saveAttemptInProgress = false
        XCTAssertEqual(draft.saveValidationMessages(writableCalendarIDs: ["work"], confirmingSuggestions: true), ["目标日历已失效或不可写，请重新选择日历"])
        draft.calendarID = "work"
        XCTAssertEqual(draft.saveValidationMessages(writableCalendarIDs: ["work"]), ["请核对时间建议"])
        XCTAssertTrue(draft.saveValidationMessages(writableCalendarIDs: ["work"], confirmingSuggestions: true).isEmpty)
        draft.end = draft.start
        XCTAssertEqual(draft.saveValidationMessages(writableCalendarIDs: ["work"], confirmingSuggestions: true), ["结束时间必须晚于开始时间"])
    }

    private func decode(_ text: String) throws -> [EventDraft] { try ExtractionDecoder.decode(text, timeZone: zone) }
}

final class MockURLProtocol: URLProtocol {
    static var handler: ((URLRequest) throws -> (Int, Data))?
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        do {
            let (code, data) = try Self.handler!(request)
            client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: code, httpVersion: nil, headerFields: nil)!, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data); client?.urlProtocolDidFinishLoading(self)
        } catch { client?.urlProtocol(self, didFailWithError: error) }
    }
    override func stopLoading() {}
}

final class LLMClientTests: XCTestCase {
    func testModelListRequestAndAllReturnedIDs() async throws {
        MockURLProtocol.handler = { request in
            XCTAssertEqual(request.url?.absoluteString, "https://example.com/v1/models")
            XCTAssertEqual(request.httpMethod, "GET")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer fixture-key")
            XCTAssertNil(request.httpBody)
            return (200, Data(#"{"data":[{"id":"chat-10","owned_by":"provider"},{"id":"chat-2"},{"id":"embedding-x"},{"id":"chat-2"},{"id":"  "}]}"#.utf8))
        }
        let result = try await client().listModels(configuration: APIConfiguration(baseURL: "https://example.com/v1/chat/completions"), apiKey: " fixture-key ")
        XCTAssertEqual(result.map(\.id), ["chat-2", "chat-10", "embedding-x"])
        XCTAssertEqual(result[1].ownedBy, "provider")
    }

    func testModelListPaginationCollectsEveryPage() async throws {
        var requests = 0
        MockURLProtocol.handler = { request in
            requests += 1
            if requests == 1 { return (200, Data(#"{"data":[{"id":"model-a"}],"has_more":true,"last_id":"cursor/a"}"#.utf8)) }
            XCTAssertEqual(URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems?.first?.value, "cursor/a")
            return (200, Data(#"{"data":[{"id":"model-b"}],"has_more":false}"#.utf8))
        }
        let result = try await client().listModels(configuration: APIConfiguration(baseURL: "https://example.com"), apiKey: "fixture-key")
        XCTAssertEqual(result.map(\.id), ["model-a", "model-b"])
        XCTAssertEqual(requests, 2)
    }

    func testModelListErrorsPreserveManualEntryAndHideResponse() async {
        for (status, expected) in [(401, "认证失败"), (404, "自定义模型"), (429, "受限")] {
            MockURLProtocol.handler = { _ in (status, Data("sensitive-provider-body".utf8)) }
            do { _ = try await client().listModels(configuration: APIConfiguration(baseURL: "https://example.com"), apiKey: "fixture-key"); XCTFail("Expected error") }
            catch { XCTAssertTrue(error.localizedDescription.contains(expected)); XCTAssertFalse(error.localizedDescription.contains("sensitive")) }
        }
    }

    func testModelListEmptyAndMalformedResponses() async throws {
        MockURLProtocol.handler = { _ in (200, Data(#"{"data":[]}"#.utf8)) }
        let result = try await client().listModels(configuration: APIConfiguration(baseURL: "https://example.com"), apiKey: "fixture-key")
        XCTAssertTrue(result.isEmpty)
        MockURLProtocol.handler = { _ in (200, Data(#"{"models":["a"]}"#.utf8)) }
        do { _ = try await client().listModels(configuration: APIConfiguration(baseURL: "https://example.com"), apiKey: "fixture-key"); XCTFail("Expected malformed response") }
        catch { XCTAssertTrue(error.localizedDescription.contains("格式不兼容")) }
    }

    func testModelListRequiresKeyAndHandlesTimeoutAndCancellation() async {
        MockURLProtocol.handler = { _ in XCTFail("Empty key must not issue a request"); return (200, Data()) }
        do { _ = try await client().listModels(configuration: APIConfiguration(baseURL: "https://example.com"), apiKey: " "); XCTFail("Expected no key error") } catch { }
        MockURLProtocol.handler = { _ in throw URLError(.timedOut) }
        do { _ = try await client().listModels(configuration: APIConfiguration(baseURL: "https://example.com"), apiKey: "fixture"); XCTFail("Expected timeout") }
        catch { XCTAssertTrue(error.localizedDescription.contains("超时")) }
        MockURLProtocol.handler = { _ in throw URLError(.cancelled) }
        do { _ = try await client().listModels(configuration: APIConfiguration(baseURL: "https://example.com"), apiKey: "fixture"); XCTFail("Expected cancellation") }
        catch { XCTAssertTrue(error is CancellationError) }
    }

    func testModelListRepeatingCursorDoesNotReturnPartialResults() async {
        MockURLProtocol.handler = { _ in (200, Data(#"{"data":[{"id":"model-a"}],"has_more":true}"#.utf8)) }
        do { _ = try await client().listModels(configuration: APIConfiguration(baseURL: "https://example.com"), apiKey: "fixture-key"); XCTFail("Expected pagination error") }
        catch { XCTAssertTrue(error.localizedDescription.contains("分页异常")) }
    }

    private func client() -> LLMClient {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [MockURLProtocol.self]
        return LLMClient(session: URLSession(configuration: config))
    }
    private func response(content: String = "{\"events\":[]}", finish: String = "stop") -> Data {
        try! JSONSerialization.data(withJSONObject: ["choices": [["message": ["content": content], "finish_reason": finish]]])
    }
    private func extract(_ client: LLMClient) async throws -> [EventDraft] {
        try await client.extract(text: "明天开会", referenceDate: Date(timeIntervalSince1970: 1791849600),
                                 timeZone: TimeZone(identifier: "Asia/Shanghai")!,
                                 configuration: APIConfiguration(baseURL: "https://example.com/v1", model: "test-model"), apiKey: "test-only-key")
    }
    override func tearDown() { MockURLProtocol.handler = nil }

    func testRequestContainsContextAndPlainTextOnly() async throws {
        let bytes = response()
        MockURLProtocol.handler = { request in
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer test-only-key")
            let body: Data
            if let data = request.httpBody { body = data }
            else {
                let stream = try XCTUnwrap(request.httpBodyStream); stream.open(); defer { stream.close() }
                var result = Data(); var buffer = [UInt8](repeating: 0, count: 4096)
                while stream.hasBytesAvailable { let n = stream.read(&buffer, maxLength: buffer.count); if n <= 0 { break }; result.append(buffer, count: n) }
                body = result
            }
            let payload = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
            XCTAssertEqual(payload["model"] as? String, "test-model")
            let messages = try XCTUnwrap(payload["messages"] as? [[String: String]])
            XCTAssertTrue(messages[0]["content"]!.contains("Asia/Shanghai"))
            XCTAssertEqual(messages[1]["content"], "明天开会")
            XCTAssertNotNil(payload["response_format"])
            return (200, bytes)
        }
        let result = try await extract(client()); XCTAssertTrue(result.isEmpty)
    }

    func testExplicitUnsupportedJSONModeRetriesOnce() async throws {
        let success = response(); var count = 0
        MockURLProtocol.handler = { _ in
            count += 1
            return count == 1 ? (400, Data(#"{"error":{"message":"response_format json_object not supported"}}"#.utf8)) : (200, success)
        }
        _ = try await extract(client()); XCTAssertEqual(count, 2)
    }

    func testAuthenticationFailureDoesNotRetryOrLeakProviderResponse() async {
        var count = 0
        MockURLProtocol.handler = { _ in count += 1; return (401, Data("sensitive-provider-body".utf8)) }
        do { _ = try await extract(client()); XCTFail("Expected rejection") }
        catch { XCTAssertTrue(error.localizedDescription.contains("认证失败")); XCTAssertFalse(error.localizedDescription.contains("sensitive")) }
        XCTAssertEqual(count, 1)
    }

    func testUnrelatedBadRequestDoesNotDowngrade() async {
        var count = 0
        MockURLProtocol.handler = { _ in count += 1; return (400, Data("invalid model".utf8)) }
        do { _ = try await extract(client()); XCTFail("Expected rejection") } catch {}
        XCTAssertEqual(count, 1)
    }

    func testTruncationNeverReturnsPartialEvents() async {
        let data = response(content: "{\"events\":[]}", finish: "length")
        MockURLProtocol.handler = { _ in (200, data) }
        do { _ = try await extract(client()); XCTFail("Expected truncation error") }
        catch { XCTAssertTrue(error.localizedDescription.contains("截断")) }
    }

    func testTimeoutIsActionable() async {
        MockURLProtocol.handler = { _ in throw URLError(.timedOut) }
        do { _ = try await extract(client()); XCTFail("Expected timeout") }
        catch { XCTAssertTrue(error.localizedDescription.contains("超时")) }
    }
}
