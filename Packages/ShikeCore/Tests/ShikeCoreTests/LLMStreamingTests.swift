import XCTest
@testable import ShikeCore

private final class ChunkedProtocol: URLProtocol {
    struct Script {
        var status = 200
        var mime = "text/event-stream"
        var chunks: [(TimeInterval, Data)]
        var finish = true
        var stopped: (() -> Void)?
    }
    static var handler: ((URLRequest) throws -> Script)?
    private var onStop: (() -> Void)?
    private var worker: Task<Void, Never>?
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        do {
            let script = try Self.handler!(request)
            onStop = script.stopped
            let response = HTTPURLResponse(url: request.url!, statusCode: script.status, httpVersion: "HTTP/1.1",
                                           headerFields: ["Content-Type": script.mime])!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            worker = Task {
                do {
                    for (delay, bytes) in script.chunks {
                        try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
                        try Task.checkCancellation()
                        client?.urlProtocol(self, didLoad: bytes)
                    }
                    if script.finish { client?.urlProtocolDidFinishLoading(self) }
                } catch { }
            }
        } catch { client?.urlProtocol(self, didFailWithError: error) }
    }
    override func stopLoading() { worker?.cancel(); onStop?() }
}

private final class RecordedUpdates: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [LLMUpdate] = []
    func record(_ update: LLMUpdate) { lock.lock(); values.append(update); lock.unlock() }
    var report: LLMDiagnostics? {
        lock.lock(); defer { lock.unlock() }
        return values.compactMap { if case .diagnostics(let report) = $0 { return report }; return nil }.last
    }
    var stages: [LLMProgress.Stage] {
        lock.lock(); defer { lock.unlock() }
        return values.compactMap { if case .progress(let progress) = $0 { return progress.stage }; return nil }
    }
}

