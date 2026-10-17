import XCTest
@testable import ShikeCore

final class StructuredOutputTests: XCTestCase {
    private let zone = TimeZone(identifier: "Asia/Shanghai")!
    override func tearDown() { MockURLProtocol.handler = nil }

    func testIndependentPromptDefaultsLimitsAndLegacySnapshot() throws {
        var settings = PromptSettings()
        try settings.set("  只提取明确事项  ", for: .extraction)
        XCTAssertEqual(settings.text(for: .extraction), "只提取明确事项")
        XCTAssertEqual(settings.text(for: .planning), PromptPurpose.planning.defaultText)
        try settings.set(PromptPurpose.extraction.defaultText, for: .extraction)
        XCTAssertTrue(settings.isDefault)
        try settings.set(" ", for: .planning); XCTAssertTrue(settings.isDefault)
        XCTAssertThrowsError(try settings.set(String(repeating: "x", count: 12001), for: .extraction))
        let old = CloudSettingsSnapshot(configuration: APIConfiguration(), credentialID: nil, defaultCalendar: nil, categoryRoutingEnabled: false, categoryCalendars: [:])
        let decoded = try JSONDecoder().decode(CloudSettingsSnapshot.self, from: JSONEncoder().encode(old))
        XCTAssertNil(decoded.promptSettings)
    }

    func testCustomPromptsReachCorrectRequestAndRetainStructuredProtocol() async throws {
        let configuration = URLSessionConfiguration.ephemeral; configuration.protocolClasses = [MockURLProtocol.self]
        let session = URLSession(configuration: configuration); defer { session.invalidateAndCancel() }
        let client = LLMClient(session: session)
        let prompts = PromptSettings(extraction: "extract-marker", planning: "plan-marker")
        let api = APIConfiguration(baseURL: "https://example.com", model: "fixture")
        var requestCount = 0
        MockURLProtocol.handler = { request in
            var data = request.httpBody ?? Data()
            if let stream = request.httpBodyStream {
                stream.open(); defer { stream.close() }
                var buffer = [UInt8](repeating: 0, count: 4096)
                while stream.hasBytesAvailable { let count = stream.read(&buffer, maxLength: buffer.count); if count <= 0 { break }; data.append(buffer, count: count) }
            }
            let body = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
            let system = try XCTUnwrap((body["messages"] as? [[String: String]])?.first?["content"])
            XCTAssertTrue(system.hasPrefix(requestCount == 0 ? "extract-marker" : "plan-marker"))
            XCTAssertTrue(system.contains("输出协议")); XCTAssertTrue(system.contains("reviewNotes"))
            XCTAssertFalse(system.contains(requestCount == 0 ? "plan-marker" : "extract-marker"))
            let content = requestCount == 0 ? #"{"events":[]}"# : #"{"kind":"question","message":"何时方便？","options":[],"events":[]}"#
            requestCount += 1
            return (200, try JSONSerialization.data(withJSONObject: ["choices": [["message": ["content": content], "finish_reason": "stop"]]]))
        }
        _ = try await client.extract(text: "事项", referenceDate: .now, timeZone: zone, configuration: api, apiKey: "fixture", prompts: prompts)
        _ = try await client.plan(conversation: PlanningConversation(goal: "读书"), drafts: [], timeZone: zone, referenceDate: .now, available: nil, configuration: api, apiKey: "fixture", prompts: prompts)
        XCTAssertEqual(requestCount, 2)
    }

    func testProseAndFencesPreserveBracesQuotesAndNewlinesInsideText() throws {
        let title = "讨论 {草稿} 和 \"计划\""
        let notes = "第一行\n[第二行] 路径 \\ 结尾"
        let data = try JSONSerialization.data(withJSONObject: ["events": [["title": title, "notes": notes]]])
        let text = "以下是提取结果：\n```json\n" + String(decoding: data, as: UTF8.self) + "\n```\n请核对。"
        let result = try ExtractionDecoder.decode(text, timeZone: zone)
        XCTAssertEqual(result.count, 1)
        XCTAssertEqual(result[0].title, title); XCTAssertEqual(result[0].notes, notes)
    }

    func testLeadingThinkingBlockIsNotMistakenForFinalEvents() throws {
        let content = "<think>例子 {\"events\":[{\"title\":\"不要导入\"}]}，需要继续分析。</think>\n{\"events\":[{\"title\":\"实际安排\"}]}"
        XCTAssertEqual(try ExtractionDecoder.decode(content, timeZone: zone).map(\.title), ["实际安排"])
        XCTAssertThrowsError(try ExtractionDecoder.decode("<think>未完成 {\"events\":[]}", timeZone: zone))
    }

