import Foundation
import SwiftData
import Security
import ShikeCore

enum AppIdentity {
    static var appGroup: String { Bundle.main.object(forInfoDictionaryKey: "ShikeAppGroup") as? String ?? "group.app.shike.calendar" }
    static var keychainGroup: String? { Bundle.main.object(forInfoDictionaryKey: "ShikeKeychainGroup") as? String }
    static var isUITesting: Bool {
        #if DEBUG
        ProcessInfo.processInfo.arguments.contains("-ui-testing")
        #else
        false
        #endif
    }
    static var usesDemoCalendar: Bool {
        #if DEBUG && targetEnvironment(simulator)
        if isUITesting && ProcessInfo.processInfo.arguments.contains("-native-calendar-testing") { return false }
        #endif
        return isUITesting
    }
    static var usesFixtureModel: Bool {
        #if DEBUG
        if isUITesting { return true }
        let expiry = UserDefaults(suiteName: appGroup)?.double(forKey: "debugFixtureModelExpiry") ?? 0
        return expiry > Date.now.timeIntervalSince1970
        #else
        return false
        #endif
    }
    static var usesConsentFixture: Bool {
        #if DEBUG
        return (isUITesting && ProcessInfo.processInfo.arguments.contains("-consent-fixture")) ||
            (UserDefaults(suiteName: appGroup)?.double(forKey: "debugFixtureConsentExpiry") ?? 0) > Date.now.timeIntervalSince1970
        #else
        return false
        #endif
    }
    static func configureDebugLaunch() {
        #if DEBUG
        let defaults = UserDefaults(suiteName: appGroup)
        if ProcessInfo.processInfo.arguments.contains("-integration-testing") {
            defaults?.set(Date.now.addingTimeInterval(300).timeIntervalSince1970, forKey: "debugFixtureModelExpiry")
        } else { defaults?.removeObject(forKey: "debugFixtureModelExpiry") }
        if ProcessInfo.processInfo.arguments.contains("-integration-testing") && ProcessInfo.processInfo.arguments.contains("-consent-fixture") {
            defaults?.removeObject(forKey: "shike.extractionConsent.v1")
            defaults?.removeObject(forKey: "shike.extractionConsent.v2")
            defaults?.set(Date.now.addingTimeInterval(300).timeIntervalSince1970, forKey: "debugFixtureConsentExpiry")
        } else { defaults?.removeObject(forKey: "debugFixtureConsentExpiry") }
        #endif
    }
}

@Model final class StoredSession {
    @Attribute(.unique) var id: UUID
    var updatedAt: Date
    var payload: Data
    init(id: UUID, payload: Data) {
        self.id = id; self.payload = payload; updatedAt = .now
    }
}

@MainActor final class SessionStore {
    let container: ModelContainer
    init(inMemory: Bool = false) throws {
        let schema = Schema([StoredSession.self])
        let config: ModelConfiguration
        if inMemory {
            config = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true, cloudKitDatabase: .none)
        } else {
            guard let folder = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: AppIdentity.appGroup) else {
                throw ShikeError.message("无法打开共享存储。请检查主 App 和分享扩展的 App Groups 签名配置。")
            }
            let url = folder.appendingPathComponent("Shike.store")
            config = ModelConfiguration(schema: schema, url: url, cloudKitDatabase: .none)
        }
        container = try ModelContainer(for: schema, configurations: [config])
    }

    func save(_ session: ImportSession) throws {
        let context = ModelContext(container)
        let id = session.id
        let descriptor = FetchDescriptor<StoredSession>(predicate: #Predicate { $0.id == id })
        let data = try JSONEncoder().encode(session)
        if let record = try context.fetch(descriptor).first {
            record.payload = data; record.updatedAt = .now
        } else { context.insert(StoredSession(id: id, payload: data)) }
        try context.save()
        NotificationCenter.default.post(name: .shikeSessionChanged, object: nil)
    }

    func all() throws -> [ImportSession] {
        let context = ModelContext(container)
        return try context.fetch(FetchDescriptor<StoredSession>(sortBy: [SortDescriptor(\.updatedAt, order: .reverse)]))
            .map { try JSONDecoder().decode(ImportSession.self, from: $0.payload) }
    }

    func delete(_ id: UUID) throws {
        try delete([id])
    }
    func delete(_ ids: Set<UUID>) throws {
        guard !ids.isEmpty else { return }
        let context = ModelContext(container)
        for record in try context.fetch(FetchDescriptor<StoredSession>()) where ids.contains(record.id) { context.delete(record) }
        try context.save()
        NotificationCenter.default.post(name: .shikeSessionChanged, object: nil, userInfo: ["deletedIDs": ids])
    }
    func importMissing(_ sessions: [ImportSession]) throws -> Int {
        let context = ModelContext(container)
        let ids = Set(try context.fetch(FetchDescriptor<StoredSession>()).map(\.id))
        let incoming = try sessions.filter { !ids.contains($0.id) }.map { StoredSession(id: $0.id, payload: try JSONEncoder().encode($0)) }
        for item in incoming { context.insert(item) }
        try context.save()
        NotificationCenter.default.post(name: .shikeSessionChanged, object: nil)
        return incoming.count
    }
}

