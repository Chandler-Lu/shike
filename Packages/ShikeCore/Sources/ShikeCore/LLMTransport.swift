import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

struct LLMHTTPResult: @unchecked Sendable {
    var response: HTTPURLResponse?
    var data = Data()
    var content: String?
    var metrics: LLMDiagnostics.Attempt
    var error: Error?
}

/// One reusable session, with all delegate state and deadlines confined to a serial queue.
final class LLMTransport: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    static let shared = LLMTransport(configuration: .ephemeral)
    private let queue = DispatchQueue(label: "cn.yeslu.shike.model-transport")
    private var session: URLSession!
    private var requests: [Int: Request] = [:]

    init(configuration: URLSessionConfiguration) {
        super.init()
        let config = configuration.copy() as! URLSessionConfiguration
        // Explicit per-operation deadlines below also cover retries and streamed heartbeats.
        config.timeoutIntervalForRequest = 3600; config.timeoutIntervalForResource = 3600
        config.urlCache = nil; config.httpCookieStorage = nil; config.urlCredentialStorage = nil
        let delegateQueue = OperationQueue(); delegateQueue.maxConcurrentOperationCount = 1
        delegateQueue.underlyingQueue = queue
        session = URLSession(configuration: config, delegate: self, delegateQueue: delegateQueue)
    }
    func invalidate() { session.invalidateAndCancel() }

    func send(_ request: URLRequest, format: APIFormat, policy: LLMRequestPolicy, operationStart: TimeInterval,
              attempt: Int, jsonMode: Bool, streaming: Bool, observer: LLMObserver?) async -> LLMHTTPResult {
        let cancellation = TransportCancellation()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                queue.async { [self] in
                    let state = Request(format: format, policy: policy, operationStart: operationStart,
                                        attempt: attempt, jsonMode: jsonMode, streaming: streaming,
                                        observer: observer, continuation: continuation)
                    if cancellation.isCancelled { continuation.resume(returning: state.result(error: CancellationError())); return }
                    var request = request; request.timeoutInterval = max(policy.total, policy.firstResponse, policy.idle)
                    let task = self.session.dataTask(with: request)
                    state.task = task; self.requests[task.taskIdentifier] = state
                    cancellation.install { [weak self, weak task] in
                        guard let self, let task else { return }
                        self.queue.async { self.complete(task, error: CancellationError()) }
                    }
                    let timer = DispatchSource.makeTimerSource(queue: self.queue)
                    timer.schedule(deadline: .now(), repeating: .milliseconds(100))
                    timer.setEventHandler { [weak self, weak task] in
                        guard let self, let task, let state = self.requests[task.taskIdentifier] else { return }
                        if let error = state.expiration { self.complete(task, error: error) }
                        else { state.publishProgress() }
                    }
                    state.timer = timer; timer.resume()
                    task.resume()
                }
            }
        } onCancel: { cancellation.cancel() }
    }

    private func complete(_ task: URLSessionTask, error: Error?) {
        guard let state = requests.removeValue(forKey: task.taskIdentifier) else { return }
        state.timer?.cancel(); state.timer = nil
        if error != nil { task.cancel() }
        state.continuation.resume(returning: state.result(error: error))
    }
    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
                    completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        guard let state = requests[dataTask.taskIdentifier], let http = response as? HTTPURLResponse else {
            completionHandler(.cancel); return
        }
        state.response = http; state.metrics.status = http.statusCode
        state.metrics.responseHeaders = state.now - state.start
        state.phase = .waiting
        completionHandler(.allow)
    }
    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        guard let state = requests[dataTask.taskIdentifier], !data.isEmpty else { return }
        do {
            try state.receive(data)
            if state.decoder?.ended == true {
                // Allow a normal HTTP end to preserve keep-alive; bound a proxy that stays open.
                queue.asyncAfter(deadline: .now() + .milliseconds(100)) { [weak self, weak dataTask] in
                    guard let self, let task = dataTask, self.requests[task.taskIdentifier] != nil else { return }
                    task.cancel()
                }
            }
        } catch { complete(dataTask, error: error) }
    }
    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard let state = requests[task.taskIdentifier] else { return }
        let terminalCancellation = state.decoder?.ended == true && (error as? URLError)?.code == .cancelled
        complete(task, error: terminalCancellation ? nil : error)
    }
    func urlSession(_ session: URLSession, task: URLSessionTask, didFinishCollecting metrics: URLSessionTaskMetrics) {
        guard let state = requests[task.taskIdentifier], let last = metrics.transactionMetrics.last else { return }
        func duration(_ from: Date?, _ to: Date?) -> TimeInterval? {
            guard let from, let to else { return nil }; return to.timeIntervalSince(from)
        }
        state.metrics.dns = duration(last.domainLookupStartDate, last.domainLookupEndDate)
        state.metrics.connection = duration(last.connectStartDate, last.connectEndDate)
        state.metrics.tls = duration(last.secureConnectionStartDate, last.secureConnectionEndDate)
        state.metrics.requestSent = duration(metrics.taskInterval.start, last.requestEndDate)
        state.metrics.networkProtocol = last.networkProtocolName
        state.metrics.proxy = last.isProxyConnection; state.metrics.reusedConnection = last.isReusedConnection
    }
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        let original = task.originalRequest?.url, target = request.url
        let same = original?.scheme == target?.scheme && original?.host == target?.host && original?.port == target?.port
        completionHandler(same ? request : nil)
    }

    private final class Request {
        let start = ProcessInfo.processInfo.systemUptime
        let operationStart: TimeInterval
        let policy: LLMRequestPolicy
        let format: APIFormat
        let observer: LLMObserver?
        let continuation: CheckedContinuation<LLMHTTPResult, Never>
        var task: URLSessionDataTask?
        var timer: DispatchSourceTimer?
        var response: HTTPURLResponse?
        var metrics: LLMDiagnostics.Attempt
        var phase = LLMProgress.Stage.connecting
        var lastProgressSecond = -1
        var lastData: TimeInterval?
        var data = Data()
        var decoder: LLMStreamDecoder?
        var decidedFormat = false

        init(format: APIFormat, policy: LLMRequestPolicy, operationStart: TimeInterval, attempt: Int,
             jsonMode: Bool, streaming: Bool, observer: LLMObserver?, continuation: CheckedContinuation<LLMHTTPResult, Never>) {
            self.format = format; self.policy = policy; self.operationStart = operationStart
            self.observer = observer; self.continuation = continuation
            metrics = .init(number: attempt, streaming: streaming, jsonMode: jsonMode)
        }
        var now: TimeInterval { ProcessInfo.processInfo.systemUptime }
        var expiration: Error? {
            if now - operationStart >= policy.total { return LLMTimeout.total }
            if let lastData {
                if now - lastData >= policy.idle { return LLMTimeout.idle }
            } else if now - start >= policy.firstResponse { return LLMTimeout.firstResponse }
            return nil
        }
        func publishProgress() {
            let elapsed = now - operationStart
            guard Int(elapsed) != lastProgressSecond else { return }
            lastProgressSecond = Int(elapsed)
            observer?(.progress(.init(stage: phase, elapsed: elapsed, attempt: metrics.number, receivedBytes: metrics.receivedBytes)))
        }
        func receive(_ chunk: Data) throws {
            lastData = now
            if metrics.firstByte == nil { metrics.firstByte = now - start }
            metrics.receivedBytes += chunk.count
            guard metrics.receivedBytes <= 16_000_000 else { throw LLMStreamDecoder.tooLarge }
            if let status = response?.statusCode, !(200..<300).contains(status) {
                data.append(chunk.prefix(max(0, 8192 - data.count))); return
            }
            if !decidedFormat {
                data.append(chunk)
                let prefix = data.prefix(128).drop(while: { [9, 10, 13, 32].contains($0) })
                let isJSON = prefix.first == 123 || prefix.first == 91
                let isSSE = response?.mimeType == "text/event-stream" || prefix.first == 58 ||
                    prefix.starts(with: Data("data:".utf8)) || prefix.starts(with: Data("event:".utf8))
                if isJSON { decidedFormat = true }
                else if isSSE {
                    decidedFormat = true; decoder = LLMStreamDecoder(format: format)
                    try decoder?.append(data); data.removeAll(keepingCapacity: false)
                } else if data.count > 1024 { decidedFormat = true }
            } else if decoder != nil { try decoder?.append(chunk) }
            else { data.append(chunk) }
            if decoder == nil { guard data.count <= 2_000_000 else { throw LLMStreamDecoder.tooLarge } }
            if let characters = decoder?.reasoningCharacters, characters > 0 {
                if metrics.firstReasoning == nil { metrics.firstReasoning = now - start }
                metrics.reasoningCharacters = characters
                if metrics.firstText == nil { phase = .thinking }
            }
            if decoder?.text.isEmpty == false {
                if metrics.firstText == nil { metrics.firstText = now - start }
                phase = .receiving
            }
        }
        func result(error: Error?) -> LLMHTTPResult {
            metrics.elapsed = now - start
            var result = LLMHTTPResult(response: response, data: data, metrics: metrics, error: error)
            if error == nil, decoder != nil {
                do { result.content = try decoder?.finish() } catch { result.error = error }
            }
            if let failure = result.error {
                if let timeout = failure as? LLMTimeout { result.metrics.failure = timeout.rawValue }
                else if failure is CancellationError || (failure as? URLError)?.code == .cancelled { result.metrics.failure = "用户取消" }
                else if let urlError = failure as? URLError { result.metrics.failure = "网络错误 NSURLErrorDomain (\(urlError.code.rawValue))" }
                else { result.metrics.failure = "接收或协议校验失败" }
            }
            return result
        }
    }
}

