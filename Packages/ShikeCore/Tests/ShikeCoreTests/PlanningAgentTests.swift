import XCTest
@testable import ShikeCore

final class PlanningAgentTests: XCTestCase {
    private let zone = TimeZone(identifier: "Asia/Shanghai")!
    private func client(policy: LLMRequestPolicy = .init()) -> LLMClient {
        let config = URLSessionConfiguration.ephemeral; config.protocolClasses = [MockURLProtocol.self]
        return LLMClient(session: URLSession(configuration: config), policy: policy)
    }
    private func envelope(_ content: String, _ format: APIFormat = .openAI) throws -> Data {
        let value: [String: Any]
        switch format {
        case .openAI: value = ["choices": [["message": ["content": content], "finish_reason": "stop"]]]
        }
        return try JSONSerialization.data(withJSONObject: value)
    }
    private func requestData(_ request: URLRequest) -> Data {
        if let data = request.httpBody { return data }
        guard let stream = request.httpBodyStream else { return Data() }
        stream.open(); defer { stream.close() }
        var data = Data(), buffer = [UInt8](repeating: 0, count: 4096)
        while stream.hasBytesAvailable {
            let count = stream.read(&buffer, maxLength: buffer.count)
            if count <= 0 { break }; data.append(buffer, count: count)
        }
        return data
    }
    private func run(_ tools: FixtureSearchTools, conversation: PlanningConversation? = nil, format: APIFormat = .openAI,
                     allowed: @escaping @Sendable () async -> Bool = { true },
                     checkpoint: @escaping @Sendable (PlanningResearch) async throws -> Void = { _ in }) async throws -> PlanningReply {
        let conversation = conversation ?? PlanningConversation(goal: "周六去北京旅行一天", timeZone: zone)
        return try await client().plan(conversation: conversation, drafts: [], timeZone: zone, referenceDate: .now,
            available: nil, configuration: APIConfiguration(baseURL: "https://model.example/v1", model: "fixture", format: format),
            apiKey: "model-key", research: PlanningResearchRuntime(tools: tools, isAllowed: allowed, checkpoint: checkpoint))
    }
    func testSearchReadAndCitationsAcrossAllModelFormats() async throws {
        defer { MockURLProtocol.handler = nil }
        for format in APIFormat.allCases {
            let tools = FixtureSearchTools(), saved = ResearchCheckpoints()
            var count = 0
            MockURLProtocol.handler = { request in
                count += 1
                let data = self.requestData(request), text = String(decoding: data, as: UTF8.self).replacingOccurrences(of: "\\/", with: "/")
                XCTAssertTrue(text.contains("Asia/Shanghai")); XCTAssertFalse(text.contains("search-key"))
                let content: String
                switch count {
                case 1: content = #"{"kind":"tools","tools":[{"name":"search","query":"北京 故宫 官方 开放时间"}]}"#
                case 2:
                    XCTAssertTrue(text.contains("fixture-source"))
                    content = #"{"kind":"tools","tools":[{"name":"read","sourceID":"fixture-source"}]}"#
                default:
                    XCTAssertTrue(text.contains("网页正文 marker"))
                    content = #"{"kind":"proposal","message":"按开放时间安排","options":[],"sourceIDs":["fixture-source"],"events":[{"title":"游览","start":"2026-10-24T08:00:00+08:00","end":"2026-10-24T10:00:00+08:00","timeZone":"Asia/Shanghai","needsReview":true}]}"#
                }
                return (200, try self.envelope(content, format))
            }
            let reply = try await run(tools, format: format, checkpoint: { await saved.append($0) })
            XCTAssertEqual(count, 3); XCTAssertEqual(reply.sourceIDs, ["fixture-source"])
            XCTAssertEqual(reply.research?.sources.first?.kind, .page)
            let calls = await tools.calls; XCTAssertEqual(calls, ["search", "read"])
            let checkpoints = await saved.values; XCTAssertEqual(checkpoints.count, 3)
            XCTAssertEqual(reply.drafts.first?.start, ISO8601DateFormatter().date(from: "2026-10-24T00:00:00Z"))
        }
    }
    func testOrdinaryGoalUsesOneModelCallAndNoTools() async throws {
        defer { MockURLProtocol.handler = nil }
        var count = 0
        MockURLProtocol.handler = { _ in
            count += 1
            return (200, try self.envelope(#"{"kind":"question","message":"想读哪本书？","events":[]}"#))
        }
        let tools = FixtureSearchTools()
        _ = try await run(tools, conversation: PlanningConversation(goal: "每晚读书"))
        XCTAssertEqual(count, 1)
        let calls = await tools.calls; XCTAssertTrue(calls.isEmpty)
    }
    func testDuplicateSearchIsReusedAndLoopStopsAtFourGenerations() async throws {
        defer { MockURLProtocol.handler = nil }
        var count = 0
        MockURLProtocol.handler = { request in
            count += 1
            if count == 4 {
                XCTAssertTrue(String(decoding: self.requestData(request), as: UTF8.self).contains("toolsAllowed\\\":false"))
                return (200, try self.envelope(#"{"kind":"question","message":"愿意调整游览日期吗？","events":[]}"#))
            }
            return (200, try self.envelope(#"{"kind":"tools","tools":[{"name":"search","query":"北京 开放时间"},{"name":"search","query":"北京  开放时间"}]}"#))
        }
        let tools = FixtureSearchTools()
        _ = try await run(tools)
        XCTAssertEqual(count, 4)
        let calls = await tools.calls; XCTAssertEqual(calls, ["search"])
    }
    func testUnknownToolsAndForgedSourcesNeverExecute() async throws {
        defer { MockURLProtocol.handler = nil }
        for invalid in [#"{"kind":"tools","tools":[{"name":"deleteCalendar"}]}"#,
                        #"{"kind":"tools","tools":[{"name":"read","sourceID":"https://localhost/private"}]}"#,
                        #"{"kind":"question","message":"请选择","sourceIDs":["made-up"]}"#] {
            var count = 0
            MockURLProtocol.handler = { _ in count += 1; return (200, try self.envelope(invalid)) }
            let tools = FixtureSearchTools()
            do { _ = try await run(tools); XCTFail("invalid action accepted") } catch {}
            XCTAssertEqual(count, 2)
            let calls = await tools.calls; XCTAssertTrue(calls.isEmpty)
        }
    }
    func testSearchFailureStillProducesExplicitlyUnverifiedProposal() async throws {
        defer { MockURLProtocol.handler = nil }
        var count = 0
        MockURLProtocol.handler = { _ in
            count += 1
            return (200, try self.envelope(count == 1
                ? #"{"kind":"tools","tools":[{"name":"search","query":"北京 开放时间"}]}"#
                : #"{"kind":"proposal","message":"先给出参考安排","events":[{"title":"游览","needsReview":false}]}"#))
        }
        let tools = FixtureSearchTools(fails: true)
        let reply = try await run(tools)
        XCTAssertTrue(reply.message.contains("搜索频率或额度受限"))
        XCTAssertEqual(reply.drafts.first?.needsReview, true)
    }
    func testConsentRevocationStopsToolsWithoutLosingConversation() async throws {
        defer { MockURLProtocol.handler = nil }
        var count = 0
        MockURLProtocol.handler = { _ in
            count += 1
            return (200, try self.envelope(count == 1
                ? #"{"kind":"tools","tools":[{"name":"search","query":"北京"}]}"#
                : #"{"kind":"question","message":"从哪个位置出发？"}"#))
        }
        let tools = FixtureSearchTools()
        let reply = try await run(tools, allowed: { false })
        XCTAssertTrue(reply.message.contains("联网搜索已关闭"))
        let calls = await tools.calls; XCTAssertTrue(calls.isEmpty)
    }
    func testCheckpointCancellationIsNeverRetriedAsMalformedOutput() async throws {
        defer { MockURLProtocol.handler = nil }
        var count = 0
        MockURLProtocol.handler = { _ in count += 1; return (200, try self.envelope(#"{"kind":"question","message":"几点出发？"}"#)) }
        do { _ = try await run(FixtureSearchTools(), checkpoint: { _ in throw CancellationError() }); XCTFail() }
        catch { XCTAssertTrue(error is CancellationError) }
        XCTAssertEqual(count, 1)
    }
    func testSuccessfulResearchSurvivesLaterModelFailureAndCanBeReused() async throws {
        defer { MockURLProtocol.handler = nil }
        let saved = ResearchCheckpoints(); var count = 0
        MockURLProtocol.handler = { _ in
            count += 1
            if count > 1 { return (504, Data()) }
            return (200, try self.envelope(#"{"kind":"tools","tools":[{"name":"search","query":"北京 开放时间"}]}"#))
        }
        let tools = FixtureSearchTools()
        do { _ = try await run(tools, checkpoint: { await saved.append($0) }); XCTFail() } catch {}
        let values = await saved.values
        XCTAssertEqual(values.last?.sources.count, 1)
        XCTAssertEqual(count, 2, "network failure must not cause an extra generation")
    }
    func testPreviouslyAnsweredQuestionIsCorrectedWithinAgentBudget() async throws {
        defer { MockURLProtocol.handler = nil }
        var conversation = PlanningConversation(goal: "读书")
        conversation.turns = [PlanningTurn(role: "assistant", text: "每次多久？"), PlanningTurn(role: "user", text: "半小时")]
        var count = 0
        MockURLProtocol.handler = { _ in
            count += 1
            return (200, try self.envelope(count == 1 ? #"{"kind":"question","message":"每次多久？"}"# : #"{"kind":"question","message":"晚上几点方便？"}"#))
        }
        let reply = try await run(FixtureSearchTools(), conversation: conversation)
        XCTAssertEqual(count, 2); XCTAssertEqual(reply.message, "晚上几点方便？")
    }
    func testModelAuthorizationIsRecheckedBetweenToolSteps() async throws {
        let gate = ModelGate(), saved = ResearchCheckpoints(), tools = FixtureSearchTools()
        var generations = 0
        do {
            _ = try await PlanningAgent.run(conversation: PlanningConversation(goal: "北京"), timeZone: zone,
                runtime: PlanningResearchRuntime(tools: tools, checkpoint: { await saved.append($0) }, beforeModel: {
                    if await gate.rejectNext() { throw SearchToolError.disabled }
                }), progress: { _ in }, remaining: { 300 }, generate: { _, _ in
                    generations += 1
                    return #"{"kind":"tools","tools":[{"name":"search","query":"北京 开放时间"}]}"#
                })
            XCTFail()
        } catch { XCTAssertTrue(error is SearchToolError) }
        XCTAssertEqual(generations, 1)
        let sources = await saved.values.last?.sources; XCTAssertEqual(sources?.count, 1)
    }
    func testFollowUpReusesSourcesAndExplicitRefreshQueriesAgain() async throws {
        let tools = FixtureSearchTools()
        var plan = PlanningConversation(goal: "北京")
        for refresh in [false, false, true] {
            var generation = 0
            let reply = try await PlanningAgent.run(conversation: plan, timeZone: zone,
                runtime: PlanningResearchRuntime(tools: tools), progress: { _ in }, remaining: { 300 }, generate: { _, _ in
                    generation += 1
                    if generation == 1 { return "{\"kind\":\"tools\",\"tools\":[{\"name\":\"search\",\"query\":\"北京 开放时间\",\"refresh\":\(refresh)}]}" }
                    return #"{"kind":"question","message":"从哪里出发？","sourceIDs":["fixture-source"]}"#
                })
            plan.research = reply.research
        }
        let calls = await tools.calls; XCTAssertEqual(calls, ["search", "search"])
        plan.start = plan.start.addingTimeInterval(86400)
        _ = try await PlanningAgent.run(conversation: plan, timeZone: zone,
            runtime: PlanningResearchRuntime(tools: tools), progress: { _ in }, remaining: { 300 }, generate: { input, _ in
                let object = try JSONSerialization.jsonObject(with: Data(input.utf8)) as! [String: Any]
                XCTAssertTrue((object["sources"] as! [Any]).isEmpty)
                return #"{"kind":"question","message":"几点出发？"}"#
            })
    }
    func testAgentHonorsSharedDeadlineBeforeGenerating() async throws {
        let tools = FixtureSearchTools()
        do {
            _ = try await PlanningAgent.run(conversation: PlanningConversation(goal: "读书"), timeZone: zone,
                runtime: PlanningResearchRuntime(tools: tools), progress: { _ in }, remaining: { 0 }, generate: { _, _ in XCTFail(); return "" })
            XCTFail()
        } catch {}
        let calls = await tools.calls; XCTAssertTrue(calls.isEmpty)
    }
}

private actor FixtureSearchTools: SearchProvider {
    var calls: [String] = []
    let fails: Bool
    init(fails: Bool = false) { self.fails = fails }
    func search(_ query: String) async throws -> [PlanningSource] {
        calls.append("search")
        if fails { throw SearchToolError.unavailable("搜索频率或额度受限，请稍后重试。") }
        return [PlanningSource(id: "fixture-source", title: "官方开放时间", url: URL(string: "https://www.dpm.org.cn/Home.html")!, content: "搜索摘要 marker")]
    }
    func read(_ source: PlanningSource) async throws -> PlanningSource {
        calls.append("read")
        var result = source; result.kind = .page; result.content = "网页正文 marker"
        return result
    }
}
private actor ResearchCheckpoints {
    var values: [PlanningResearch] = []
    func append(_ value: PlanningResearch) { values.append(value) }
}

private actor ModelGate {
    private var calls = 0
    func rejectNext() -> Bool { calls += 1; return calls > 1 }
}
