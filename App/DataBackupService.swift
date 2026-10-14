import Foundation
import Combine
import CryptoKit
import ShikeCore

actor AppBackupFiles {
    let directory: URL
    let deviceID: String
    let containerID: String
    init(directory: URL, deviceID: String, containerID: String) {
        self.directory = directory; self.deviceID = deviceID; self.containerID = containerID
    }
    func save(_ data: Data, reason: String, now: Date = .now) throws -> URL {
        guard data.count <= 50_000_000 else { throw ShikeError.message("数据超过 50 MB，未创建备份。") }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let stamp = Int64(now.timeIntervalSince1970 * 1000)
        let url = directory.appendingPathComponent("Shike_\(stamp)_\(reason)_\(UUID().uuidString.prefix(8)).json")
        try data.write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        try prune(directory)
        return url
    }
    func list() throws -> [URL] {
        guard FileManager.default.fileExists(atPath: directory.path) else { return [] }
        return try files(in: directory)
    }
    private func files(in folder: URL) throws -> [URL] {
        try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)
            .filter { $0.lastPathComponent.hasPrefix("Shike_") && $0.pathExtension == "json" }
            .sorted { $0.lastPathComponent > $1.lastPathComponent }
    }
    private func prune(_ folder: URL) throws {
        for url in try files(in: folder).dropFirst(30) { try FileManager.default.removeItem(at: url) }
    }
    func mirrorToCloud() throws {
        guard FileManager.default.ubiquityIdentityToken != nil,
              let root = FileManager.default.url(forUbiquityContainerIdentifier: containerID) else {
            throw ShikeError.message("iCloud Drive 暂不可用，本地备份已保留。")
        }
        let folder = root.appendingPathComponent("Documents/Backups/\(deviceID)", isDirectory: true)
        let coordinator = NSFileCoordinator()
        var coordinationError: NSError?, writeError: Error?
        coordinator.coordinate(writingItemAt: folder, options: .forMerging, error: &coordinationError) { destination in
            do {
                try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
                for source in try files(in: directory) {
                    let target = destination.appendingPathComponent(source.lastPathComponent)
                    if !FileManager.default.fileExists(atPath: target.path) {
                        try Data(contentsOf: source).write(to: target, options: .atomic)
                    }
                }
                try prune(destination)
            } catch { writeError = error }
        }
        if let error = coordinationError ?? writeError as NSError? { throw error }
    }
}

