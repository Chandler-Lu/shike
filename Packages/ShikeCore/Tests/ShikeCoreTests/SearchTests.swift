import XCTest
@testable import ShikeCore

final class SearchTests: XCTestCase {
    private func session() -> URLSession {
        let config = URLSessionConfiguration.ephemeral; config.protocolClasses = [SearchFixtureProtocol.self]
        return URLSession(configuration: config)
    }
    func testSearchEndpointsStayOfficialWhenRestoringCustomAddresses() throws {
        for service in SearchService.allCases {
            let expected = service == .bocha ? "https://api.bochaai.com/v1/web-search" : "https://api.tavily.com/search"
            XCTAssertEqual(try SearchConfiguration(service: service).endpoint().absoluteString, expected)
            for address in ["https://custom.example/proxy", "", "http://old.example", "https://u:p@example.com?api_key=secret"] {
                let old = try JSONSerialization.data(withJSONObject: ["service": service.rawValue, "baseURL": address, "credentialID": "existing-key"])
                let restored = try JSONDecoder().decode(SearchConfiguration.self, from: old)
                XCTAssertEqual(restored.credentialID, "existing-key")
                XCTAssertEqual(restored.baseURL, service.officialURL)
                XCTAssertEqual(try restored.endpoint().absoluteString, expected)
                let encoded = try JSONSerialization.jsonObject(with: JSONEncoder().encode(restored)) as? [String: String]
                XCTAssertEqual(encoded?["baseURL"], service.officialURL)
            }
        }
    }
    func testBothSearchAdaptersUseOnlySearchKeyAndMinimalQuery() async throws {
        defer { SearchFixtureProtocol.handler = nil }
        for service in SearchService.allCases {
            SearchFixtureProtocol.handler = { request in
                XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer search-key")
                XCTAssertEqual(request.url?.query, nil)
                XCTAssertEqual(request.url?.absoluteString, service == .bocha ? "https://api.bochaai.com/v1/web-search" : "https://api.tavily.com/search")
                let payload = try XCTUnwrap(JSONSerialization.jsonObject(with: request.bodyData) as? [String: Any])
                XCTAssertEqual(payload["query"] as? String, "北京 开放时间")
                XCTAssertNil(payload["api_key"]); XCTAssertNil(payload["conversation"]); XCTAssertNil(payload["availableIntervals"])
                let row: [String: Any] = ["url": "https://www.dpm.org.cn", "name": "故宫", "title": "故宫", "summary": "开放时间", "content": "开放时间"]
                let root: [String: Any] = service == .bocha ? ["code": 200, "data": ["webPages": ["value": [row]]]] : ["results": [row]]
                return (200, ["Content-Type": "application/json"], try JSONSerialization.data(withJSONObject: root))
            }
            let client = SearchAPIClient(configuration: SearchConfiguration(service: service), apiKey: "search-key", session: session())
            let sources = try await client.search("北京 开放时间")
            XCTAssertEqual(sources.count, 1); XCTAssertEqual(sources.first?.kind, .summary)
            XCTAssertEqual(sources.first?.content, "开放时间")
        }
    }
    func testSearchRejectsServiceErrorEvenWithHTTP200() async throws {
        defer { SearchFixtureProtocol.handler = nil }
        SearchFixtureProtocol.handler = { _ in (200, ["Content-Type": "application/json"], Data(#"{"code":401,"message":"private token"}"#.utf8)) }
        do {
            _ = try await SearchAPIClient(configuration: .init(service: .bocha), apiKey: "fixture", session: session()).search("北京")
            XCTFail()
        } catch { XCTAssertFalse(error.localizedDescription.contains("private token")); XCTAssertTrue(error.localizedDescription.contains("401")) }
    }
    func testHTTPAuthenticationAndRateLimitFailuresAreReadable() async throws {
        defer { SearchFixtureProtocol.handler = nil }
        for status in [401, 429, 503] {
            SearchFixtureProtocol.handler = { _ in (status, ["Content-Type": "application/json"], Data("do not show server body".utf8)) }
            do {
                _ = try await SearchAPIClient(configuration: .init(service: .tavily), apiKey: "fixture", session: session()).search("北京")
                XCTFail()
            } catch { XCTAssertFalse(error.localizedDescription.contains("server body")) }
        }
    }
    func testPageReaderExtractsTextWithoutScriptsOrCredentials() async throws {
        defer { SearchFixtureProtocol.handler = nil }
        SearchFixtureProtocol.handler = { request in
            XCTAssertNil(request.value(forHTTPHeaderField: "Authorization")); XCTAssertNil(request.value(forHTTPHeaderField: "Cookie"))
            let html = "<html><head><title>景点开放信息</title><script>bad-script-marker</script></head><body><nav>nav-marker</nav><main><p>" + String(repeating: "开放时间仅供参考，请核对所选日期。", count: 20) + "</p></main></body></html>"
            return (200, ["Content-Type": "text/html; charset=utf-8"], Data(html.utf8))
        }
        let source = PlanningSource(id: "keep-id", title: "摘要", url: URL(string: "https://www.dpm.org.cn/Home.html")!, content: "原摘要")
        let result = try await WebPageReader(session: session()).read(source)
        XCTAssertEqual(result.kind, .page); XCTAssertEqual(result.id, source.id)
        XCTAssertEqual(result.title, "景点开放信息")
        XCTAssertFalse(result.content.contains("bad-script-marker")); XCTAssertFalse(result.content.contains("nav-marker"))
    }
    func testReaderRejectsPrivateURLsUnsupportedContentAndOversize() async throws {
        for value in ["https://localhost", "https://127.0.0.1/x", "https://127.1", "https://10.0.0.1", "https://192.168.0.1", "https://169.254.169.254", "https://[::1]", "https://[::ffff:127.0.0.1]", "file:///tmp/data", "http://www.example.com", "https://example.local/x", "https://u:p@example.com"] {
            XCTAssertFalse(PublicWebURL.isAllowed(URL(string: value)!), value)
        }
        XCTAssertTrue(PublicWebURL.isAllowed(URL(string: "https://www.dpm.org.cn")!))
        defer { SearchFixtureProtocol.handler = nil }
        let source = PlanningSource(title: "资料", url: URL(string: "https://www.dpm.org.cn")!, content: "")
        for headers in [["Content-Type": "application/pdf"], ["Content-Type": "text/html", "Content-Length": "3000000"]] {
            SearchFixtureProtocol.handler = { _ in (200, headers, Data("body".utf8)) }
            do { _ = try await WebPageReader(session: session()).read(source); XCTFail() } catch {}
        }
    }
    func testRevokedPermissionDoesNotStartNetworkRequest() async throws {
        defer { SearchFixtureProtocol.handler = nil }
        SearchFixtureProtocol.handler = { _ in XCTFail("network started after revocation"); return (200, [:], Data()) }
        do { _ = try await SearchAPIClient(configuration: .init(service: .tavily), apiKey: "fixture", session: session(), isAllowed: { false }).search("北京"); XCTFail() }
        catch { XCTAssertTrue(error is SearchToolError) }
    }
    func testExportedSearchPreferencesRemoveCredentialAssociation() throws {
        var settings = SearchSettings(); settings.enabled = true
        settings.set(SearchConfiguration(service: .bocha, credentialID: "secret-credential-id"))
        let preferences = AppDataExport.PreferencesData(iCloudEnabled: false, categoryRoutingEnabled: false,
            defaultCalendar: nil, categoryCalendars: [:], activeProfileID: "", calendar: CalendarPreferences(), search: settings)
        let text = String(decoding: try JSONEncoder().encode(preferences), as: UTF8.self)
        XCTAssertFalse(text.contains("secret-credential-id")); XCTAssertFalse(text.contains("credentialID"))
        XCTAssertTrue(text.contains("bocha")); XCTAssertEqual(preferences.search?.enabled, true)
    }
    func testOldPlanningRecordsDecodeAndResearchRoundTrips() throws {
        var plan = PlanningConversation(goal: "去北京")
        let old = try JSONEncoder().encode(plan)
        XCTAssertNil(try JSONDecoder().decode(PlanningConversation.self, from: old).research)
        var research = PlanningResearch()
        research.sources = [PlanningSource(title: "来源", url: URL(string: "https://www.dpm.org.cn")!, content: "摘要")]
        plan.research = research; plan.sourceIDs = research.sources.map(\.id)
        XCTAssertEqual(try JSONDecoder().decode(PlanningConversation.self, from: JSONEncoder().encode(plan)), plan)
        try research.validate()
    }
}

private final class SearchFixtureProtocol: URLProtocol {
    static var handler: ((URLRequest) throws -> (Int, [String: String], Data))?
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        do {
            let (status, headers, data) = try Self.handler!(request)
            client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/1.1", headerFields: headers)!, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data); client?.urlProtocolDidFinishLoading(self)
        } catch { client?.urlProtocol(self, didFailWithError: error) }
    }
    override func stopLoading() {}
}
private extension URLRequest {
    var bodyData: Data {
        if let httpBody { return httpBody }
        guard let stream = httpBodyStream else { return Data() }
        stream.open(); defer { stream.close() }
        var data = Data(), buffer = [UInt8](repeating: 0, count: 4096)
        while stream.hasBytesAvailable { let n = stream.read(&buffer, maxLength: buffer.count); if n <= 0 { break }; data.append(buffer, count: n) }
        return data
    }
}
