import XCTest
@testable import ShikeCore

final class CalendarSummaryTests: XCTestCase {
    private func date(_ text: String) -> Date { ISO8601DateFormatter().date(from: text)! }
    func testSummaryFiltersRangeAndNeverSendsPrivateIdentifiersOrNotes() throws {
        let zone = TimeZone(identifier: "Asia/Shanghai")!
        let start = date("2026-10-15T00:00:00+08:00"), end = date("2026-10-16T00:00:00+08:00")
        let events = [
            CalendarEventSnapshot(eventID: "private-event", itemID: "private-item", calendarID: "private-calendar", title: "跨天会议", start: start.addingTimeInterval(-3600), end: start.addingTimeInterval(3600), location: "三楼", notes: "private-notes"),
            CalendarEventSnapshot(eventID: "other", itemID: "other", calendarID: "c", title: "边界外事件", start: end, end: end.addingTimeInterval(3600))
        ]
        let input = CalendarSummaryInput(events: events, range: DateInterval(start: start, end: end), timeZone: zone)
        XCTAssertEqual(input.events.count, 1)
        let encoded = try input.encoded()
        XCTAssertTrue(encoded.contains("跨天会议")); XCTAssertTrue(encoded.contains("三楼"))
        XCTAssertFalse(encoded.contains("private-")); XCTAssertFalse(encoded.contains("边界外事件"))
        XCTAssertTrue(input.events[0].start.contains("2026-10-14T23:00:00"))
    }
    func testSummaryFormatsCopyAndRejectsMalformedOutput() throws {
        let summary = try CalendarSummary.decode("```json\n{\"overview\":\"两项安排\",\"agenda\":[\"上午阅读\"],\"attention\":[],\"suggestions\":[\"建议预留休息\"]}\n```")
        let plain = summary.text(title: "今天", markdown: false), markdown = summary.text(title: "今天", markdown: true)
        XCTAssertTrue(plain.hasPrefix("今天\n")); XCTAssertFalse(plain.contains("##"))
        XCTAssertTrue(markdown.hasPrefix("# 今天\n")); XCTAssertTrue(markdown.contains("## 日程安排\n- 上午阅读"))
        XCTAssertFalse(markdown.contains("需要留意"))
        XCTAssertThrowsError(try CalendarSummary.decode(#"{"overview":"","agenda":[],"attention":[],"suggestions":[]}"#))
    }
    func testSummaryUsesAllThreeAPIFormatsAndEmptyCalendarNeedsNoService() async throws {
        defer { MockURLProtocol.handler = nil }
        let configuration = URLSessionConfiguration.ephemeral; configuration.protocolClasses = [MockURLProtocol.self]
        let client = LLMClient(session: URLSession(configuration: configuration))
        let start = date("2026-10-15T10:00:00Z"), end = start.addingTimeInterval(3600)
        let input = CalendarSummaryInput(events: [CalendarEventSnapshot(eventID: "secret-id", itemID: "secret-item", calendarID: "secret-calendar", title: "设计评审", start: start, end: end, notes: "secret-notes")], range: DateInterval(start: start, end: end), timeZone: .gmt)
        for format in APIFormat.allCases {
            MockURLProtocol.handler = { request in
                var data = request.httpBody ?? Data()
                if let stream = request.httpBodyStream {
                    stream.open(); defer { stream.close() }
                    var buffer = [UInt8](repeating: 0, count: 4096)
                    while stream.hasBytesAvailable { let count = stream.read(&buffer, maxLength: buffer.count); if count <= 0 { break }; data.append(buffer, count: count) }
                }
                let raw = String(decoding: data, as: UTF8.self)
                XCTAssertTrue(raw.contains("设计评审")); XCTAssertFalse(raw.contains("secret-"))
                let result = #"{"overview":"有一项评审安排","agenda":["设计评审"],"attention":[],"suggestions":[]}"#
                let envelope: [String: Any]
                switch format {
                case .openAI: envelope = ["choices": [["message": ["content": result], "finish_reason": "stop"]]]
                case .claude: envelope = ["content": [["type": "text", "text": result]], "stop_reason": "end_turn"]
                case .gemini: envelope = ["candidates": [["content": ["parts": [["text": result]]], "finishReason": "STOP"]]]
                }
                return (200, try JSONSerialization.data(withJSONObject: envelope))
            }
            let result = try await client.summarizeCalendar(input, configuration: APIConfiguration(baseURL: "https://test.example/custom", model: "fixture", format: format), apiKey: "fixture-key")
            XCTAssertEqual(result.agenda, ["设计评审"])
        }
        MockURLProtocol.handler = { _ in XCTFail("Empty range must stay local"); return (500, Data()) }
        let empty = CalendarSummaryInput(events: [], range: DateInterval(start: start, end: end), timeZone: .gmt)
        let result = try await client.summarizeCalendar(empty, configuration: APIConfiguration(), apiKey: "")
        XCTAssertTrue(result.agenda.isEmpty)
    }
}