@MainActor final class DataBackupService: ObservableObject {
    @Published private(set) var busy = false
    @Published private(set) var status = "尚未备份"
    @Published private(set) var backups: [URL] = []
    @Published var automatic: Bool { didSet { defaults.set(automatic, forKey: "automaticDataBackup"); if automatic { schedule() } else { scheduled?.cancel() } } }
    @Published var cloudEnabled: Bool { didSet { defaults.set(cloudEnabled, forKey: "dataBackupToCloud"); if cloudEnabled { mirror() } } }
    private weak var environment: AppEnvironment?
    private let defaults: UserDefaults
    private let files: AppBackupFiles?
    private var subscriptions = Set<AnyCancellable>()
    private var scheduled: Task<Void, Never>?
    private var cloudTask: Task<Void, Never>?
    private var started = false
    init(environment: AppEnvironment) {
        self.environment = environment
        defaults = AppIdentity.isUITesting ? UserDefaults(suiteName: "Shike.UITests")! : .standard
        automatic = defaults.object(forKey: "automaticDataBackup") as? Bool ?? true
        cloudEnabled = defaults.object(forKey: "dataBackupToCloud") as? Bool ?? true
        let id = defaults.string(forKey: "backupDeviceID") ?? UUID().uuidString
        defaults.set(id, forKey: "backupDeviceID")
        let root = AppIdentity.isUITesting ? FileManager.default.temporaryDirectory.appendingPathComponent("UITestBackups-\(UUID())") : try? CountdownSnapshotStorage.directory()
        files = root.map { AppBackupFiles(directory: $0.appendingPathComponent("DataBackups", isDirectory: true), deviceID: id,
                                         containerID: Bundle.main.object(forInfoDictionaryKey: "ShikeCloudContainer") as? String ?? "iCloud.com.chandler.shike") }
        if let date = defaults.object(forKey: "lastDataBackup") as? Date { status = "本地备份 · " + date.formatted(date: .abbreviated, time: .shortened) }
    }
    func start() {
        guard !started, !AppIdentity.isUITesting else { return }; started = true
        environment?.countdowns.$revision.dropFirst().sink { [weak self] _ in self?.schedule() }.store(in: &subscriptions)
        environment?.preferences.objectWillChange.sink { [weak self] _ in self?.schedule() }.store(in: &subscriptions)
        NotificationCenter.default.publisher(for: .shikeSessionChanged).sink { [weak self] _ in self?.schedule() }.store(in: &subscriptions)
        NotificationCenter.default.publisher(for: .NSUbiquityIdentityDidChange).sink { [weak self] _ in
            Task { @MainActor in
                // A new Apple account must not silently receive the previous account's backups.
                self?.cloudEnabled = false; self?.status = "iCloud 账户已变化，请确认账户后重新开启云端备份。"
            }
        }.store(in: &subscriptions)
        schedule(); mirror()
    }
    func schedule(immediately: Bool = false) {
        guard automatic, !AppIdentity.isUITesting else { return }
        scheduled?.cancel()
        scheduled = Task { [weak self] in
            if !immediately { try? await Task.sleep(for: .seconds(10)) }
            guard !Task.isCancelled, let self else { return }
            do { _ = try await create(reason: "Auto", onlyIfChanged: true) }
            catch { status = "备份未完成：\(error.localizedDescription)" }
        }
    }
    @discardableResult func create(reason: String = "Manual", onlyIfChanged: Bool = false) async throws -> URL? {
        guard !busy else {
            if onlyIfChanged { return nil }
            throw ShikeError.message("正在备份，请稍后重试。")
        }
        guard let environment, let files else { throw ShikeError.message("备份目录不可用，请检查共享空间配置。") }
        let snapshot = try AppExportSnapshot.make(environment: environment)
        let data = try snapshot.data()
        var normalized = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        normalized.removeValue(forKey: "exportedAt")
        let hash = SHA256.hash(data: try JSONSerialization.data(withJSONObject: normalized, options: [.sortedKeys])).map { String(format: "%02x", $0) }.joined()
        if onlyIfChanged, defaults.string(forKey: "lastBackupContentHash") == hash,
           let latest = try await files.list().first {
            backups = try await files.list(); if cloudEnabled { mirror() }; return latest
        }
        busy = true; defer { busy = false }
        let url = try await files.save(data, reason: reason)
        defaults.set(hash, forKey: "lastBackupContentHash"); defaults.set(snapshot.exportedAt, forKey: "lastDataBackup")
        backups = try await files.list()
        status = "本地备份已保存 · " + snapshot.exportedAt.formatted(date: .abbreviated, time: .shortened)
        mirror(); return url
    }
    func refreshList() async {
        do { backups = try await files?.list() ?? [] }
        catch { status = "无法读取备份列表：\(error.localizedDescription)" }
    }
    private func mirror() {
        guard cloudEnabled, cloudTask == nil, !AppIdentity.isUITesting, let files else { return }
        cloudTask = Task { [weak self] in
            do {
                try await files.mirrorToCloud()
                if self?.cloudEnabled == true { self?.status = "本地备份已保留，iCloud Drive 等待系统上传。" }
            } catch {
                if self?.cloudEnabled == true { self?.status = "iCloud Drive 暂未备份，本地副本已保留。" }
            }
            self?.cloudTask = nil
        }
    }
    func restore(_ imported: AppDataImport, includeSettings: Bool) async throws -> String {
        guard let environment, let store = environment.store else { throw ShikeError.message("本地存储未就绪。") }
        if includeSettings { try environment.preferences.validateImport(imported.backup) }
        _ = try await create(reason: "BeforeImport")
        // No suspension during the merge, so cloud callbacks cannot interleave local commits.
        let previous = environment.countdowns.document
        let restored = imported.sessions(calendars: environment.preferences.exportCalendarReferences)
        let added: Int
        let sessions: Int
        do {
            added = try environment.countdowns.importBackup(imported.backup, notify: false)
            sessions = try store.importMissing(restored)
        } catch {
            do { try environment.countdowns.rollbackImport(to: previous) }
            catch { throw ShikeError.message("导入未完成，本地回退失败；请从导入前备份恢复。") }
            throw error
        }
        if includeSettings { environment.preferences.importSettings(imported) }
        environment.countdowns.finishImport()
        schedule()
        return "已导入 \(added) 个日子、\(sessions) 条记录；重复编号保留本机内容。"
    }
}