extension Notification.Name { static let shikeSessionChanged = Notification.Name("shikeSessionChanged") }

enum KeychainStore {
    private static var query: [String: Any] {
        var query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                   kSecAttrService as String: "app.shike.model-api",
                                   kSecAttrAccount as String: "api-key"]
        if let group = AppIdentity.keychainGroup, !group.isEmpty { query[kSecAttrAccessGroup as String] = group }
        return query
    }
    static func read() throws -> String {
        let defaults = UserDefaults(suiteName: AppIdentity.appGroup)
        if let data = defaults?.data(forKey: "apiProfiles"),
           let profiles = try? JSONDecoder().decode([APIProfile].self, from: data) {
            guard let profile = profiles.first(where: { $0.id == defaults?.string(forKey: "activeProfileID") }) else { return "" }
            return try readProfile(profile, synchronizable: defaults?.bool(forKey: "iCloudSettingsEnabled") == true)
        }
        if defaults?.bool(forKey: "iCloudSettingsEnabled") == true {
            guard let id = defaults?.string(forKey: "cloudCredentialID") else { return "" }
            return try readCloud(id: id)
        }
        return try readLocal()
    }
    static func readProfile(_ profile: APIProfile, synchronizable: Bool) throws -> String {
        if profile.usesLegacyCredential == true { return try readLocal() }
        guard let id = profile.credentialID else { return "" }
        return try readItem(profileQuery(id: id, synchronizable: synchronizable))
    }
    static func saveProfileKey(_ key: String, id: String, synchronizable: Bool) throws {
        try saveItem(key, query: profileQuery(id: id, synchronizable: synchronizable), synchronizable: synchronizable)
    }
    static func searchKey(id: String, synchronizable: Bool) throws -> String {
        try readItem(searchQuery(id: id, synchronizable: synchronizable))
    }
    static func saveSearchKey(_ key: String, id: String, synchronizable: Bool) throws {
        try saveItem(key, query: searchQuery(id: id, synchronizable: synchronizable), synchronizable: synchronizable)
    }
    private static func searchQuery(id: String, synchronizable: Bool) -> [String: Any] {
        var value = profileQuery(id: id, synchronizable: synchronizable)
        value[kSecAttrService as String] = "app.shike.search-api"
        return value
    }
    private static func profileQuery(id: String, synchronizable: Bool) -> [String: Any] {
        var result = cloudQuery(id: id)
        result[kSecAttrSynchronizable as String] = synchronizable
        return result
    }
    static func readLocal() throws -> String { try readItem(query) }
    static func readCloud(id: String) throws -> String { try readItem(cloudQuery(id: id)) }
    private static func readItem(_ source: [String: Any]) throws -> String {
        var query = source
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return "" }
        guard status == errSecSuccess, let data = result as? Data, let key = String(data: data, encoding: .utf8) else {
            throw ShikeError.message("无法读取 API Key（\(status)）。请检查设备解锁状态与 Keychain Sharing 配置。")
        }
        return key
    }
    static func save(_ key: String) throws { try saveItem(key, query: query, synchronizable: false) }
    static func saveCloud(_ key: String, id: String) throws { try saveItem(key, query: cloudQuery(id: id), synchronizable: true) }
    private static func cloudQuery(id: String) -> [String: Any] {
        var query = query
        query[kSecAttrAccount as String] = "api-key.\(id)"
        query[kSecAttrSynchronizable as String] = true
        return query
    }
    private static func saveItem(_ key: String, query: [String: Any], synchronizable: Bool) throws {
        let clean = key.trimmingCharacters(in: .whitespacesAndNewlines)
        if clean.isEmpty {
            let status = SecItemDelete(query as CFDictionary)
            guard status == errSecSuccess || status == errSecItemNotFound else { throw failure(status) }
            return
        }
        let attributes: [String: Any] = [kSecValueData as String: Data(clean.utf8),
                                        kSecAttrAccessible as String: synchronizable ? kSecAttrAccessibleWhenUnlocked : kSecAttrAccessibleWhenUnlockedThisDeviceOnly]
        var status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if status == errSecItemNotFound {
            var addition = query
            attributes.forEach { addition[$0] = $1 }
            status = SecItemAdd(addition as CFDictionary, nil)
        }
        guard status == errSecSuccess else { throw failure(status) }
    }
    private static func failure(_ status: OSStatus) -> ShikeError {
        .message("API Key 保存失败（\(status)）。请检查 Keychain Sharing 签名配置。")
    }
}

@MainActor protocol CloudPreferencesStore: AnyObject {
    var accountAvailable: Bool { get }
    func data(forKey key: String) -> Data?
    func set(_ data: Data, forKey key: String)
    func synchronize() -> Bool
}

