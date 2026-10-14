import Foundation

/// Accept presentation differences without guessing missing JSON or choosing between alternatives.
enum StructuredModelOutput {
    static func data(_ content: String) throws -> Data {
        guard content.utf8.count <= 2_000_000 else { throw ShikeError.message("模型返回内容过长，请缩短原文后重试。") }
        var text = content.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.hasPrefix("\u{FEFF}") { text.removeFirst() }
        text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        // Some compatible reasoning endpoints put a reasoning block in content instead of a separate field.
        for tag in ["think", "analysis"] where text.hasPrefix("<\(tag)>") {
            guard let end = text.range(of: "</\(tag)>") else {
                throw ShikeError.message("模型只返回了未完成的思考内容，请重试或减少单次内容。")
            }
            text = String(text[end.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        if let result = validData(text) { return result }
        var candidates: [Data] = []
        var stack: [Character] = [], buffer = ""
        var inString = false, escaped = false
        for character in text {
            if stack.isEmpty {
                guard character == "{" || character == "[" else { continue }
                stack.append(character); buffer = String(character)
                inString = false; escaped = false
                continue
            }
            buffer.append(character)
            if inString {
                if escaped { escaped = false }
                else if character == "\\" { escaped = true }
                else if character == "\"" { inString = false }
                continue
            }
            if character == "\"" { inString = true }
            else if character == "{" || character == "[" {
                guard stack.count < 128 else { throw malformed }
                stack.append(character)
            } else if character == "}" || character == "]" {
                guard stack.last == (character == "}" ? "{" : "[") else { throw malformed }
                stack.removeLast()
                if stack.isEmpty, let candidate = validData(buffer) {
                    candidates.append(candidate)
                    guard candidates.count <= 1 else {
                        throw ShikeError.message("模型返回了多份不同的 JSON，无法确定最终方案。原文已保留，请重试。")
                    }
                }
            }
        }
        guard stack.isEmpty else {
            throw ShikeError.message("模型返回的 JSON 不完整，原文已保留。请减少单次内容后重试。")
        }
        guard let result = candidates.first else { throw malformed }
        return result
    }

    static func eventData(_ content: String) throws -> Data {
        let object = try JSONSerialization.jsonObject(with: data(content))
        // A bare event array conveys the same information as {"events": [...]}.
        var root = (object as? [String: Any]) ?? ["events": object]
        guard var events = root["events"] as? [[String: Any]] else { throw invalidFields }
        for index in events.indices {
            // These conversions preserve meaning; malformed dates and arbitrary text remain invalid.
            for key in ["allDay", "needsReview"] {
                if let value = events[index][key] as? String {
                    switch value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
                    case "true": events[index][key] = true
                    case "false": events[index][key] = false
                    default: break
                    }
                }
            }
            if let value = events[index]["reminderMinutes"] as? String,
               let number = Int(value.trimmingCharacters(in: .whitespacesAndNewlines)) {
                events[index]["reminderMinutes"] = number
            }
            if let value = events[index]["reviewNotes"] as? String {
                events[index]["reviewNotes"] = value.isEmpty ? [] : [value]
            }
        }
        root["events"] = events
        return try JSONSerialization.data(withJSONObject: root)
    }

    static var invalidFields: ShikeError {
        .message("模型返回的日程字段不完整或类型不正确，原文已保留。请重新提取；若仍失败，可更换模型。")
    }
    private static var malformed: ShikeError {
        .message("模型没有返回可读取的 JSON，原文已保留。请重试；若仍失败，请检查所选模型是否支持文字生成。")
    }
    private static func validData(_ text: String) -> Data? {
        let data = Data(text.utf8)
        guard let value = try? JSONSerialization.jsonObject(with: data),
              value is [String: Any] || value is [Any] else { return nil }
        return data
    }
}

enum ModelOutputContract {
    static func eventFields(timeZone: TimeZone) -> String {
        """
        输出协议（严格遵守）：只返回一个完整 JSON 对象，使用英文双引号。不输出 Markdown、代码围栏、思考过程、注释、前后说明、尾逗号或省略号。
        不要把 JSON 对象再编码成字符串。字段名使用以下英文拼写，不能翻译、改名或用中文键名。
        events 必须为数组。每个事件使用相同字段，缺失值规则如下：
        - title、location、notes、sourceExcerpt：字符串；未知文本为 ""，不能用数组或对象。
        - start、end：日期字符串或 null；不能写 "null"、时间戳、日期对象或“明天”等自然语言。
        - allDay、needsReview：JSON 布尔值 true/false，不能加引号。
        - timeZone：IANA 时区字符串；默认 "\(timeZone.identifier)"。
        - category：work、personal、study、travel、health、other 中的一个字符串。
        - reminderMinutes：整数 0/5/15/30/60 或 null，不能加引号。
        - reviewNotes：字符串数组，无需说明时为 []，不能用单个字符串。
        - calendarID：给定候选 id 字符串或 null；没有候选时必须为 null。
        事件格式示例（仅展示类型，不是本次事实，禁止复制示例内容）：
        {"title":"待确认日期的会议","start":null,"end":null,"allDay":false,"timeZone":"\(timeZone.identifier)","location":"","notes":"","sourceExcerpt":"开个会","reminderMinutes":null,"needsReview":true,"reviewNotes":["缺少日期"],"category":"work","calendarID":null}
        输出前检查：JSON 可解析，数组/对象和引号完整闭合，所有字段类型正确，结果只依据本次资料。
        """
    }
}
