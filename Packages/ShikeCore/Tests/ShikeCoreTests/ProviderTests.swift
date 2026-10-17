import XCTest
@testable import ShikeCore
import Foundation

final class ProviderTests: XCTestCase {
    override func tearDown() { MockURLProtocol.handler = nil }
    private func client() -> LLMClient {
        let config = URLSessionConfiguration.ephemeral; config.protocolClasses = [MockURLProtocol.self]
        return LLMClient(session: URLSession(configuration: config))
    }
    private func body(_ request: URLRequest) throws -> [String: Any] {
        var data = request.httpBody ?? Data()
        if let stream = request.httpBodyStream {
            stream.open(); defer { stream.close() }
            var buffer = [UInt8](repeating: 0, count: 4096)
            while stream.hasBytesAvailable { let count = stream.read(&buffer, maxLength: buffer.count); if count <= 0 { break }; data.append(buffer, count: count) }
        }
        return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }
    private func extract(_ format: APIFormat) async throws -> [EventDraft] {
        try await client().extract(text: "明天出差", referenceDate: .now, timeZone: TimeZone(identifier: "Asia/Shanghai")!,
                                   configuration: APIConfiguration(baseURL: "https://proxy.example/custom", model: "fixture-model", format: format), apiKey: "fixture-key")
    }
    func testOpenAIEndpointsAndHistoricalFormatMigration() throws {
        let decoder = JSONDecoder()
        let old = try decoder.decode(APIConfiguration.self, from: Data(#"{"baseURL":"https://example.com","model":"old"}"#.utf8))
        XCTAssertEqual(old.format, .openAI)
        XCTAssertEqual(APIFormat.allCases, [.openAI])
        for legacy in ["claude", "gemini", "openAI"] {
            let raw = try JSONSerialization.data(withJSONObject: ["id": "saved-profile", "name": "旧接口", "credentialID": "existing-key-id",
                "configuration": ["baseURL": "https://proxy.example/custom", "model": "original-model", "format": legacy]])
            let profile = try decoder.decode(APIProfile.self, from: raw)
            XCTAssertEqual(profile.id, "saved-profile"); XCTAssertEqual(profile.credentialID, "existing-key-id")
            XCTAssertEqual(profile.configuration.model, "original-model")
            XCTAssertEqual(profile.configuration.baseURL, "https://proxy.example/custom")
            XCTAssertEqual(profile.configuration.format, .openAI)
            XCTAssertEqual(try profile.configuration.endpoint().path, "/custom/chat/completions")
            let rewritten = try JSONSerialization.jsonObject(with: JSONEncoder().encode(profile.configuration)) as? [String: String]
            XCTAssertEqual(rewritten?["format"], "openAI")
        }
        XCTAssertEqual(try APIConfiguration(baseURL: "https://proxy.example", model: "test").endpoint().path, "/v1/chat/completions")
        XCTAssertEqual(try APIConfiguration(baseURL: "https://proxy.example/custom/chat/completions/").modelsEndpoint().path, "/custom/models")
        XCTAssertThrowsError(try decoder.decode(APIFormat.self, from: Data(#""unsupported""#.utf8)))
    }
    func testOpenAIRequestUsesBearerAndChatCompletions() async throws {
        MockURLProtocol.handler = { request in
            XCTAssertEqual(request.url?.path, "/custom/chat/completions")
            XCTAssertNil(request.url?.query)
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer fixture-key")
            XCTAssertNil(request.value(forHTTPHeaderField: "x-api-key"))
            XCTAssertNil(request.value(forHTTPHeaderField: "x-goog-api-key"))
            let payload = try self.body(request)
            XCTAssertEqual(payload["model"] as? String, "fixture-model")
            XCTAssertNotNil(payload["messages"])
            XCTAssertNil(payload["systemInstruction"])
            return (200, Data(#"{"choices":[{"message":{"content":"{\"events\":[]}"},"finish_reason":"stop"}]}"#.utf8))
        }
        let result = try await extract(.openAI); XCTAssertTrue(result.isEmpty)
    }
    func testTruncationAndRefusalNeverReturnEvents() async {
        for response in [
            #"{"choices":[{"message":{"content":"{\"events\":[]}"},"finish_reason":"length"}]}"#,
            #"{"choices":[{"message":{"refusal":"blocked"},"finish_reason":"stop"}]}"#
        ] {
            MockURLProtocol.handler = { _ in (200, Data(response.utf8)) }
            do { _ = try await extract(.openAI); XCTFail("Should reject incomplete/blocked output") } catch { }
        }
    }
    func testOpenAIModelPagination() async throws {
        var count = 0
        MockURLProtocol.handler = { request in
            count += 1
            if count == 2 {
                let query = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems
                XCTAssertEqual(query?.first?.name, "after")
                XCTAssertEqual(query?.first?.value, "next/token")
            }
            let response = count == 1 ? #"{"data":[{"id":"first"}],"has_more":true,"last_id":"next/token"}"# : #"{"data":[{"id":"second"}],"has_more":false}"#
            return (200, Data(response.utf8))
        }
        let result = try await client().listModels(configuration: APIConfiguration(baseURL: "https://example.com"), apiKey: "fixture")
        XCTAssertEqual(result.map(\.id), ["first", "second"]); XCTAssertEqual(count, 2)
    }
    func testForcedCategoryAndCalendarCandidateAllowList() async throws {
        MockURLProtocol.handler = { request in
            let payload = try self.body(request)
            let prompt = try XCTUnwrap((payload["messages"] as? [[String: String]])?.first?["content"])
            XCTAssertTrue(prompt.contains("个人出行")); XCTAssertTrue(prompt.contains("用户已强制指定类别：travel"))
            let content = #"{"events":[{"title":"出差","category":"work","calendarID":"travel-id"},{"title":"恶意候选","calendarID":"not-provided"}]}"#
            return (200, try JSONSerialization.data(withJSONObject: ["choices": [["message": ["content": content], "finish_reason": "stop"]]]))
        }
        let result = try await client().extract(text: "出差", referenceDate: .now, timeZone: .current,
                                                configuration: APIConfiguration(baseURL: "https://example.com", model: "fixture"), apiKey: "fixture",
                                                calendars: [CalendarCandidate(id: "travel-id", name: "个人出行")], forcedCategory: .travel)
        XCTAssertEqual(result.map(\.category), [.travel, .travel])
        XCTAssertEqual(result[0].suggestedCalendarID, "travel-id"); XCTAssertNil(result[1].suggestedCalendarID)
    }
    func testManualCalendarPriorityAndOptOut() {
        let writable: Set<String> = ["personal", "manual", "ai"]
        XCTAssertEqual(CalendarRouting.preferredID(category: .travel, enabled: true, mapping: [:], defaultID: "personal", writableIDs: writable, suggestedID: "ai"), "ai")
        XCTAssertEqual(CalendarRouting.preferredID(category: .travel, enabled: true, mapping: ["travel": "manual"], defaultID: "personal", writableIDs: writable, suggestedID: "ai"), "manual")
        XCTAssertEqual(CalendarRouting.preferredID(category: .travel, enabled: false, mapping: [:], defaultID: "personal", writableIDs: writable, suggestedID: "ai"), "personal")
        XCTAssertEqual(CalendarRouting.preferredID(category: .travel, enabled: true, mapping: [:], defaultID: "personal", writableIDs: writable, suggestedID: "forged"), "personal")
    }
    func testSystemTimeZoneIsDefaultAndExplicitZoneIsPreserved() throws {
        XCTAssertEqual(EventDraft().timeZoneIdentifier, TimeZone.current.identifier)
        XCTAssertEqual(ImportSession().referenceTimeZone, TimeZone.current.identifier)
        let events = try ExtractionDecoder.decode(#"{"events":[{"title":"默认"},{"title":"明确时区","timeZone":"Asia/Tokyo"}]}"#, timeZone: .current)
        XCTAssertEqual(events[0].timeZoneIdentifier, TimeZone.current.identifier)
        XCTAssertEqual(events[1].timeZoneIdentifier, "Asia/Tokyo")
    }
}
