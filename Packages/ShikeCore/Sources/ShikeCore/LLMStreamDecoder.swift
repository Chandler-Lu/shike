import Foundation

/// Parses SSE as bytes first so a network chunk may split a Chinese UTF-8 character.
struct LLMStreamDecoder {
    let format: APIFormat
    private var buffer = Data()
    private var dataLines: [String] = []
    private var eventBytes = 0
    private(set) var text = ""
    private(set) var reasoningCharacters = 0
    private var textBytes = 0
    private var stopReason: String?
    private(set) var ended = false
    private var refused = false

    mutating func append(_ data: Data) throws {
        buffer.append(data)
        while let newline = buffer.firstIndex(of: 10) {
            var line = buffer[..<newline]
            if line.last == 13 { line = line.dropLast() }
            guard let value = String(data: line, encoding: .utf8) else { throw Self.invalid }
            buffer.removeSubrange(...newline)
            if value.isEmpty { try dispatch() }
            else if value.hasPrefix("data:") {
                var payload = String(value.dropFirst(5))
                if payload.first == " " { payload.removeFirst() }
                eventBytes += payload.utf8.count
                guard eventBytes <= 1_000_000 else { throw Self.tooLarge }
                dataLines.append(payload)
            }
        }
        guard buffer.count <= 1_000_000 else { throw Self.tooLarge }
    }

    mutating func finish() throws -> String {
        if !buffer.isEmpty { try append(Data([10, 10])) }
        else { try dispatch() }
        switch format {
        case .openAI:
            // Some compatible servers close cleanly after finish_reason without [DONE].
            guard ended || stopReason != nil else { throw Self.incomplete }
            guard !refused, stopReason == "stop" else { throw Self.incomplete }
        case .claude:
            guard ended, stopReason == "end_turn" || stopReason == "stop_sequence" else { throw Self.incomplete }
        case .gemini:
            guard stopReason == "STOP" else { throw Self.incomplete }
        }
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw Self.incomplete }
        return text
    }

    private mutating func add(_ value: String) throws {
        textBytes += value.utf8.count
        guard textBytes <= 2_000_000 else { throw Self.tooLarge }
        text += value
    }
    private mutating func dispatch() throws {
        guard !dataLines.isEmpty else { return }
        let payload = dataLines.joined(separator: "\n")
        dataLines.removeAll(keepingCapacity: true); eventBytes = 0
        if payload == "[DONE]" {
            guard format == .openAI else { throw Self.invalid }
            ended = true; return
        }
        guard !ended else { return }
        guard let json = try? JSONSerialization.jsonObject(with: Data(payload.utf8)) as? [String: Any] else { throw Self.invalid }
        if json["error"] != nil || json["type"] as? String == "error" {
            throw ShikeError.message("模型服务在返回过程中报错，原文已保留，请稍后重试。")
        }
        switch format {
        case .openAI:
            guard let choices = json["choices"] as? [[String: Any]] else { return }
            guard let choice = choices.first(where: { ($0["index"] as? Int ?? 0) == 0 }) else { return }
            if let delta = choice["delta"] as? [String: Any] {
                if let value = delta["content"] as? String { try add(value) }
                if let value = delta["refusal"] as? String, !value.isEmpty { refused = true }
                if let value = delta["reasoning_content"] as? String { reasoningCharacters += value.count }
                // reasoning_content and other reasoning deltas are activity, never final JSON.
            }
            if let reason = choice["finish_reason"] as? String {
                stopReason = reason
                if reason == "length" { throw Self.truncated }
            }
        case .claude:
            switch json["type"] as? String {
            case "content_block_start":
                if let block = json["content_block"] as? [String: Any], block["type"] as? String == "text",
                   let value = block["text"] as? String { try add(value) }
            case "content_block_delta":
                if let delta = json["delta"] as? [String: Any], delta["type"] as? String == "text_delta",
                   let value = delta["text"] as? String { try add(value) }
                if let delta = json["delta"] as? [String: Any], delta["type"] as? String == "thinking_delta",
                   let value = delta["thinking"] as? String { reasoningCharacters += value.count }
            case "message_delta":
                if let delta = json["delta"] as? [String: Any], let reason = delta["stop_reason"] as? String {
                    stopReason = reason
                    if reason == "max_tokens" { throw Self.truncated }
                }
            case "message_stop": ended = true
            default: break // ping, thinking and future event types are safe to ignore.
            }
        case .gemini:
            guard let candidates = json["candidates"] as? [[String: Any]],
                  let candidate = candidates.first(where: { ($0["index"] as? Int ?? 0) == 0 }) else { return }
            if let content = candidate["content"] as? [String: Any], let parts = content["parts"] as? [[String: Any]] {
                for part in parts {
                    if let value = part["text"] as? String {
                        if part["thought"] as? Bool == true { reasoningCharacters += value.count }
                        else { try add(value) }
                    }
                }
            }
            if let reason = candidate["finishReason"] as? String {
                stopReason = reason
                if reason == "MAX_TOKENS" { throw Self.truncated }
                ended = true
            }
        }
    }
    static let invalid = ShikeError.message("模型流式响应格式无法读取，原文已保留。")
    static let incomplete = ShikeError.message("模型回复未完整结束，原文已保留，请重试。")
    static let truncated = ShikeError.message("模型输出被截断，请减少单次导入内容。")
    static let tooLarge = ShikeError.message("模型返回内容过长，请缩短原文后重试。")
}