// Injected test sessions do not live for the process lifetime like the shared transport.
final class LLMTransportLease: @unchecked Sendable {
    let transport: LLMTransport
    init(configuration: URLSessionConfiguration) { transport = LLMTransport(configuration: configuration) }
    deinit { transport.invalidate() }
}

enum LLMTimeout: String, LocalizedError {
    case firstResponse = "等待首次响应超时"
    case idle = "响应中途长时间无数据"
    case total = "达到请求总时限"
    var errorDescription: String? { "模型响应超时：\(rawValue)。原文已保留，可稍后重试。" }
}

private final class TransportCancellation: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false
    private var action: (@Sendable () -> Void)?
    var isCancelled: Bool { lock.lock(); defer { lock.unlock() }; return cancelled }
    func install(_ action: @escaping @Sendable () -> Void) {
        lock.lock(); self.action = action; let run = cancelled; lock.unlock()
        if run { action() }
    }
    func cancel() {
        lock.lock(); cancelled = true; let action = action; lock.unlock(); action?()
    }
}

final class LLMCapabilityCache: @unchecked Sendable {
    static let shared = LLMCapabilityCache(defaults: .standard)
    private let lock = NSLock()
    private let defaults: UserDefaults?
    private var values: [String: [String: Double]]
    init(defaults: UserDefaults? = nil) {
        self.defaults = defaults
        values = defaults?.dictionary(forKey: "llmUnsupportedCapabilitiesV1") as? [String: [String: Double]] ?? [:]
    }
    func unsupported(_ capability: String, key: String) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return (values[key]?[capability] ?? 0) > Date().timeIntervalSince1970
    }
    func mark(_ capability: String, key: String) {
        lock.lock(); defer { lock.unlock() }
        let now = Date().timeIntervalSince1970
        values = values.mapValues { $0.filter { $0.value > now } }.filter { !$0.value.isEmpty }
        values[key, default: [:]][capability] = now + 86400
        defaults?.set(values, forKey: "llmUnsupportedCapabilitiesV1")
    }
}
