import XCTest
@testable import ShikeCore

final class PlanningTests: XCTestCase {
    private let zone = TimeZone(identifier: "America/New_York")!
    private func date(_ text: String) -> Date { ISO8601DateFormatter().date(from: text)! }
    func testAvailabilityMergesClipsAndKeepsAdjacentBoundariesFree() {
        let base = Date(timeIntervalSince1970: 0)
        func range(_ a: Double, _ b: Double) -> DateInterval { DateInterval(start: base.addingTimeInterval(a), end: base.addingTimeInterval(b)) }
        let free = Scheduling.freeIntervals(in: range(0, 100), busy: [range(20, 40), range(-10, 10), range(35, 50), range(50, 60), range(95, 120)])
        XCTAssertEqual(free, [range(10, 20), range(60, 95)])
        XCTAssertFalse(Scheduling.overlaps(range(0, 10), range(10, 20)))
        XCTAssertTrue(Scheduling.freeIntervals(in: range(0, 100), busy: [range(-1, 101)]).isEmpty)
    }
    func testAllDayDatesStayOnTheirCalendarDayAcrossDisplayTimeZones() {
        let event = CalendarEventSnapshot(eventID: "all", itemID: "all", calendarID: "c", title: "全天", start: date("2026-10-14T00:00:00+08:00"), end: date("2026-10-15T00:00:00+08:00"), allDay: true, timeZone: "Asia/Shanghai")
        let displayed = event.interval(in: zone)
        XCTAssertEqual(displayed.start, date("2026-10-14T00:00:00-04:00"))
        XCTAssertEqual(displayed.end, date("2026-10-15T00:00:00-04:00"))
    }
    func testPlanningAndDayRangesUseNaturalDaysAcrossDST() throws {
        let plan = PlanningConversation(goal: "阅读", now: date("2026-03-07T12:00:00-05:00"), timeZone: zone)
        XCTAssertEqual(plan.end.timeIntervalSince(plan.start), 7 * 86400 - 3600)
        try plan.validate(timeZone: zone)
        let days = Scheduling.days(from: plan.start, count: 3, timeZone: zone)
        XCTAssertEqual(days[2].timeIntervalSince(days[1]), 23 * 3600)
        var bad = plan; bad.end = bad.start.addingTimeInterval(31 * 86400)
        XCTAssertThrowsError(try bad.validate(timeZone: zone))
    }
    func testOldImportAndSettingsDecodeWithoutPlanningFields() throws {
        var session = ImportSession(); session.text = "旧记录"
        let data = try JSONEncoder().encode(session)
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        object.removeValue(forKey: "planning")
        let restored = try JSONDecoder().decode(ImportSession.self, from: JSONSerialization.data(withJSONObject: object))
        XCTAssertEqual(restored.text, "旧记录"); XCTAssertNil(restored.planning)
        session.planning = PlanningConversation(goal: session.text)
        session.planning?.turns = [PlanningTurn(role: "user", text: "晚上半小时")]
        XCTAssertEqual(try JSONDecoder().decode(ImportSession.self, from: JSONEncoder().encode(session)), session)
    }
    func testPlanningResponseRequiresUsefulQuestionOrNonemptyProposal() throws {
        let question = try PlanningReply.decode(#"{"kind":"question","message":"每次多长时间？","options":["半小时","一小时"]}"#, timeZone: zone)
        XCTAssertEqual(question.kind, .question); XCTAssertEqual(question.options.count, 2)
        let unavailable = try PlanningReply.decode(#"{"kind":"unavailable","message":"没有可用时段，换一天吗？"}"#, timeZone: zone)
        XCTAssertTrue(unavailable.drafts.isEmpty)
        for invalid in [#"{"kind":"proposal","message":"好了","events":[]}"#, #"{"kind":"question","message":""}"#, #"{"kind":"execute","message":"写入日历"}"#] {
            XCTAssertThrowsError(try PlanningReply.decode(invalid, timeZone: zone))
        }
    }
    func testPlanningTransportsAcrossAllFormatsUseOnlyAllowedContext() async throws {
        defer { MockURLProtocol.handler = nil }
        let config = URLSessionConfiguration.ephemeral; config.protocolClasses = [MockURLProtocol.self]
        let client = LLMClient(session: URLSession(configuration: config))
        var plan = PlanningConversation(goal: "读完一本书", now: date("2026-10-14T12:00:00Z"), timeZone: zone)
        plan.turns = [PlanningTurn(role: "assistant", text: "每次多久？"), PlanningTurn(role: "user", text: "半小时")]
        var draft = EventDraft(); draft.title = "我的方案"; draft.calendarID = "private-calendar-id"; draft.eventIdentifier = "private-event-id"
        for format in APIFormat.allCases {
            MockURLProtocol.handler = { request in
                var data = request.httpBody ?? Data()
                if let stream = request.httpBodyStream {
                    stream.open(); defer { stream.close() }
                    var buffer = [UInt8](repeating: 0, count: 4096)
                    while stream.hasBytesAvailable { let count = stream.read(&buffer, maxLength: buffer.count); if count <= 0 { break }; data.append(buffer, count: count) }
                }
                let raw = String(decoding: data, as: UTF8.self)
                XCTAssertTrue(raw.contains("availableIntervals")); XCTAssertTrue(raw.contains("conversation"))
                XCTAssertFalse(raw.contains("private-calendar-id")); XCTAssertFalse(raw.contains("private-event-id"))
                XCTAssertNil(request.url?.query)
                let content = #"{"kind":"question","message":"晚上几点方便？","options":["七点","八点"]}"#
                let envelope: [String: Any]
                switch format {
                case .openAI: envelope = ["choices": [["message": ["content": content], "finish_reason": "stop"]]]
                case .claude: envelope = ["content": [["type": "text", "text": content]], "stop_reason": "end_turn"]
                case .gemini: envelope = ["candidates": [["content": ["parts": [["text": content]]], "finishReason": "STOP"]]]
                }
                return (200, try JSONSerialization.data(withJSONObject: envelope))
            }
            let result = try await client.plan(conversation: plan, drafts: [draft], timeZone: zone, referenceDate: plan.start,
                available: [DateInterval(start: plan.start, end: plan.end)], configuration: APIConfiguration(baseURL: "https://test.example/custom", model: "model", format: format), apiKey: "fixture-key")
            XCTAssertEqual(result.kind, .question)
        }
    }
}
