import Foundation
import SwiftSoup
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

public protocol SearchProvider: Sendable {
    func search(_ query: String) async throws -> [PlanningSource]
    func read(_ source: PlanningSource) async throws -> PlanningSource
}

public enum SearchToolError: Error, LocalizedError {
    case disabled, unavailable(String)
    public var errorDescription: String? {
        switch self {
        case .disabled: return "联网搜索已关闭或配置已变化。"
        case .unavailable(let message): return message
        }
    }
}

public struct SearchAPIClient: SearchProvider, Sendable {
    private let configuration: SearchConfiguration
    private let key: String
    private let http: SearchHTTP
    private let allowed: @Sendable () async -> Bool
    public init(configuration: SearchConfiguration, apiKey: String, session: URLSession? = nil,
                isAllowed: @escaping @Sendable () async -> Bool = { true }) {
        self.configuration = configuration; key = apiKey; http = SearchHTTP(session: session); allowed = isAllowed
    }
    public func search(_ query: String) async throws -> [PlanningSource] {
        guard await allowed() else { throw SearchToolError.disabled }
        let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty, query.count <= 300 else { throw SearchToolError.unavailable("搜索词为空或过长。") }
        guard !key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw SearchToolError.unavailable("搜索 API Key 尚未配置。") }
        var request = URLRequest(url: try configuration.endpoint())
        request.httpMethod = "POST"
        request.setValue("Bearer \(key.trimmingCharacters(in: .whitespacesAndNewlines))", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let body: [String: Any] = configuration.service == .bocha
            ? ["query": query, "summary": true, "freshness": "noLimit", "count": 5]
            : ["query": query, "search_depth": "basic", "max_results": 5, "include_answer": false, "include_raw_content": false]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, _) = try await http.load(request, publicPage: false, isAllowed: allowed)
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw SearchToolError.unavailable("搜索响应格式无法读取。")
        }
        let values: [[String: Any]]
        if configuration.service == .bocha {
            if let code = root["code"] as? Int, code != 200 && code != 0 {
                throw SearchToolError.unavailable("博查搜索请求失败（\(code)），请检查密钥和额度。")
            }
            let payload = root["data"] as? [String: Any] ?? root
            guard let pages = payload["webPages"] as? [String: Any], let rows = pages["value"] as? [[String: Any]] else {
                // Bocha uses null webPages for a successful empty search.
                if payload["webPages"] is NSNull { return [] }
                throw SearchToolError.unavailable("博查搜索返回格式不兼容。")
            }
            values = rows
        } else {
            guard let rows = root["results"] as? [[String: Any]] else { throw SearchToolError.unavailable("Tavily 搜索返回格式不兼容。") }
            values = rows
        }
        var seen = Set<URL>()
        return values.prefix(5).compactMap { value in
            guard let address = value["url"] as? String, let url = URL(string: address), PublicWebURL.isAllowed(url), seen.insert(url).inserted else { return nil }
            let title = (value["title"] ?? value["name"]) as? String ?? url.host ?? "参考资料"
            let content = (value["summary"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? value["content"] as? String ?? value["snippet"] as? String ?? ""
            return PlanningSource(title: title, url: url, content: content)
        }
    }
    public func read(_ source: PlanningSource) async throws -> PlanningSource {
        try await WebPageReader(session: http.injectedSession, isAllowed: allowed).read(source)
    }
}