final class LLMStreamingTests: XCTestCase {
    private let configuration = APIConfiguration(baseURL: "https://example.com/custom", model: "fixture")
    override func tearDown() { ChunkedProtocol.handler = nil }
    private func client(_ policy: LLMRequestPolicy = .init()) -> LLMClient {
        let config = URLSessionConfiguration.ephemeral; config.protocolClasses = [ChunkedProtocol.self]
        return LLMClient(session: URLSession(configuration: config), policy: policy)
    }
    private func extract(_ client: LLMClient, format: APIFormat = .openAI, updates: RecordedUpdates = RecordedUpdates()) async throws -> [EventDraft] {
        var config = configuration; config.format = format
        return try await client.extract(text: "private input", referenceDate: .now, timeZone: .current,
                                        configuration: config, apiKey: "private-key", observer: { updates.record($0) })
    }
    private func event(_ json: [String: Any]) throws -> Data {
        var data = Data("data: ".utf8); data.append(try JSONSerialization.data(withJSONObject: json)); data.append(Data("\n\n".utf8)); return data
    }
    private func openAI(_ content: String = "{\"events\":[]}", finish: String = "stop") throws -> Data {
        var data = try event(["choices": [["index": 0, "delta": ["content": content], "finish_reason": finish]]])
        data.append(Data("data: [DONE]\n\n".utf8)); return data
    }
    private func requestBody(_ request: URLRequest) throws -> [String: Any] {
        var data = request.httpBody ?? Data()
        if let stream = request.httpBodyStream {
            stream.open(); defer { stream.close() }
            var bytes = [UInt8](repeating: 0, count: 4096)
            while true { let count = stream.read(&bytes, maxLength: bytes.count); if count <= 0 { break }; data.append(bytes, count: count) }
        }
        return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    func testByteByByteChineseCRLFAndReasoningOnlyChunks() throws {
        var decoder = LLMStreamDecoder(format: .openAI)
        let reasoning = try event(["choices": [["delta": ["reasoning_content": "private reasoning"]]]])
        try decoder.append(reasoning)
        XCTAssertTrue(decoder.text.isEmpty)
        XCTAssertEqual(decoder.reasoningCharacters, "private reasoning".count)
        let payload = try openAI("{\"events\":[{\"title\":\"开会🐱\"}]}")
        let bytes = Data(String(decoding: payload, as: UTF8.self).replacingOccurrences(of: "\n", with: "\r\n").utf8)
        for byte in bytes { try decoder.append(Data([byte])) }
        let result = try decoder.finish()
        XCTAssertEqual(try ExtractionDecoder.decode(result, timeZone: .current).first?.title, "开会🐱")
        XCTAssertFalse(result.contains("private reasoning"))
    }

    func testOpenAIStreamsAndPreservesCustomEndpoint() async throws {
        let bytes = try openAI()
        ChunkedProtocol.handler = { request in
            let body = try self.requestBody(request)
            XCTAssertEqual(request.url?.path, "/custom/chat/completions")
            XCTAssertNil(request.url?.query)
            XCTAssertEqual(body["stream"] as? Bool, true)
            return .init(chunks: [(0, bytes)])
        }
        let updates = RecordedUpdates()
        let result = try await extract(client(), updates: updates)
        XCTAssertTrue(result.isEmpty)
        XCTAssertEqual(updates.report?.outcome, "成功")
        XCTAssertNotNil(updates.report?.attempts.first?.firstByte)
        XCTAssertNotNil(updates.report?.attempts.first?.firstText)
        XCTAssertNotNil(updates.report?.attempts.first?.responseHeaders)
        XCTAssertEqual(updates.report?.attempts.first?.reasoningCharacters, 0)
        XCTAssertFalse(updates.report?.text.contains("private") ?? true)
    }

    func testReasoningProgressIsSeparateFromAnswerAndNeverExposesContent() async throws {
        let thinking = try event(["choices": [["delta": ["reasoning_content": "private reasoning"]]]])
        let answer = try openAI()
        ChunkedProtocol.handler = { _ in .init(chunks: [(0, thinking), (1.15, answer)]) }
        let updates = RecordedUpdates()
        _ = try await extract(client(), updates: updates)
        let attempt = try XCTUnwrap(updates.report?.attempts.first)
        XCTAssertTrue(updates.stages.contains(.thinking))
        XCTAssertEqual(attempt.reasoningCharacters, "private reasoning".count)
        XCTAssertLessThan(try XCTUnwrap(attempt.firstReasoning), try XCTUnwrap(attempt.firstText))
        XCTAssertFalse(updates.report?.text.contains("private") ?? true)
    }

    func testValidTerminalCompletesWithoutWaitingForServerToClose() async throws {
        let bytes = try openAI()
        ChunkedProtocol.handler = { _ in .init(chunks: [(0, bytes)], finish: false) }
        let start = Date()
        _ = try await extract(client(.init(firstResponse: 1, idle: 1, total: 2)))
        XCTAssertLessThan(Date().timeIntervalSince(start), 0.8)
    }

    func testCleanCloseWithoutOpenAIDoneRequiresFinishReason() throws {
        var good = LLMStreamDecoder(format: .openAI)
        try good.append(event(["choices": [["delta": ["content": "{\"events\":[]}"], "finish_reason": "stop"]]]))
        XCTAssertEqual(try good.finish(), "{\"events\":[]}")
        var bad = LLMStreamDecoder(format: .openAI)
        try bad.append(event(["choices": [["delta": ["content": "{\"events\":[]}"]]]]))
        XCTAssertThrowsError(try bad.finish())
    }

    func testPartialMalformedRefusedAndTruncatedNeverReturnDrafts() async throws {
        let cases = [try event(["choices": [["delta": ["content": "{\"events\":[]} visible"]]]]),
                     Data("data: {bad json}\n\n".utf8),
                     try event(["choices": [["delta": ["refusal": "private refusal"], "finish_reason": "stop"]]]) + Data("data: [DONE]\n\n".utf8),
                     try openAI(finish: "length"),
                     try event(["error": ["message": "private error"]])]
        for data in cases {
            var calls = 0
            ChunkedProtocol.handler = { _ in calls += 1; return .init(chunks: [(0, data)]) }
            do { _ = try await extract(client()); XCTFail("Invalid stream accepted") }
            catch { XCTAssertFalse(error.localizedDescription.contains("private")) }
            XCTAssertEqual(calls, 1)
        }
    }

    func testHeartbeatKeepsIdleAliveAndLongGenerationPassesOldDeadline() async throws {
        let body = try openAI()
        ChunkedProtocol.handler = { _ in .init(chunks: [(0.03, Data(": ping\n\n".utf8)), (0.15, Data(": ping\n\n".utf8)), (0.15, Data(": ping\n\n".utf8)), (0.15, body)]) }
        _ = try await extract(client(.init(firstResponse: 0.2, idle: 0.3, total: 2)))
        do { _ = try await extract(client(.init(firstResponse: 0.2, idle: 0.3, total: 0.3))); XCTFail("Total deadline must apply to active streams") }
        catch { XCTAssertEqual(error as? LLMTimeout, .total) }
    }

    func testFirstDataAndIdleTimeoutsAreDistinctAndDoNotRetry() async throws {
        for first in [true, false] {
            var count = 0
            ChunkedProtocol.handler = { _ in
                count += 1
                return .init(chunks: first ? [] : [(0, Data(": ping\n\n".utf8))], finish: false)
            }
            let updates = RecordedUpdates()
            do { _ = try await extract(client(.init(firstResponse: 0.15, idle: 0.15, total: 2)), updates: updates); XCTFail("Expected deadline") }
            catch { XCTAssertEqual(error as? LLMTimeout, first ? .firstResponse : .idle) }
            XCTAssertEqual(count, 1)
            XCTAssertEqual(updates.report?.attempts.first?.failure, first ? LLMTimeout.firstResponse.rawValue : LLMTimeout.idle.rawValue)
        }
    }

    func testCancellationStopsUnderlyingRequestAndPublishesCancelledReport() async throws {
        var count = 0
        let stopped = expectation(description: "Underlying URLSession task stopped")
        ChunkedProtocol.handler = { _ in count += 1; return .init(chunks: [], finish: false, stopped: { stopped.fulfill() }) }
        let updates = RecordedUpdates(), client = client()
        let task = Task { try await self.extract(client, updates: updates) }
        try await Task.sleep(nanoseconds: 100_000_000); task.cancel()
        do { _ = try await task.value; XCTFail("Expected cancellation") } catch { XCTAssertTrue(error is CancellationError) }
        XCTAssertEqual(count, 1)
        await fulfillment(of: [stopped], timeout: 1)
        XCTAssertEqual(updates.report?.outcome, "已取消")
    }

    func testExplicitCapabilityFallbacksAreBoundedAndCached() async throws {
        var calls = 0
        ChunkedProtocol.handler = { request in
            calls += 1
            let payload = try self.requestBody(request)
            if payload["stream"] as? Bool == true {
                return .init(status: 400, mime: "application/json", chunks: [(0, Data("stream is not supported".utf8))])
            }
            if payload["response_format"] != nil {
                return .init(status: 422, mime: "application/json", chunks: [(0, Data("response_format unsupported".utf8))])
            }
            return .init(mime: "application/json", chunks: [(0, Data(#"{"choices":[{"message":{"content":"{\"events\":[]}"},"finish_reason":"stop"}]}"#.utf8))])
        }
        let client = client(), updates = RecordedUpdates()
        _ = try await extract(client, updates: updates)
        XCTAssertEqual(calls, 3); XCTAssertEqual(updates.report?.attempts.count, 3)
        XCTAssertNotNil(updates.report?.attempts[0].fallback); XCTAssertNotNil(updates.report?.attempts[1].fallback)
        _ = try await extract(client)
        XCTAssertEqual(calls, 4)
    }

    func testFallbackSharesTotalDeadline() async throws {
        var count = 0
        ChunkedProtocol.handler = { _ in
            count += 1
            if count == 1 { return .init(status: 400, chunks: [(0.15, Data("response_format unsupported".utf8))]) }
            return .init(chunks: [(0.25, try self.openAI())])
        }
        do { _ = try await extract(client(.init(firstResponse: 1, idle: 1, total: 0.3))); XCTFail("Retries cannot reset the total deadline") }
        catch { XCTAssertEqual(error as? LLMTimeout, .total) }
        XCTAssertEqual(count, 2)
    }

    func testHTTP504AndUnrelated400DoNotDowngradeOrRetry() async {
        for status in [400, 401, 429, 503, 504] {
            var count = 0
            ChunkedProtocol.handler = { _ in count += 1; return .init(status: status, chunks: [(0, Data("private service error".utf8))]) }
            let updates = RecordedUpdates()
            do { _ = try await extract(client(), updates: updates); XCTFail("Expected HTTP failure") }
            catch { XCTAssertFalse(error.localizedDescription.contains("private")); if status == 504 { XCTAssertTrue(error.localizedDescription.contains("504")) } }
            XCTAssertEqual(count, 1); XCTAssertEqual(updates.report?.attempts.first?.status, status)
        }
    }

    func testCapabilityCacheExpiresAndIsLocalToEndpointAndModel() throws {
        let name = "LLMCacheTests-" + UUID().uuidString
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        defaults.set(["expired": ["stream": Date().timeIntervalSince1970 - 1]], forKey: "llmUnsupportedCapabilitiesV1")
        let cache = LLMCapabilityCache(defaults: defaults)
        XCTAssertFalse(cache.unsupported("stream", key: "expired"))
        cache.mark("stream", key: "endpoint-A|model-A")
        XCTAssertTrue(LLMCapabilityCache(defaults: defaults).unsupported("stream", key: "endpoint-A|model-A"))
        XCTAssertFalse(cache.unsupported("json", key: "endpoint-A|model-A"))
        XCTAssertFalse(cache.unsupported("stream", key: "endpoint-B|model-A"))
    }

    func testOversizedSSEFrameIsRejectedBeforeCompletion() {
        var decoder = LLMStreamDecoder(format: .openAI)
        XCTAssertThrowsError(try decoder.append(Data(("data: " + String(repeating: "x", count: 1_000_001)).utf8)))
    }
}