@MainActor final class AppleCloudPreferencesStore: CloudPreferencesStore {
    let store = NSUbiquitousKeyValueStore.default
    var accountAvailable: Bool { FileManager.default.ubiquityIdentityToken != nil }
    func data(forKey key: String) -> Data? { store.data(forKey: key) }
    func set(_ data: Data, forKey key: String) { store.set(data, forKey: key) }
    func synchronize() -> Bool { store.synchronize() }
}

@MainActor final class Preferences: ObservableObject {
    static let cloudKey = "shike.settings.v1"
    private let defaults: UserDefaults
    private let cloud: (any CloudPreferencesStore)?
    private var cloudObserver: NSObjectProtocol?
    private var choices: [String: CalendarReference] = [:]
    private var defaultReference: CalendarReference?
    private var categoryReferences: [String: CalendarReference] = [:]
    @Published private(set) var calendarPreferences = CalendarPreferences()
    @Published private(set) var promptSettings = PromptSettings()
    @Published private(set) var searchSettings = SearchSettings()
    @Published private(set) var profiles: [APIProfile] = []
    @Published private(set) var activeProfileID = ""
    @Published var configuration: APIConfiguration
    @Published var defaultCalendarID: String
    @Published private(set) var categoryRoutingEnabled: Bool
    @Published private(set) var categoryCalendars: [String: String]
    @Published private(set) var iCloudEnabled: Bool
    @Published private(set) var syncStatus = "尚未开启"
    @Published private(set) var syncRevision = UUID()

    init(defaults: UserDefaults? = nil, cloud: (any CloudPreferencesStore)? = nil) {
        self.defaults = defaults ?? (AppIdentity.isUITesting ? UserDefaults(suiteName: "Shike.UITests")! : UserDefaults(suiteName: AppIdentity.appGroup)!)
        self.cloud = cloud ?? (defaults == nil && !AppIdentity.isUITesting ? AppleCloudPreferencesStore() : nil)
        let defaults = self.defaults
        configuration = APIConfiguration(baseURL: defaults.string(forKey: "apiBaseURL") ?? "", model: defaults.string(forKey: "model") ?? "")
        defaultCalendarID = defaults.string(forKey: "defaultCalendarID") ?? ""
        categoryRoutingEnabled = defaults.bool(forKey: "categoryRoutingEnabled")
        categoryCalendars = defaults.dictionary(forKey: "categoryCalendars") as? [String: String] ?? [:]
        iCloudEnabled = defaults.bool(forKey: "iCloudSettingsEnabled")
        restoreReferences(); restoreProfiles()
        restoreCalendarPreferences()
        restorePromptSettings()
        restoreSearchSettings()
        if let apple = self.cloud as? AppleCloudPreferencesStore {
            cloudObserver = NotificationCenter.default.addObserver(forName: NSUbiquitousKeyValueStore.didChangeExternallyNotification,
                                                                  object: apple.store, queue: .main) { [weak self] notification in
                let reason = notification.userInfo?[NSUbiquitousKeyValueStoreChangeReasonKey] as? Int
                Task { @MainActor in self?.receiveCloudChanges(reason: reason) }
            }
        }
        if iCloudEnabled { checkCloudSync() }
    }
    deinit { if let cloudObserver { NotificationCenter.default.removeObserver(cloudObserver) } }