public struct WebPageReader: Sendable {
    private let http: SearchHTTP
    private let allowed: @Sendable () async -> Bool
    public init(session: URLSession? = nil, isAllowed: @escaping @Sendable () async -> Bool = { true }) {
        http = SearchHTTP(session: session); allowed = isAllowed
    }
    public func read(_ source: PlanningSource) async throws -> PlanningSource {
        guard PublicWebURL.isAllowed(source.url) else { throw SearchToolError.unavailable("只能读取公开 HTTPS 网页。") }
        var request = URLRequest(url: source.url)
        request.setValue("text/html, text/plain;q=0.9", forHTTPHeaderField: "Accept")
        let (data, response) = try await http.load(request, publicPage: true, isAllowed: allowed)
        let mime = response.mimeType?.lowercased() ?? ""
        guard ["text/html", "application/xhtml+xml", "text/plain"].contains(mime) else {
            throw SearchToolError.unavailable("此页面不是可读取的文字网页，保留搜索摘要。")
        }
        var encoding = String.Encoding.utf8
        if let charset = response.textEncodingName {
            let cf = CFStringConvertIANACharSetNameToEncoding(charset as CFString)
            if cf != kCFStringEncodingInvalidId { encoding = String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(cf)) }
        }
        guard let html = String(data: data, encoding: encoding) else { throw SearchToolError.unavailable("网页编码无法读取，保留搜索摘要。") }
        var result = source
        if mime == "text/plain" { result.content = String(html.prefix(6000)) }
        else {
            let document = try SwiftSoup.parse(html)
            try document.select("script,style,noscript,nav,header,footer,form,iframe,svg").remove()
            let body = try document.select("main,article").first() ?? document.body()
            result.content = String((try body?.text() ?? "").prefix(6000))
            let title = try document.title()
            if !title.isEmpty { result.title = String(title.prefix(200)) }
        }
        guard result.content.count >= 40 else { throw SearchToolError.unavailable("网页正文不足，可能需要登录或动态加载，保留搜索摘要。") }
        result.kind = .page; result.retrievedAt = .now
        return result
    }
}

/// Separate sessions keep model credentials, cookies and URL caches out of web requests.
private struct SearchHTTP: Sendable {
    let injectedSession: URLSession?
    init(session: URLSession?) { injectedSession = session }
    func load(_ input: URLRequest, publicPage: Bool, isAllowed: @escaping @Sendable () async -> Bool) async throws -> (Data, HTTPURLResponse) {
        try Task.checkCancellation()
        guard await isAllowed() else { throw SearchToolError.disabled }
        if publicPage, let url = input.url {
            guard PublicWebURL.isAllowed(url) else { throw SearchToolError.unavailable("不能读取此网页地址。") }
            if injectedSession == nil { try PublicWebURL.checkDNS(url) }
        }
        let config = URLSessionConfiguration.ephemeral
        config.httpCookieStorage = nil; config.urlCredentialStorage = nil; config.urlCache = nil
        config.timeoutIntervalForRequest = 20; config.timeoutIntervalForResource = 25
        let session = injectedSession ?? URLSession(configuration: config, delegate: SearchRedirects(publicPage: publicPage), delegateQueue: nil)
        defer { if injectedSession == nil { session.invalidateAndCancel() } }
        var request = input; request.timeoutInterval = 20
        do {
            let (bytes, response) = try await session.bytes(for: request)
            guard let response = response as? HTTPURLResponse else { throw SearchToolError.unavailable("搜索服务未返回有效响应。") }
            guard (200..<300).contains(response.statusCode) else {
                let message: String
                switch response.statusCode {
                case 401, 403: message = publicPage ? "网页拒绝读取，保留搜索摘要。" : "搜索认证失败，请检查 API Key 和账户权限。"
                case 429: message = "搜索频率或额度受限，请稍后重试。"
                default: message = "资料请求失败（HTTP \(response.statusCode)）。"
                }
                throw SearchToolError.unavailable(message)
            }
            let limit = 2_000_000
            guard response.expectedContentLength <= limit else { throw SearchToolError.unavailable("资料过大，已停止读取。") }
            var data = Data()
            for try await byte in bytes {
                guard data.count < limit else { throw SearchToolError.unavailable("资料过大，已停止读取。") }
                data.append(byte)
                if data.count % 16_384 == 0 {
                    try Task.checkCancellation()
                    guard await isAllowed() else { throw SearchToolError.disabled }
                }
            }
            try Task.checkCancellation()
            guard await isAllowed() else { throw SearchToolError.disabled }
            return (data, response)
        } catch is CancellationError { throw CancellationError() }
        catch let error as SearchToolError { throw error }
        catch let error as URLError {
            if error.code == .cancelled { throw CancellationError() }
            throw SearchToolError.unavailable(error.code == .timedOut ? "搜索或网页读取超时。" : "搜索或网页暂时无法连接。")
        }
    }
}

