import Foundation

public struct LLMProgress: Sendable {
    public enum Stage: String, Sendable { case preparing, connecting, waiting, thinking, receiving, parsing, searching, reading, arranging }
    public let stage: Stage
    public let elapsed: TimeInterval
    public let attempt: Int
    public var receivedBytes: Int = 0
    public var message: String {
        let label: String
        switch stage {
        case .preparing: label = "正在准备请求"
        case .connecting: label = "正在连接模型"
        case .waiting: label = "正在等待模型回复"
        case .thinking: label = "模型正在思考"
        case .receiving: label = "正在接收模型回复"
        case .parsing: label = "正在整理结果"
        case .searching: label = "正在查找资料"
        case .reading: label = "正在读取网页"
        case .arranging: label = "正在整理安排"
        }
        return "\(label) · \(Int(elapsed)) 秒" + (attempt > 1 ? " · 兼容请求 \(attempt)" : "")
    }
}

/// Intentionally contains no request/response bodies, credentials or provider request IDs.
public struct LLMDiagnostics: Sendable {
    public struct Attempt: Sendable {
        public var number: Int
        public var streaming: Bool
        public var jsonMode: Bool
        public var status: Int?
        public var elapsed: TimeInterval = 0
        public var firstByte: TimeInterval?
        public var responseHeaders: TimeInterval?
        public var firstReasoning: TimeInterval?
        public var reasoningCharacters = 0
        public var firstText: TimeInterval?
        public var dns: TimeInterval?
        public var connection: TimeInterval?
        public var tls: TimeInterval?
        public var requestSent: TimeInterval?
        public var networkProtocol: String?
        public var proxy: Bool?
        public var reusedConnection: Bool?
        public var receivedBytes = 0
        public var fallback: String?
        public var failure: String?
    }
    public var host: String
    public var model: String
    public var format: String
    public var preparation: TimeInterval = 0
    public var elapsed: TimeInterval = 0
    public var decoding: TimeInterval = 0
    public var attempts: [Attempt] = []
    public var outcome = "进行中"

    public var text: String {
        func seconds(_ value: TimeInterval?) -> String { value.map { String(format: "%.2f 秒", $0) } ?? "未取得" }
        var lines = ["接口：\(host)", "模型：\(model)", "协议：\(format)", "结果：\(outcome)",
                     "总耗时：\(seconds(elapsed)) · 准备：\(seconds(preparation)) · 解析：\(seconds(decoding))"]
        for a in attempts {
            lines += ["请求 \(a.number)：\(a.streaming ? "流式" : "非流式") · JSON \(a.jsonMode ? "开启" : "关闭") · HTTP \(a.status.map(String.init) ?? "无响应")",
                      "首个数据：\(seconds(a.firstByte)) · 首段正文：\(seconds(a.firstText)) · 接收完成：\(seconds(a.elapsed))",
                      "响应头：\(seconds(a.responseHeaders)) · 首段推理：\(seconds(a.firstReasoning)) · 推理片段 \(a.reasoningCharacters) 字符",
                      "DNS：\(seconds(a.dns)) · 连接：\(seconds(a.connection)) · TLS：\(seconds(a.tls)) · 发出请求：\(seconds(a.requestSent))",
                      "传输：\(a.networkProtocol ?? "未知") · 代理：\(a.proxy.map { $0 ? "是" : "否" } ?? "未知") · 复用连接：\(a.reusedConnection.map { $0 ? "是" : "否" } ?? "未知") · 接收 \(a.receivedBytes) 字节"]
            if let fallback = a.fallback { lines.append("兼容调整：\(fallback)") }
            if let failure = a.failure { lines.append("失败阶段：\(failure)") }
        }
        return lines.joined(separator: "\n")
    }
}

public enum LLMUpdate: Sendable {
    case progress(LLMProgress)
    case diagnostics(LLMDiagnostics)
}
public typealias LLMObserver = @Sendable (LLMUpdate) -> Void

/// Injectable short deadlines make timeout tests deterministic without minute-long waits.
public struct LLMRequestPolicy: Sendable {
    public var firstResponse: TimeInterval
    public var idle: TimeInterval
    public var total: TimeInterval
    public var streaming: Bool
    public var compatibilityFallback: Bool
    var bufferedComparison = false
    public init(firstResponse: TimeInterval = 90, idle: TimeInterval = 60, total: TimeInterval = 300,
                streaming: Bool = true, compatibilityFallback: Bool = true) {
        self.firstResponse = firstResponse; self.idle = idle; self.total = total
        self.streaming = streaming; self.compatibilityFallback = compatibilityFallback
    }
    /// Only for controlled diagnostics; reproduces the previous request policy.
    public static var legacyComparison: LLMRequestPolicy {
        var policy = LLMRequestPolicy(firstResponse: 60, idle: 60, total: 90, streaming: false)
        policy.bufferedComparison = true
        return policy
    }
}

final class LLMTrace: @unchecked Sendable {
    // A trace belongs to one async operation. Network callbacks finish before decoding starts.
    let start = ProcessInfo.processInfo.systemUptime
    let observer: LLMObserver?
    var decodeStart: TimeInterval?
    var report: LLMDiagnostics
    init(configuration: APIConfiguration, observer: LLMObserver?) {
        self.observer = observer
        report = LLMDiagnostics(host: URL(string: configuration.baseURL)?.host ?? "", model: configuration.model, format: configuration.format.rawValue)
        progress(.preparing)
    }
    var elapsed: TimeInterval { ProcessInfo.processInfo.systemUptime - start }
    func progress(_ stage: LLMProgress.Stage, attempt: Int = 1) {
        observer?(.progress(LLMProgress(stage: stage, elapsed: elapsed, attempt: attempt)))
    }
    func finish(_ outcome: String) {
        report.outcome = outcome; report.elapsed = elapsed
        observer?(.diagnostics(report))
    }
}