    func reload() {
        configuration = APIConfiguration(baseURL: defaults.string(forKey: "apiBaseURL") ?? "", model: defaults.string(forKey: "model") ?? "")
        defaultCalendarID = defaults.string(forKey: "defaultCalendarID") ?? ""
        categoryRoutingEnabled = defaults.bool(forKey: "categoryRoutingEnabled")
        categoryCalendars = defaults.dictionary(forKey: "categoryCalendars") as? [String: String] ?? [:]
        iCloudEnabled = defaults.bool(forKey: "iCloudSettingsEnabled")
        restoreReferences(); restoreProfiles()
        restoreCalendarPreferences()
        restorePromptSettings()
        restoreSearchSettings()
    }
    var activeProfile: APIProfile? { profiles.first { $0.id == activeProfileID } }
    func profileKey(_ profile: APIProfile) throws -> String { try KeychainStore.readProfile(profile, synchronizable: iCloudEnabled) }
    func save(configuration: APIConfiguration, key: String) throws {
        try saveProfile(id: activeProfile?.id, name: activeProfile?.name ?? "默认接口", configuration: configuration, key: key)
    }
    /// A nil key means metadata-only editing; keep the existing Keychain association, even while locked.
    func saveProfile(id: String?, name: String, configuration: APIConfiguration, key: String?) throws {
        guard id != nil || profiles.count < 100 else { throw ShikeError.message("最多保存 100 个接口，请先删除不再使用的配置。") }
        try validateProfileConfiguration(configuration)
        let existing = profiles.first(where: { $0.id == id })
        guard id == nil || existing != nil else { throw ShikeError.message("此接口已被删除，请重新选择接口。") }
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        var profile = APIProfile(id: id ?? UUID().uuidString, name: name.isEmpty ? (existing?.name ?? availableProfileName("新接口")) : name,
                                 configuration: configuration, credentialID: existing?.credentialID,
                                 usesLegacyCredential: existing?.usesLegacyCredential ?? false)
        if let key {
            let cleanKey = key.trimmingCharacters(in: .whitespacesAndNewlines)
            let oldKey = try existing.map { try profileKey($0) } ?? ""
            if iCloudEnabled, cleanKey.isEmpty, existing?.credentialID != nil, oldKey.isEmpty {
                throw ShikeError.message("同步的 API Key 尚未到达，请稍后检查同步，或手动填写 Key。")
            }
            if cleanKey != oldKey {
                let credential = cleanKey.isEmpty ? nil : UUID().uuidString
                if let credential { try KeychainStore.saveProfileKey(cleanKey, id: credential, synchronizable: iCloudEnabled) }
                profile.credentialID = credential
                profile.usesLegacyCredential = false
            }
        }
        guard profile != existing || activeProfileID != profile.id else { return }
        storeProfile(profile)
    }
    func createBlankProfile() throws {
        guard profiles.count < 100 else { throw ShikeError.message("最多保存 100 个接口，请先删除不再使用的配置。") }
        storeProfile(APIProfile(name: availableProfileName("新接口"), configuration: APIConfiguration()))
    }
    func duplicateProfile(_ id: String) throws {
        guard profiles.count < 100 else { throw ShikeError.message("最多保存 100 个接口，请先删除不再使用的配置。") }
        guard let source = profiles.first(where: { $0.id == id }) else { throw ShikeError.message("原接口已不存在，请重新选择。") }
        let key = try profileKey(source)
        guard source.credentialID == nil || !key.isEmpty else {
            throw ShikeError.message("当前接口的 API Key 尚不可用，请等待钥匙串同步或补充 Key 后再复制。")
        }
        let credential = key.isEmpty ? nil : UUID().uuidString
        if let credential { try KeychainStore.saveProfileKey(key, id: credential, synchronizable: iCloudEnabled) }
        storeProfile(APIProfile(name: availableProfileName(source.name + " 副本"), configuration: source.configuration, credentialID: credential))
    }
    private func availableProfileName(_ base: String) -> String {
        let names = Set(profiles.map(\.name))
        var name = base; var suffix = 2
        while names.contains(name) { name = "\(base) \(suffix)"; suffix += 1 }
        return name
    }
    private func validateProfileConfiguration(_ configuration: APIConfiguration) throws {
        let url = configuration.baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        // Save partial forms too. Requests separately require the URL, model and key.
        if !url.isEmpty { _ = try configuration.endpoint() }
    }
    private func storeProfile(_ profile: APIProfile) {
        if let index = profiles.firstIndex(where: { $0.id == profile.id }) { profiles[index] = profile }
        else { profiles.append(profile) }
        activeProfileID = profile.id
        persistProfiles(); publishCloudSettings(); syncRevision = UUID()
    }
    func selectProfile(_ id: String) {
        guard profiles.contains(where: { $0.id == id }) else { return }
        activeProfileID = id; persistProfiles(); publishCloudSettings(); syncRevision = UUID()
    }
    func deleteProfile(_ id: String) {
        profiles.removeAll { $0.id == id }
        if activeProfileID == id { activeProfileID = profiles.first?.id ?? "" }
        persistProfiles(); publishCloudSettings(); syncRevision = UUID()
    }
    private func restoreProfiles() {
        if let data = defaults.data(forKey: "apiProfiles"), let saved = try? JSONDecoder().decode([APIProfile].self, from: data) {
            profiles = saved
            let active = defaults.string(forKey: "activeProfileID") ?? ""
            activeProfileID = profiles.contains(where: { $0.id == active }) ? active : profiles.first?.id ?? ""
            configuration = activeProfile?.configuration ?? APIConfiguration()
        } else if !configuration.baseURL.isEmpty || !configuration.model.isEmpty {
            // Migrate the old single configuration without reading a locked Keychain during launch.
            profiles = [APIProfile(id: "legacy-default", name: "默认接口", configuration: configuration,
                                   credentialID: defaults.string(forKey: "cloudCredentialID"), usesLegacyCredential: !iCloudEnabled)]
            activeProfileID = "legacy-default"; persistProfiles()
        }
    }
    private func persistProfiles() {
        defaults.set(try? JSONEncoder().encode(profiles), forKey: "apiProfiles")
        defaults.set(activeProfileID, forKey: "activeProfileID")
        configuration = activeProfile?.configuration ?? APIConfiguration()
        defaults.set(configuration.baseURL, forKey: "apiBaseURL")
        defaults.set(configuration.model, forKey: "model")
        defaults.set(activeProfile?.credentialID, forKey: "cloudCredentialID")
    }
    var exportPreferences: AppDataExport.PreferencesData {
        .init(iCloudEnabled: iCloudEnabled, categoryRoutingEnabled: categoryRoutingEnabled,
              defaultCalendar: defaultReference, categoryCalendars: categoryReferences,
              activeProfileID: activeProfileID, calendar: calendarPreferences, search: searchSettings.withoutCredentials)
    }
    func validateImport(_ backup: AppDataExport) throws {
        let ids = Set(profiles.map(\.id))
        guard profiles.count + backup.apiProfiles.filter({ !ids.contains($0.id) }).count <= 100 else {
            throw ShikeError.message("合并后的接口超过 100 个，请先整理接口，或关闭导入设置。")
        }
    }
    func importSettings(_ imported: AppDataImport) {
        let backup = imported.backup
        if let search = backup.preferences.search, searchSettings == SearchSettings() {
            searchSettings = search.withoutCredentials
            defaults.set(try? JSONEncoder().encode(searchSettings), forKey: "searchSettings")
        }
        // Keep existing endpoints and their Keychain associations together.
        let ids = Set(profiles.map(\.id))
        profiles += backup.apiProfiles.filter { !ids.contains($0.id) }.map {
            APIProfile(id: $0.id, name: $0.name, configuration: APIConfiguration(baseURL: $0.baseURL, model: $0.model, format: $0.format))
        }
        if profiles.contains(where: { $0.id == backup.preferences.activeProfileID }) { activeProfileID = backup.preferences.activeProfileID }
        persistProfiles()
        promptSettings = imported.prompts
        defaults.set(try? JSONEncoder().encode(promptSettings), forKey: "promptSettings")
        let source = backup.preferences.calendar
        var calendar = CalendarPreferences()
        calendar.visibleDays = source.visibleDays; calendar.visibleCalendars = source.visibleCalendars; calendar.planningCalendars = source.planningCalendars
        calendar.timeZoneIdentifier = source.timeZoneIdentifier; calendar.showCountdowns = source.showCountdowns; calendar.countdownLayout = source.countdownLayout
        calendarPreferences = calendar; defaults.set(try? JSONEncoder().encode(calendar), forKey: "calendarPreferences")
        defaultReference = backup.preferences.defaultCalendar; categoryReferences = backup.preferences.categoryCalendars
        defaultCalendarID = defaultReference?.matchingID(in: choices) ?? ""
        categoryCalendars = categoryReferences.compactMapValues { $0.matchingID(in: choices) }
        categoryRoutingEnabled = backup.preferences.categoryRoutingEnabled
        defaults.set(defaultCalendarID, forKey: "defaultCalendarID"); defaults.set(categoryCalendars, forKey: "categoryCalendars")
        defaults.set(categoryRoutingEnabled, forKey: "categoryRoutingEnabled"); persistReferences()
        publishCloudSettings(); syncRevision = UUID()
    }
    var exportCalendarReferences: [String: CalendarReference] { choices }

