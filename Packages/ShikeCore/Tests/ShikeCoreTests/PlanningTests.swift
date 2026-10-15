import XCTest
@testable import ShikeCore

final class PlanningTests: XCTestCase {
    private let zone = TimeZone(identifier: "America/New_York")!
    private func date(_ text: String) -> Date { ISO8601DateFormatter().date(from: text)! }
    func testPlanningUsesLocalOffsetsForEveryTimestampIncludingDST() async throws {
        defer { MockURLProtocol.handler = nil }
        let config = URLSessionConfiguration.ephemeral; config.protocolClasses = [MockURLProtocol.self]
        let client = LLMClient(session: URLSession(configuration: config))
        for (zoneName, now, rangeEnd, start, end) in [
            ("Asia/Shanghai", "2026-10-15T21:25:00+08:00", "2026-10-22T00:00:00+08:00", "2026-10-17T08:00:00+08:00", "2026-10-17T17:00:00+08:00"),
            ("America/New_York", "2026-03-07T12:00:00-05:00", "2026-03-14T00:00:00-04:00", "2026-03-08T08:00:00-04:00", "2026-03-08T17:00:00-04:00")
        ] {
            let timeZone = TimeZone(identifier: zoneName)!
            let reference = date(now)
            let plan = PlanningConversation(goal: "周六去北京旅行一天", now: reference, timeZone: timeZone)
            var draft = EventDraft(); draft.title = "旅行"; draft.start = date(start); draft.end = date(end)
            for format in APIFormat.allCases {
                MockURLProtocol.handler = { request in
                    var data = request.httpBody ?? Data()
                    if let stream = request.httpBodyStream {
                        stream.open(); defer { stream.close() }
                        var buffer = [UInt8](repeating: 0, count: 4096)
                        while stream.hasBytesAvailable { let n = stream.read(&buffer, maxLength: buffer.count); if n <= 0 { break }; data.append(buffer, count: n) }
                    }
                    let raw = String(decoding: data, as: UTF8.self)
                    XCTAssertTrue(raw.contains("不能用它标记未经换算的当地时间"))
                    let body = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
                    let input: String
                    if format == .gemini {
                        let contents = try XCTUnwrap(body["contents"] as? [[String: Any]])
                        input = try XCTUnwrap((contents.first?["parts"] as? [[String: String]])?.first?["text"])
                    } else { input = try XCTUnwrap((body["messages"] as? [[String: String]])?.last?["content"]) }
                    let payload = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(input.utf8)) as? [String: Any])
                    XCTAssertEqual(payload["now"] as? String, now)
                    XCTAssertEqual(payload["rangeEndExclusive"] as? String, rangeEnd)
                    let iso = ISO8601DateFormatter(); iso.timeZone = timeZone
                    XCTAssertEqual(payload["rangeStart"] as? String, iso.string(from: plan.start))
                    let intervals = try XCTUnwrap(payload["availableIntervals"] as? [[String: String]])
                    XCTAssertEqual(intervals.first?["start"], now); XCTAssertEqual(intervals.first?["end"], rangeEnd)
                    let proposal = try XCTUnwrap(payload["currentProposal"] as? [[String: Any]])
                    XCTAssertEqual(proposal.first?["start"] as? String, start)
                    XCTAssertEqual(proposal.first?["end"] as? String, end)
                    let content = "{\"kind\":\"proposal\",\"message\":\"当地 08:00 至 17:00\",\"events\":[{\"title\":\"北京旅行\",\"start\":\"\(start)\",\"end\":\"\(end)\",\"timeZone\":\"\(zoneName)\"}]}"
                    let envelope: [String: Any]
                    switch format {
                    case .openAI: envelope = ["choices": [["message": ["content": content], "finish_reason": "stop"]]]
                    case .claude: envelope = ["content": [["type": "text", "text": content]], "stop_reason": "end_turn"]
                    case .gemini: envelope = ["candidates": [["content": ["parts": [["text": content]]], "finishReason": "STOP"]]]
                    }
                    return (200, try JSONSerialization.data(withJSONObject: envelope))
                }
                let reply = try await client.plan(conversation: plan, drafts: [draft], timeZone: timeZone, referenceDate: reference,
                    available: [DateInterval(start: reference, end: plan.end)], configuration: APIConfiguration(baseURL: "https://test.example", model: "fixture", format: format), apiKey: "fixture", prompts: PromptSettings(planning: "自定义规则"))
                var calendar = Calendar(identifier: .gregorian); calendar.timeZone = timeZone
                XCTAssertEqual(calendar.component(.hour, from: try XCTUnwrap(reply.drafts.first?.start)), 8)
                XCTAssertEqual(calendar.component(.hour, from: try XCTUnwrap(reply.drafts.first?.end)), 17)
            }
        }
        // UTC is still a valid absolute instant; don't blindly subtract eight hours from model output.
        let utc = try PlanningReply.decode(#"{"kind":"proposal","message":"上海 08:00","events":[{"title":"出发","start":"2026-10-17T00:00:00Z","end":"2026-10-17T01:00:00Z","timeZone":"Asia/Shanghai"}]}"#, timeZone: TimeZone(identifier: "Asia/Shanghai")!)
        XCTAssertEqual(utc.drafts.first?.start, date("2026-10-17T08:00:00+08:00"))
    }
    func testOnlyAnsweredQuestionsAreMatchedIgnoringPunctuationAndSpacing() {
        var plan = PlanningConversation(goal: "测试")
        plan.turns = [PlanningTurn(role: "assistant", text: "每次希望安排多久？")]
        XCTAssertFalse(plan.hasAnsweredQuestion("每次 希望安排多久?"))
        plan.turns.append(PlanningTurn(role: "user", text: "半小时"))
        XCTAssertTrue(plan.hasAnsweredQuestion("每次 希望安排多久?"))
        XCTAssertFalse(plan.hasAnsweredQuestion("每天几点方便？"))
        XCTAssertFalse(plan.hasAnsweredQuestion("半小时是包含通勤的时间吗？"))
    }

    func testRepeatedAnsweredQuestionGetsOneCorrectionAcrossProviders() async throws {
        defer { MockURLProtocol.handler = nil }
        let config = URLSessionConfiguration.ephemeral; config.protocolClasses = [MockURLProtocol.self]
        let session = URLSession(configuration: config); defer { session.invalidateAndCancel() }
        let client = LLMClient(session: session)
        var plan = PlanningConversation(goal: "测试", timeZone: zone)
        plan.turns = [PlanningTurn(role: "assistant", text: "每次希望安排多久？"), PlanningTurn(role: "user", text: "半小时")]
        for format in APIFormat.allCases {
            for keepsRepeating in [false, true] {
                var count = 0
                MockURLProtocol.handler = { request in
                    var data = request.httpBody ?? Data()
                    if let stream = request.httpBodyStream {
                        stream.open(); defer { stream.close() }
                        var buffer = [UInt8](repeating: 0, count: 4096)
                        while stream.hasBytesAvailable { let n = stream.read(&buffer, maxLength: buffer.count); if n <= 0 { break }; data.append(buffer, count: n) }
                    }
                    count += 1
                    let raw = String(decoding: data, as: UTF8.self)
                    XCTAssertTrue(raw.contains("先确认目标中的具体活动"))
                    XCTAssertTrue(raw.contains("半小时"))
                    if count == 2 { XCTAssertTrue(raw.contains("rejectedQuestion")) }
                    let message = count == 1 || keepsRepeating ? "每次 希望安排多久?" : "具体要安排什么测试？"
                    let content = String(decoding: try JSONSerialization.data(withJSONObject: ["kind": "question", "message": message, "options": []]), as: UTF8.self)
                    let envelope: [String: Any]
                    switch format {
                    case .openAI: envelope = ["choices": [["message": ["content": content], "finish_reason": "stop"]]]
                    case .claude: envelope = ["content": [["type": "text", "text": content]], "stop_reason": "end_turn"]
                    case .gemini: envelope = ["candidates": [["content": ["parts": [["text": content]]], "finishReason": "STOP"]]]
                    }
                    return (200, try JSONSerialization.data(withJSONObject: envelope))
                }
                do {
                    let reply = try await client.plan(conversation: plan, drafts: [], timeZone: zone, referenceDate: .now,
                        available: nil, configuration: APIConfiguration(baseURL: "https://test.example", model: "fixture", format: format), apiKey: "fixture")
                    XCTAssertFalse(keepsRepeating)
                    XCTAssertEqual(reply.message, "具体要安排什么测试？")
                } catch {
                    XCTAssertTrue(keepsRepeating, "Unexpected error: \(error)")
                    XCTAssertTrue(error.localizedDescription.contains("重复询问"))
                }
                XCTAssertEqual(count, 2, "只允许纠正一次，不能无限请求或把重复问题交给用户")
            }
        }
    }

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
    func testAllDayIncludesItsFinalDayWhenEndIsNotMidnight() {
        for (end, expectedEnd) in [
            ("2026-10-14T23:59:59+08:00", "2026-10-15T00:00:00-04:00"),
            ("2026-10-16T23:59:00+08:00", "2026-10-17T00:00:00-04:00"),
            ("2026-10-15T00:00:00+08:00", "2026-10-15T00:00:00-04:00")
        ] {
            let event = CalendarEventSnapshot(eventID: "all", itemID: "all", calendarID: "c", title: "全天",
                start: date("2026-10-14T00:00:00+08:00"), end: date(end), allDay: true, timeZone: "Asia/Shanghai")
            XCTAssertEqual(event.interval(in: zone), DateInterval(start: date("2026-10-14T00:00:00-04:00"), end: date(expectedEnd)))
        }
    }
    func testOldImportAndSettingsDecodeWithoutPlanningFields() throws {
        var session = ImportSession(); session.text = "旧记录"
        let data = try JSONEncoder().encode(session)
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        object.removeValue(forKey: "planning")
        let restored = try JSONDecoder().decode(ImportSession.self, from: JSONSerialization.data(withJSONObject: object))
        XCTAssertEqual(restored.text, "旧记录"); XCTAssertNil(restored.planning)
        XCTAssertNil(restored.referenceDate); XCTAssertEqual(restored.effectiveReferenceDate, restored.createdAt)
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
                XCTAssertTrue(raw.contains("自定义安排偏好"))
                XCTAssertTrue(raw.contains("全天日程不占用时间"), "自定义提示词也必须保留应用的全天占用规则")
                XCTAssertFalse(raw.contains("private-calendar-id")); XCTAssertFalse(raw.contains("private-event-id"))
                XCTAssertEqual(request.url?.query, format == .gemini ? "alt=sse" : nil)
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
                available: [DateInterval(start: plan.start, end: plan.end)], configuration: APIConfiguration(baseURL: "https://test.example/custom", model: "model", format: format), apiKey: "fixture-key",
                prompts: PromptSettings(planning: "自定义安排偏好"))
            XCTAssertEqual(result.kind, .question)
        }
    }
}
