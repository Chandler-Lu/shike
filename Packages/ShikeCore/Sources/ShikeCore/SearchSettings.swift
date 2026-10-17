import Foundation

public enum SearchService: String, Codable, CaseIterable, Identifiable, Sendable {
    case bocha, tavily
    public var id: String { rawValue }
    public var title: String { self == .bocha ? "博查" : "Tavily" }
    public var officialURL: String { self == .bocha ? "https://api.bochaai.com" : "https://api.tavily.com" }
}

public struct SearchConfiguration: Codable, Equatable, Sendable {
    public var service: SearchService
    public var baseURL: String { service.officialURL }
    public var credentialID: String?
    public init(service: SearchService, credentialID: String? = nil) {
        self.service = service; self.credentialID = credentialID
    }
    private enum CodingKeys: String, CodingKey { case service, baseURL, credentialID }
    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        service = try values.decode(SearchService.self, forKey: .service)
        credentialID = try values.decodeIfPresent(String.self, forKey: .credentialID)
        // Ignore historical custom addresses from local settings, iCloud and backups.
    }
    public func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(service, forKey: .service)
        try values.encode(baseURL, forKey: .baseURL)
        try values.encodeIfPresent(credentialID, forKey: .credentialID)
    }
    public func endpoint() throws -> URL {
        URL(string: baseURL + (service == .bocha ? "/v1/web-search" : "/search"))!
    }
    public var authorizationScope: String? { (try? endpoint()).map { service.rawValue + "|" + $0.absoluteString } }
}

public struct SearchSettings: Codable, Equatable, Sendable {
    public var enabled = false
    public var selectedService: SearchService = .bocha
    public var configurations = SearchService.allCases.map { SearchConfiguration(service: $0) }
    public init() {}
    public var selected: SearchConfiguration { configuration(for: selectedService) }
    public func configuration(for service: SearchService) -> SearchConfiguration {
        configurations.first { $0.service == service } ?? SearchConfiguration(service: service)
    }
    public mutating func set(_ configuration: SearchConfiguration) {
        configurations.removeAll { $0.service == configuration.service }
        configurations.append(configuration)
    }
    public func validate() throws {
        guard configurations.count <= 2, Set(configurations.map(\.service)).count == configurations.count else {
            throw ShikeError.message("搜索配置无效。")
        }
        for value in configurations {
            guard (value.credentialID?.count ?? 0) <= 100 else { throw ShikeError.message("搜索凭据标识无效。") }
        }
    }
    /// Explicit backup allowlist: never export a Keychain association.
    public var withoutCredentials: SearchSettings {
        var value = self
        value.configurations = configurations.map { SearchConfiguration(service: $0.service) }
        return value
    }
}

public struct PlanningSource: Codable, Equatable, Identifiable, Sendable {
    public enum ContentKind: String, Codable, Sendable { case summary, page }
    public var id: String
    public var title: String
    public var url: URL
    public var content: String
    public var kind: ContentKind
    public var retrievedAt: Date
    public init(id: String = UUID().uuidString, title: String, url: URL, content: String,
                kind: ContentKind = .summary, retrievedAt: Date = .now) {
        self.id = id; self.title = String(title.prefix(200)); self.url = url
        self.content = String(content.prefix(kind == .page ? 6000 : 1800)); self.kind = kind; self.retrievedAt = retrievedAt
    }
}

public struct PlanningResearch: Codable, Equatable, Sendable {
    public var sources: [PlanningSource] = []
    public var queries: [String] = []
    public var warnings: [String] = []
    public var contextKey: String = ""
    public var updatedAt: Date = .now
    public init() {}
    public func validate() throws {
        guard sources.count <= 16, queries.count <= 20, warnings.count <= 10,
              contextKey.count <= 32_000, Set(sources.map(\.id)).count == sources.count,
              queries.allSatisfy({ $0.count <= 300 }), warnings.allSatisfy({ $0.count <= 300 }),
              sources.allSatisfy({ $0.id.count <= 100 && $0.title.count <= 200 && $0.content.count <= 6000 &&
                  $0.url.absoluteString.count <= 4096 && PublicWebURL.isAllowed($0.url) }) else {
            throw ShikeError.message("规划参考资料无效或过长。")
        }
    }
}