    func setDefaultCalendar(_ id: String) {
        defaultCalendarID = id; defaultReference = choices[id]
        defaults.set(id, forKey: "defaultCalendarID")
        persistReferences(); publishCloudSettings()
    }
    func setCategoryRouting(_ enabled: Bool) {
        categoryRoutingEnabled = enabled
        defaults.set(enabled, forKey: "categoryRoutingEnabled")
        publishCloudSettings()
    }
    func setCategoryCalendar(_ id: String, for category: EventCategory) {
        categoryCalendars[category.rawValue] = id.isEmpty ? nil : id
        categoryReferences[category.rawValue] = choices[id]
        defaults.set(categoryCalendars, forKey: "categoryCalendars")
        persistReferences(); publishCloudSettings()
    }
    func updateCalendars(_ calendars: [CalendarChoice]) {
        choices = Dictionary(uniqueKeysWithValues: calendars.map { ($0.id, CalendarReference(title: $0.title, account: $0.account)) })
        if defaultReference == nil { defaultReference = choices[defaultCalendarID] }
        for (category, id) in categoryCalendars where categoryReferences[category] == nil { categoryReferences[category] = choices[id] }
        // Keep this device's IDs when still valid, otherwise resolve the portable reference.
        if let reference = defaultReference, choices[defaultCalendarID] != reference {
            defaultCalendarID = reference.matchingID(in: choices) ?? "unavailable:\(reference.title)"
        }
        for (category, reference) in categoryReferences where choices[categoryCalendars[category] ?? ""] != reference {
            categoryCalendars[category] = reference.matchingID(in: choices) ?? "unavailable:\(reference.title)"
        }
        defaults.set(defaultCalendarID, forKey: "defaultCalendarID")
        defaults.set(categoryCalendars, forKey: "categoryCalendars")
        persistReferences()
    }
    func calendarID(for category: EventCategory?, calendars: CalendarService, suggestedID: String? = nil) -> String? {
        CalendarRouting.preferredID(category: category, enabled: categoryRoutingEnabled, mapping: categoryCalendars,
                                    defaultID: calendars.preferredCalendarID(defaultCalendarID),
                                    writableIDs: Set(calendars.calendars.map(\.id)), suggestedID: suggestedID)
    }