private final class SearchRedirects: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    let publicPage: Bool
    init(publicPage: Bool) { self.publicPage = publicPage }
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        guard let target = request.url else { completionHandler(nil); return }
        if publicPage {
            guard PublicWebURL.isAllowed(target), (try? PublicWebURL.checkDNS(target)) != nil else { completionHandler(nil); return }
            var clean = URLRequest(url: target); clean.setValue("text/html, text/plain;q=0.9", forHTTPHeaderField: "Accept")
            completionHandler(clean)
        } else {
            let original = task.originalRequest?.url
            completionHandler(original?.scheme == target.scheme && original?.host == target.host && original?.port == target.port ? request : nil)
        }
    }
}

public enum PublicWebURL {
    public static func isAllowed(_ url: URL) -> Bool {
        guard url.scheme == "https", let host = url.host?.lowercased(), !host.isEmpty,
              url.user == nil, url.password == nil, url.port == nil || url.port == 443,
              url.absoluteString.count <= 4096 else { return false }
        let name = host.trimmingCharacters(in: CharacterSet(charactersIn: "[]."))
        guard name != "localhost", !name.hasSuffix(".localhost"), !name.hasSuffix(".local"),
              !name.hasSuffix(".internal"), name.contains(".") || name.contains(":") else { return false }
        if name.contains(":") { return publicAddress(name) }
        if name.allSatisfy({ $0.isNumber || $0 == "." }) { return publicAddress(name) }
        return true
    }
    static func publicAddress(_ value: String) -> Bool {
        var v4 = in_addr()
        if inet_pton(AF_INET, value, &v4) == 1 {
            let ip = UInt32(bigEndian: v4.s_addr), a = ip >> 24, b = (ip >> 16) & 255
            return !(a == 0 || a == 10 || a == 127 || a >= 224 || (a == 169 && b == 254) ||
                (a == 172 && (16...31).contains(b)) || (a == 192 && b == 168) || (a == 100 && (64...127).contains(b)) ||
                (a == 192 && b == 0) || (a == 198 && (b == 18 || b == 19)))
        }
        var v6 = in6_addr()
        if inet_pton(AF_INET6, value, &v6) == 1 {
            return withUnsafeBytes(of: &v6) { bytes in
                // Only globally routed unicast; excludes loopback, mapped IPv4, ULA and link-local.
                bytes[0] & 0xe0 == 0x20 && !(bytes[0] == 0x20 && bytes[1] == 0x01 && bytes[2] == 0x0d && bytes[3] == 0xb8)
            }
        }
        return false
    }
    static func checkDNS(_ url: URL) throws {
        guard let host = url.host else { throw SearchToolError.unavailable("网页地址无效。") }
        var hints = addrinfo(); hints.ai_family = AF_UNSPEC
        var result: UnsafeMutablePointer<addrinfo>?
        guard getaddrinfo(host.trimmingCharacters(in: CharacterSet(charactersIn: "[]")), nil, &hints, &result) == 0, let first = result else {
            throw SearchToolError.unavailable("网页域名暂时无法解析。")
        }
        defer { freeaddrinfo(first) }
        var cursor: UnsafeMutablePointer<addrinfo>? = first
        while let item = cursor {
            var buffer = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            guard getnameinfo(item.pointee.ai_addr, item.pointee.ai_addrlen, &buffer, socklen_t(buffer.count), nil, 0, NI_NUMERICHOST) == 0,
                  publicAddress(String(cString: buffer)) else { throw SearchToolError.unavailable("不能读取本地或私有网络地址。") }
            cursor = item.pointee.ai_next
        }
    }
}
