import XCTest
@testable import ShikeCore

final class CountdownExtractionTests: XCTestCase {
    private let zone = TimeZone(identifier: "Asia/Shanghai")!
    private var now: Date { CivilDate(year: 2026, month: 10, day: 14).date(in: zone)! }
    override func tearDown() { MockURLProtocol.handler = nil }
    private func decode(_ text: String) throws -> [CountdownDraft] {
        try CountdownExtraction.decode(text, referenceDate: now, timeZone: zone, categories: CountdownCategory.defaults)
    }
    func testMultipleDatesPreservePastSecondsRemindersAndCategory() throws {
        let output = #"{"countdowns":[{"title":"在一起","date":"2020-05-20","category":"纪念日","recurrence":"yearly","includesStartDay":true,"reminder":{"milestoneDays":[520,1314,520],"hour":13,"minute":14}},{"title":"出发","date":"2026-12-01","time":{"hour":13,"minute":14,"second":52},"timeZone":"Asia/Shanghai"}]}"#
        let result = try decode(output)
        XCTAssertEqual(result.count, 2)
        XCTAssertEqual(result[0].entry.anchorDate.description, "2020-05-20")
        XCTAssertEqual(result[0].entry.recurrence, .yearly)
        XCTAssertEqual(result[0].entry.reminder.milestones, [520,1314])
        XCTAssertEqual(result[0].entry.reminder.hour, 13)
        XCTAssertTrue(result[0].entry.includesStartDay == true)
        XCTAssertEqual(result[0].entry.categoryID, CountdownCategory.defaults[0].id)
        XCTAssertEqual(result[1].entry.targetTime?.second, 52)
        XCTAssertFalse(result[0].dateMissing)
        XCTAssertNotEqual(result[0].id, result[1].id)
    }
    func testUnknownDateRequiresManualCompletion() throws {
        let result = try decode(#"{"countdowns":[{"title":"旅行","date":null}]}"#)
        XCTAssertTrue(result[0].dateMissing)
        XCTAssertFalse(result[0].reviewNotes.isEmpty)
        XCTAssertFalse(result[0].entry.reminder.isEnabled)
        XCTAssertNil(result[0].entry.timeZoneIdentifier)
    }
    func testAnniversaryAndIntervalRemindersPreserveOriginalCountUpDate() throws {
        let result = try decode(#"{"countdowns":[{"title":"在一起","date":"2020-05-20","reminder":{"anniversaries":true,"dayInterval":500,"milestoneDays":[520,1314]}}]}"#)
        XCTAssertEqual(result[0].entry.anchorDate.description, "2020-05-20")
        XCTAssertEqual(result[0].entry.recurrence, .none)
        XCTAssertEqual(result[0].entry.reminder.anniversaries, true)
        XCTAssertEqual(result[0].entry.reminder.dayInterval, 500)
        XCTAssertEqual(result[0].entry.reminder.milestones, [520, 1314])
        XCTAssertThrowsError(try decode(#"{"countdowns":[{"title":"x","date":"2020-05-20","reminder":{"dayInterval":0}}]}"#))
    }
    func testLunarConversionUsesNativeCalendarAndRejectsNonexistentLeapMonth() throws {
        let result = try decode(#"{"countdowns":[{"title":"中秋","date":null,"calendar":"chinese","lunar":{"year":2026,"month":8,"day":15,"isLeapMonth":false},"recurrence":"yearly"}]}"#)
        XCTAssertEqual(result[0].entry.anchorDate.description, "2026-09-25")
        XCTAssertEqual(CountdownDates.lunarDate(result[0].entry, systemZone: zone)?.day, 15)
        XCTAssertThrowsError(try decode(#"{"countdowns":[{"title":"不存在的闰月","calendar":"chinese","lunar":{"year":2026,"month":8,"day":15,"isLeapMonth":true}}]}"#))
    }
    func testMalformedOrTruncatedBatchDoesNotKeepPartialResults() {
        for output in [
            #"{"countdowns":[{"title":"正常","date":"2026-12-01"},{"title":"坏日期","date":"2026-02-30"}]}"#,
            #"{"countdowns":[{"title":"x","date":"2026-01-01","time":{"hour":24,"minute":0,"second":0}}]}"#,
            #"{"countdowns":[{"title":"x","date":"2026-01-01","timeZone":"Unknown/Place"}]}"#,
            #"{"countdowns":[{"title":"x","date":"2026-01-01","reminder":{"milestoneDays":[0]}}]}"#,
            #"{"countdowns":[{"title":"x","date":"2026-01-01"},"#
        ] { XCTAssertThrowsError(try decode(output)) }
    }
    func testFencesBareArrayEmptyAndBatchLimit() throws {
        XCTAssertEqual(try decode("```json\n[{\"title\":\"旅行\",\"date\":\"2026-12-01\"}]\n```").count, 1)
        XCTAssertTrue(try decode(#"{"countdowns":[]}"#).isEmpty)
        let many = String(data: try JSONSerialization.data(withJSONObject: ["countdowns": Array(repeating: ["title":"x","date":"2026-12-01"], count:51)]), encoding:.utf8)!
        XCTAssertThrowsError(try decode(many))
    }
    func testOpenAIUsesCountdownProtocolWithoutSendingExistingCategories() async throws {
        let config = URLSessionConfiguration.ephemeral; config.protocolClasses = [MockURLProtocol.self]
        let session = URLSession(configuration: config); defer { session.invalidateAndCancel() }
        let client = LLMClient(session: session)
        for format in APIFormat.allCases {
            MockURLProtocol.handler = { request in
                var data = request.httpBody ?? Data()
                if let stream = request.httpBodyStream {
                    stream.open(); defer { stream.close() }
                    var buffer = [UInt8](repeating:0, count:4096)
                    while stream.hasBytesAvailable { let n=stream.read(&buffer,maxLength:buffer.count); if n<=0 { break }; data.append(buffer,count:n) }
                }
                let text = String(decoding: data, as: UTF8.self)
                XCTAssertTrue(text.contains("countdowns")); XCTAssertFalse(text.contains("PRIVATE-CATEGORY"))
                let content = #"{"countdowns":[{"title":"旅行","date":"2026-12-01"}]}"#
                let envelope: [String:Any]
                switch format {
                case .openAI: envelope=["choices":[["message":["content":content],"finish_reason":"stop"]]]
                }
                return (200, try JSONSerialization.data(withJSONObject: envelope))
            }
            let result = try await client.extractCountdowns(text:"12 月 1 日旅行", referenceDate:now, timeZone:zone,
                configuration: APIConfiguration(baseURL:"https://example.com", model:"fixture", format:format), apiKey:"fixture",
                categories:[CountdownCategory(name:"PRIVATE-CATEGORY")])
            XCTAssertEqual(result.first?.entry.title,"旅行")
        }
    }
}