    func setCloudEnabled(_ enabled: Bool) throws {
        if enabled == iCloudEnabled { return }
        if enabled {
            guard let cloud, cloud.accountAvailable else { throw ShikeError.message("请先在系统设置登录 iCloud，并开启 iCloud Drive 与密码和钥匙串。") }
            guard cloud.synchronize() else { throw ShikeError.message("iCloud 暂不可用，请检查网络与应用的 iCloud 权限。") }
            if let remote = try cloudSnapshot() {
                if remote.searchSettings == nil { try migrateSearchKeys(toCloud: true) }
                iCloudEnabled = true; defaults.set(true, forKey: "iCloudSettingsEnabled")
                apply(remote)
                if remote.searchSettings == nil, searchSettings != SearchSettings() { publishCloudSettings() }
            } else {
                var migrated: [APIProfile] = []
                for var profile in profiles {
                    let key = try profileKey(profile)
                    if profile.credentialID != nil && key.isEmpty { throw ShikeError.message("接口 Key 暂不可用，请解锁设备后重试。") }
                    let id = UUID().uuidString
                    try KeychainStore.saveProfileKey(key, id: id, synchronizable: true)
                    profile.credentialID = key.isEmpty ? nil : id; profile.usesLegacyCredential = false
                    migrated.append(profile)
                }
                try migrateSearchKeys(toCloud: true)
                profiles = migrated; persistProfiles()
                iCloudEnabled = true; defaults.set(true, forKey: "iCloudSettingsEnabled")
                if profiles.isEmpty && configuration.baseURL.isEmpty && configuration.model.isEmpty &&
                    defaultCalendarID.isEmpty && categoryCalendars.isEmpty && !categoryRoutingEnabled &&
                    promptSettings.isDefault && calendarPreferences == CalendarPreferences() && searchSettings == SearchSettings() {
                    // An empty fresh install must not replace remote settings before
                    // the initial iCloud download has had a chance to arrive.
                    syncStatus = "等待 iCloud 设置到达，也可以先填写接口，内容会自动保存。"
                } else { publishCloudSettings() }
            }
        } else {
            try migrateSearchKeys(toCloud: false)
            for profile in profiles {
                if let id = profile.credentialID {
                    let key = try profileKey(profile)
                    guard !key.isEmpty else { throw ShikeError.message("API Key 尚未同步到本机，请等待到达后再关闭同步，或先填写 Key。") }
                    try KeychainStore.saveProfileKey(key, id: id, synchronizable: false)
                }
            }
            iCloudEnabled = false; defaults.set(false, forKey: "iCloudSettingsEnabled")
            syncStatus = "本设备已停止同步，当前设置保留在本机。"
        }
        syncRevision = UUID()
    }
    func checkCloudSync() {
        guard iCloudEnabled else { return }
        guard let cloud, cloud.accountAvailable else { syncStatus = "等待 iCloud 可用；设置已保留在本机。"; return }
        guard cloud.synchronize() else { syncStatus = "iCloud 同步暂不可用，请检查网络与权限。"; return }
        do {
            if let snapshot = try cloudSnapshot(), snapshot.revision.uuidString != defaults.string(forKey: "cloudRevision") {
                let localDate = defaults.object(forKey: "cloudUpdatedAt") as? Date ?? .distantPast
                if snapshot.updatedAt >= localDate { apply(snapshot) }
                else { publishCloudSettings() }
            } else { syncStatus = "已请求同步，iCloud 会在可用时传送设置。" }
            syncRevision = UUID()
        } catch { syncStatus = error.localizedDescription }
    }
    func receiveCloudChanges(reason: Int?) {
        guard iCloudEnabled else { return }
        if reason == NSUbiquitousKeyValueStoreQuotaViolationChange { syncStatus = "iCloud 设置空间不足，设置已保留在本机。"; return }
        if reason == NSUbiquitousKeyValueStoreAccountChange {
            // Pause on account changes; do not upload the previous account's settings.
            iCloudEnabled = false; defaults.set(false, forKey: "iCloudSettingsEnabled")
            // Clear any legacy local key, which may belong to a different endpoint.
            do { try KeychainStore.save("") }
            catch { syncStatus = "账户已变更，但本机钥匙串尚不可访问，请解锁后重试。"; return }
            syncStatus = "iCloud 账户已变更，请重新开启同步。"
            return
        }
        checkCloudSync()
    }
    func setPrompt(_ text: String, for purpose: PromptPurpose) throws {
        var value = promptSettings
        try value.set(text, for: purpose)
        promptSettings = value
        defaults.set(try JSONEncoder().encode(value), forKey: "promptSettings")
        publishCloudSettings()
    }
    private func restorePromptSettings() {
        promptSettings = defaults.data(forKey: "promptSettings").flatMap { data in
            guard let value = try? JSONDecoder().decode(PromptSettings.self, from: data),
                  (try? value.validate()) != nil else { return nil }
            return value
        } ?? PromptSettings()
    }
    func setCalendarPreferences(_ value: CalendarPreferences) {
        calendarPreferences = value
        defaults.set(try? JSONEncoder().encode(value), forKey: "calendarPreferences")
        publishCloudSettings()
    }
    private func restoreCalendarPreferences() {
        calendarPreferences = defaults.data(forKey: "calendarPreferences").flatMap { try? JSONDecoder().decode(CalendarPreferences.self, from: $0) } ?? CalendarPreferences()
    }

