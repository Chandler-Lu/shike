import Foundation
import ShikeCore

/// Permission is scoped to the receiving service and data categories, never to a model or API key.
struct ExtractionConsent: Codable, Equatable, Identifiable {
    static let policyVersion = 2
    let serviceURL: String
    let includesCalendarNames: Bool
    let includesPlanning: Bool
    let includesAvailability: Bool
    var mask: Int { 1 | (includesCalendarNames ? 2 : 0) | (includesPlanning ? 4 : 0) | (includesAvailability ? 8 : 0) }
    var id: String { "\(serviceURL)|\(mask)|\(Self.policyVersion)" }
    var host: String { URL(string: serviceURL)?.host ?? serviceURL }

    init(configuration: APIConfiguration, includesCalendarNames: Bool, includesPlanning: Bool = false, includesAvailability: Bool = false) throws {
        // Normalize roots and full extraction URLs through the same code as actual requests.
        // A Gemini model change must not look like a new recipient; a proxy path change must.
        var parts = URLComponents(url: try configuration.modelsEndpoint(), resolvingAgainstBaseURL: false)!
        parts.path = String(parts.path.dropLast("/models".count))
        parts.host = parts.host?.lowercased()
        if parts.port == 443 { parts.port = nil }
        serviceURL = parts.url!.absoluteString
        self.includesCalendarNames = includesCalendarNames
        self.includesPlanning = includesPlanning
        self.includesAvailability = includesAvailability
    }
}

@MainActor final class ExtractionConsentStore {
    private let defaults: UserDefaults
    private let key = "shike.extractionConsent.v2"
    init(defaults: UserDefaults? = nil) {
        self.defaults = defaults ?? UserDefaults(suiteName: AppIdentity.isUITesting ? "Shike.UITests" : AppIdentity.appGroup)!
    }
    // Read through on every check, so the app and extension do not retain a stale in-memory grant.
    private var grants: [String: Int] {
        var result = defaults.dictionary(forKey: key) as? [String: Int] ?? [:]
        // v1 stored levels, not bitmasks. Migrate text/names only; never authorize planning implicitly.
        for (service, level) in defaults.dictionary(forKey: "shike.extractionConsent.v1") as? [String: Int] ?? [:] {
            result[service, default: 0] |= level >= 2 ? 3 : 1
        }
        return result
    }
    func allows(_ scope: ExtractionConsent) -> Bool {
        guard let granted = grants[scope.serviceURL] else { return false }
        return granted & scope.mask == scope.mask
    }
    func grant(_ scope: ExtractionConsent) {
        var values = grants
        values[scope.serviceURL] = (values[scope.serviceURL] ?? 0) | scope.mask
        defaults.set(values, forKey: key)
    }
    func revokeAll() { defaults.removeObject(forKey: key); defaults.removeObject(forKey: "shike.extractionConsent.v1") }
}

enum AppLegal {
    static let privacyURL = URL(string: "https://github.com/Chandler-Lu/shike/blob/main/PRIVACY.md")!
    static let supportURL = URL(string: "https://github.com/Chandler-Lu/shike/issues")!
    static let emailURL = URL(string: "mailto:shike@yeslu.cn?subject=Shike%20Support")!
    static var version: String {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0"
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "1"
        return "拾刻计划 \(version)（\(build)）"
    }
}
