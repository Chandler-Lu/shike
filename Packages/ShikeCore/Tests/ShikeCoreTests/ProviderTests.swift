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
    func testProviderEndpointsAndOldConfigurationMigration() throws {
        let old = try JSONDecoder().decode(APIConfiguration.self, from: Data(#"{"baseURL":"https://example.com","model":"old"}"#.utf8))
        XCTAssertEqual(old.format, .openAI)
        XCTAssertEqual(try APIConfiguration(baseURL: "https://proxy.example/custom/messages", model: "a", format: .claude).endpoint().path, "/custom/messages")
        XCTAssertEqual(try APIConfiguration(baseURL: "https://proxy.example", model: "models/test", format: .gemini).endpoint().path, "/v1beta/models/test:generateContent")
        XCTAssertEqual(try APIConfiguration(baseURL: "https://proxy.example/proxy/v1beta/models/old:generateContent", model: "new", format: .gemini).endpoint().path, "/proxy/v1beta/models/new:generateContent")
        XCTAssertEqual(try APIConfiguration(baseURL: "https://proxy.example/custom", format: .gemini).modelsEndpoint().path, "/custom/models")
        XCTAssertThrowsError(try APIConfiguration(baseURL: "https://proxy.example", model: "../escape", format: .gemini).endpoint())
    }
    func testClaudeRequestAndTextBlocks() async throws {
        MockURLProtocol.handler = { request in
            XCTAssertEqual(request.url?.path, "/custom/messages")
            XCTAssertEqual(request.value(forHTTPHeaderField: "x-api-key"), "fixture-key")
            XCTAssertEqual(request.value(forHTTPHeaderField: "anthropic-version"), "2023-06-01")
            XCTAssertNil(request.value(forHTTPHeaderField: "Authorization"))
            let payload = try self.body(request)
            XCTAssertNotNil(payload["system"]); XCTAssertEqual(payload["max_tokens"] as? Int, 4096)
            XCTAssertNil(payload["response_format"])
            return (200, Data(#"{"content":[{"type":"thinking","thinking":"ignored"},{"type":"text","text":"{\"events\":[]}"}],"stop_reason":"end_turn"}"#.utf8))
        }
        let result = try await extract(.claude); XCTAssertTrue(result.isEmpty)
    }
    func testGeminiRequestDoesNotPutKeyInURLAndIgnoresThoughts() async throws {
        MockURLProtocol.handler = { request in
            XCTAssertEqual(request.url?.path, "/custom/models/fixture-model:generateContent")
            XCTAssertNil(request.url?.query)
            XCTAssertEqual(request.value(forHTTPHeaderField: "x-goog-api-key"), "fixture-key")
            XCTAssertNil(request.value(forHTTPHeaderField: "Authorization"))
            let payload = try self.body(request)
            XCTAssertNotNil(payload["systemInstruction"]); XCTAssertNotNil(payload["contents"])
            XCTAssertEqual((payload["generationConfig"] as? [String: String])?["responseMimeType"], "application/json")
            return (200, Data(#"{"candidates":[{"content":{"parts":[{"thought":true,"text":"not JSON"},{"text":"{\"events\":[]}"}]},"finishReason":"STOP"}]}"#.utf8))
        }
        let result = try await extract(.gemini); XCTAssertTrue(result.isEmpty)
    }
    func testNativeProviderTruncationAndRefusalNeverReturnsEvents() async {
        let responses: [(APIFormat, String)] = [
            (.claude, #"{"content":[{"type":"text","text":"{\"events\":[]}"}],"stop_reason":"max_tokens"}"#),
            (.gemini, #"{"candidates":[{"content":{"parts":[{"text":"{\"events\":[]}"}]},"finishReason":"MAX_TOKENS"}]}"#),
            (.gemini, #"{"promptFeedback":{"blockReason":"SAFETY"}}"#)
        ]
        for (format, response) in responses {
            MockURLProtocol.handler = { _ in (200, Data(response.utf8)) }
            do { _ = try await extract(format); XCTFail("Should reject incomplete/blocked output") } catch { }
        }
    }
    func testClaudeAndGeminiModelPagination() async throws {
        for format in [APIFormat.claude, .gemini] {
            var count = 0
            MockURLProtocol.handler = { request in
                count += 1
                if count == 2 {
                    let query = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems
                    XCTAssertEqual(query?.first?.name, format == .claude ? "after_id" : "pageToken")
                    XCTAssertEqual(query?.first?.value, "next/token")
                }
                let response: String
                if format == .claude {
                    response = count == 1 ? #"{"data":[{"id":"first"}],"has_more":true,"last_id":"next/token"}"# : #"{"data":[{"id":"second"}],"has_more":false}"#
                } else {
                    response = count == 1 ? #"{"models":[{"name":"models/first","displayName":"First"}],"nextPageToken":"next/token"}"# : #"{"models":[{"name":"models/second"}]}"#
                }
                return (200, Data(response.utf8))
            }
            let result = try await client().listModels(configuration: APIConfiguration(baseURL: "https://example.com", format: format), apiKey: "fixture")
            XCTAssertEqual(result.map(\.id), ["first", "second"]); XCTAssertEqual(count, 2)
        }
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