    private func cloudSnapshot() throws -> CloudSettingsSnapshot? {
        guard let data = cloud?.data(forKey: Self.cloudKey) else { return nil }
        guard data.count <= 500_000, let snapshot = try? JSONDecoder().decode(CloudSettingsSnapshot.self, from: data), [1, 2].contains(snapshot.version) else {
            throw ShikeError.message("iCloud 设置版本无法读取，本机设置已保留。")
        }
        try snapshot.promptSettings?.validate()
        try snapshot.searchSettings?.validate()
        if !snapshot.configuration.baseURL.isEmpty { _ = try snapshot.configuration.endpoint() }
        if let profiles = snapshot.profiles {
            guard profiles.count <= 100, Set(profiles.map(\.id)).count == profiles.count else { throw ShikeError.message("iCloud 接口列表无效，本机设置已保留。") }
            for profile in profiles { try validateProfileConfiguration(profile.configuration) }
        }
        return snapshot
    }
    private func publishCloudSettings() {
        guard iCloudEnabled, let cloud else { return }
        var snapshot = CloudSettingsSnapshot(configuration: configuration, credentialID: defaults.string(forKey: "cloudCredentialID"),
                                             defaultCalendar: defaultReference, categoryRoutingEnabled: categoryRoutingEnabled,
                                             categoryCalendars: categoryReferences, profiles: profiles, activeProfileID: activeProfileID)
        snapshot.calendarPreferences = calendarPreferences
        snapshot.promptSettings = promptSettings
        snapshot.searchSettings = searchSettings
        guard let data = try? JSONEncoder().encode(snapshot), data.count <= 500_000 else { syncStatus = "同步设置过大或编码失败，请减少接口配置。"; return }
        defaults.set(snapshot.revision.uuidString, forKey: "cloudRevision")
        defaults.set(snapshot.updatedAt, forKey: "cloudUpdatedAt")
        cloud.set(data, forKey: Self.cloudKey)
        syncStatus = cloud.accountAvailable ? "设置已保存，等待 iCloud 同步。" : "等待 iCloud 可用；设置已保留在本机。"
    }
    private func apply(_ snapshot: CloudSettingsSnapshot) {
        if let value = snapshot.searchSettings {
            searchSettings = value
            defaults.set(try? JSONEncoder().encode(value), forKey: "searchSettings")
        }
        if let value = snapshot.promptSettings {
            promptSettings = value
            defaults.set(try? JSONEncoder().encode(value), forKey: "promptSettings")
        }
        if let value = snapshot.calendarPreferences {
            calendarPreferences = value
            defaults.set(try? JSONEncoder().encode(value), forKey: "calendarPreferences")
        }
        configuration = snapshot.configuration
        defaults.set(configuration.baseURL, forKey: "apiBaseURL"); defaults.set(configuration.model, forKey: "model")
        defaults.set(snapshot.credentialID, forKey: "cloudCredentialID")
        profiles = snapshot.profiles ?? (snapshot.configuration.baseURL.isEmpty ? [] : [APIProfile(id: "legacy-default", name: "默认接口", configuration: snapshot.configuration, credentialID: snapshot.credentialID)])
        // Synced snapshots always reference synced credentials; never local legacy credentials.
        for index in profiles.indices { profiles[index].usesLegacyCredential = false }
        activeProfileID = snapshot.activeProfileID.flatMap { id in profiles.contains(where: { $0.id == id }) ? id : nil } ?? profiles.first?.id ?? ""
        persistProfiles()
        defaultReference = snapshot.defaultCalendar; categoryReferences = snapshot.categoryCalendars
        categoryRoutingEnabled = snapshot.categoryRoutingEnabled
        defaults.set(categoryRoutingEnabled, forKey: "categoryRoutingEnabled")
        defaultCalendarID = defaultReference.map { $0.matchingID(in: choices) ?? "unavailable:\($0.title)" } ?? ""
        categoryCalendars = categoryReferences.mapValues { $0.matchingID(in: choices) ?? "unavailable:\($0.title)" }
        defaults.set(defaultCalendarID, forKey: "defaultCalendarID"); defaults.set(categoryCalendars, forKey: "categoryCalendars")
        defaults.set(snapshot.revision.uuidString, forKey: "cloudRevision"); defaults.set(snapshot.updatedAt, forKey: "cloudUpdatedAt")
        persistReferences()
        syncStatus = "已接收 iCloud 设置；API Key 由钥匙串单独同步。"
        syncRevision = UUID()
    }
    private func persistReferences() {
        defaults.set(try? JSONEncoder().encode(defaultReference), forKey: "defaultCalendarReference")
        defaults.set(try? JSONEncoder().encode(categoryReferences), forKey: "categoryCalendarReferences")
    }
    private func restoreReferences() {
        defaultReference = defaults.data(forKey: "defaultCalendarReference").flatMap { try? JSONDecoder().decode(CalendarReference?.self, from: $0) } ?? nil
        categoryReferences = defaults.data(forKey: "categoryCalendarReferences").flatMap { try? JSONDecoder().decode([String: CalendarReference].self, from: $0) } ?? [:]
    }
}