    func testBareArrayAndUnambiguousScalarDifferences() throws {
        let content = #"[{"title":"阅读","start":"2026-10-15T19:00:00+08:00","end":"2026-10-15T19:30:00+08:00","allDay":"false","needsReview":"true","reminderMinutes":"15","reviewNotes":"需要核对时长"}]"#
        let event = try XCTUnwrap(ExtractionDecoder.decode(content, timeZone: zone).first)
        XCTAssertFalse(event.isAllDay); XCTAssertTrue(event.needsReview)
        XCTAssertEqual(event.reminderMinutes, 15); XCTAssertEqual(event.reviewNotes, ["需要核对时长"])
        XCTAssertEqual(event.end!.timeIntervalSince(event.start!), 1800)
        XCTAssertTrue(try ExtractionDecoder.decode("[]", timeZone: zone).isEmpty)
    }

    func testIncompleteAndAmbiguousResponsesNeverImportPartialEvents() {
        for text in [
            #"{"events":[{"title":"已完整的一条"},{"title":"没写完""#,
            #"{"events":[]} 然后 {"events":[{"title":"另一方案"}]}"#,
            #"[ {"title":"已完整的一条"}"#,
            #"{"events":[{"title":"x"}]"#,
            #"{"events":[{"title":"x","allDay":"可能"}]}"#,
            #"{"events":[{"title":"x","start":1792000000}]}"#,
            #"{"events":[{"title":"x","notes":{"unknown":"value"}}]}"#
        ] { XCTAssertThrowsError(try ExtractionDecoder.decode(text, timeZone: zone), text) }
    }

    func testTolerantEnvelopeDoesNotInferInvalidOrUnzonedDates() throws {
        let events = try ExtractionDecoder.decode(#"结果： [{"title":"缺偏移","start":"2026-10-14T14:00:00"},{"title":"错误日期","start":"2026-02-30","allDay":"true"}]"#, timeZone: zone)
        XCTAssertNil(events[0].start); XCTAssertNil(events[1].start)
        XCTAssertTrue(events.allSatisfy { !$0.validationMessages.isEmpty })
    }

    func testPlanningQuestionAndProposalAllowPresentationWrappers() throws {
        let question = try PlanningReply.decode(#"请回答： {"kind":"question","message":"每次多久？","options":["30 分钟"],"events":[]}"#, timeZone: zone)
        XCTAssertEqual(question.kind, .question); XCTAssertEqual(question.options, ["30 分钟"])
        let proposal = try PlanningReply.decode("```json\n" + #"{"kind":"proposal","message":"安排一次阅读","options":[],"events":[{"title":"阅读","needsReview":"true","reviewNotes":"确认时间"}]}"# + "\n```", timeZone: zone)
        XCTAssertEqual(proposal.drafts.count, 1); XCTAssertTrue(proposal.drafts[0].needsReview)
        XCTAssertThrowsError(try PlanningReply.decode(#"{"kind":"question|proposal|unavailable","message":"x","events":[]}"#, timeZone: zone))
    }

    func testAllProvidersUseTolerantDecoderWithoutAdditionalNetworkCalls() async throws {
        let configuration = URLSessionConfiguration.ephemeral; configuration.protocolClasses = [MockURLProtocol.self]
        let session = URLSession(configuration: configuration); defer { session.invalidateAndCancel() }
        let client = LLMClient(session: session)
        for format in APIFormat.allCases {
            var requests = 0
            MockURLProtocol.handler = { _ in
                requests += 1
                let content = "已整理：\n```json\n{\"events\":[{\"title\":\"阅读\",\"allDay\":\"false\"}]}\n```"
                let response: [String: Any]
                switch format {
                case .openAI: response = ["choices": [["message": ["content": content], "finish_reason": "stop"]]]
                }
                return (200, try JSONSerialization.data(withJSONObject: response))
            }
            let events = try await client.extract(text: "阅读", referenceDate: .now, timeZone: zone,
                configuration: APIConfiguration(baseURL: "https://example.com", model: "fixture", format: format), apiKey: "fixture")
            XCTAssertEqual(events.map(\.title), ["阅读"]); XCTAssertEqual(requests, 1)
        }
    }

    func testFormatErrorsDoNotEchoPrivateModelOutput() {
        do {
            _ = try ExtractionDecoder.decode("private-sensitive-text, not JSON", timeZone: zone)
            XCTFail("Expected a format error")
        } catch {
            XCTAssertFalse(error.localizedDescription.contains("private-sensitive-text"))
            XCTAssertFalse(error.localizedDescription.contains("支持 JSON 输出的模型"))
            XCTAssertTrue(error.localizedDescription.contains("原文已保留"))
        }
    }
}