extension Preferences {
    private var searchGrants: [String] { defaults.stringArray(forKey: "searchServiceGrants") ?? [] }
    var searchAuthorized: Bool { searchSettings.selected.authorizationScope.map(searchGrants.contains) == true }
    var searchReady: Bool {
        searchSettings.enabled && searchAuthorized && searchSettings.selected.credentialID != nil &&
            !defaults.bool(forKey: "searchConfigurationEditing") && (try? searchSettings.selected.endpoint()) != nil
    }
    var searchStatus: String {
        guard searchSettings.enabled else { return "关闭后仅使用模型已有知识安排。" }
        if defaults.bool(forKey: "searchConfigurationEditing") { return "待配置：填写完整后自动保存并启用。" }
        if searchSettings.selected.credentialID == nil { return "待配置：请填写搜索 API Key。" }
        if !searchAuthorized { return "在本机开启后才会向所选搜索服务发送搜索词。" }
        return "已开启 · 帮我安排将按需查询资料。"
    }
    func setSearchEnabled(_ enabled: Bool) {
        searchSettings.enabled = enabled
        if enabled { authorizeSearch(searchSettings.selected) }
        persistSearchSettings()
    }
    func selectSearchService(_ service: SearchService) {
        searchSettings.selectedService = service
        defaults.set(false, forKey: "searchConfigurationEditing")
        if searchSettings.enabled { authorizeSearch(searchSettings.selected) }
        persistSearchSettings()
    }
    func beginSearchEditing() {
        defaults.set(true, forKey: "searchConfigurationEditing")
        objectWillChange.send()
    }
    func discardSearchEditing() {
        defaults.set(false, forKey: "searchConfigurationEditing")
        objectWillChange.send()
    }
    func searchKey(for configuration: SearchConfiguration) throws -> String {
        guard let id = configuration.credentialID else { return "" }
        return try KeychainStore.searchKey(id: id, synchronizable: iCloudEnabled)
    }
    func saveSearchConfiguration(service: SearchService, key: String) throws {
        var value = SearchConfiguration(service: service)
        let cleanKey = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard cleanKey.count <= 16_384 else { throw ShikeError.message("搜索 API Key 过长。") }
        let old = searchSettings.configuration(for: service)
        let oldKey = try searchKey(for: old)
        if old.credentialID != nil && cleanKey.isEmpty && oldKey.isEmpty {
            throw ShikeError.message("搜索 API Key 尚未到达，请等待钥匙串同步或重新填写 Key。")
        }
        if cleanKey.isEmpty { value.credentialID = nil }
        else if cleanKey == oldKey { value.credentialID = old.credentialID }
        else {
            let id = UUID().uuidString
            try KeychainStore.saveSearchKey(cleanKey, id: id, synchronizable: iCloudEnabled)
            value.credentialID = id
        }
        searchSettings.set(value)
        defaults.set(cleanKey.isEmpty, forKey: "searchConfigurationEditing")
        if searchSettings.enabled { authorizeSearch(value) }
        persistSearchSettings()
    }
    func revokeSearchAuthorization() {
        defaults.removeObject(forKey: "searchServiceGrants")
        objectWillChange.send()
    }
    private func authorizeSearch(_ configuration: SearchConfiguration) {
        guard let scope = configuration.authorizationScope else { return }
        var grants = searchGrants
        if !grants.contains(scope) { grants.append(scope) }
        defaults.set(Array(grants.suffix(100)), forKey: "searchServiceGrants")
    }
    private func persistSearchSettings() {
        defaults.set(try? JSONEncoder().encode(searchSettings), forKey: "searchSettings")
        publishCloudSettings()
    }
    private func restoreSearchSettings() {
        if let data = defaults.data(forKey: "searchSettings"),
           let settings = try? JSONDecoder().decode(SearchSettings.self, from: data), (try? settings.validate()) != nil {
            searchSettings = settings
            defaults.set(try? JSONEncoder().encode(settings), forKey: "searchSettings")
        } else { searchSettings = SearchSettings() }
    }
    private func migrateSearchKeys(toCloud: Bool) throws {
        var settings = searchSettings
        for var configuration in settings.configurations {
            guard let oldID = configuration.credentialID else { continue }
            let key = try searchKey(for: configuration)
            guard !key.isEmpty else { throw ShikeError.message("搜索 API Key 尚未到达本机，请稍后再切换同步。") }
            let id = toCloud ? UUID().uuidString : oldID
            try KeychainStore.saveSearchKey(key, id: id, synchronizable: toCloud)
            configuration.credentialID = id; settings.set(configuration)
        }
        searchSettings = settings
        defaults.set(try? JSONEncoder().encode(settings), forKey: "searchSettings")
    }
}
