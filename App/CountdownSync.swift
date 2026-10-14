import CloudKit
import Combine
import UIKit
import ShikeCore

@MainActor enum CountdownBackgroundSync { static weak var current: CountdownSync? }

@MainActor final class CountdownSync: ObservableObject, CKSyncEngineDelegate {
    @Published private(set) var status = "尚未开启倒数日同步"
    @Published private(set) var diagnostic: String?
    private let store: CountdownStore
    private let preferences: Preferences
    private var subscription: AnyCancellable?
    private var engine: CKSyncEngine?
    private var operation: Task<Void, Never>?
    private var generation = UUID()
    private var cycleError: String?
    private var suspended = false
    private var requiresManualRetry = false
    private var retryNotBefore: Date?
    private let zoneID = CKRecordZone.ID(zoneName: "ShikeCountdowns")
    private var container: CKContainer { CKContainer(identifier: Bundle.main.object(forInfoDictionaryKey: "ShikeCloudContainer") as? String ?? "iCloud.com.chandler.shike") }
    init(store: CountdownStore, preferences: Preferences) {
        self.store = store; self.preferences = preferences
        subscription = preferences.$iCloudEnabled.removeDuplicates().sink { [weak self] enabled in
            // @Published delivers before the property changes.
            Task { @MainActor [weak self] in self?.setEnabled(enabled) }
        }
    }
    private func setEnabled(_ enabled: Bool) {
        suspended = false
        requiresManualRetry = false; retryNotBefore = nil; diagnostic = nil
        generation = UUID(); operation?.cancel(); operation = nil
        let previous = engine; engine = nil
        if let previous { Task { await previous.cancelOperations() } }
        if enabled { refresh() } else { status = "倒数日保留在本机，同步已关闭" }
    }
    func refresh(userInitiated: Bool = false) {
        #if DEBUG
        if CloudKitReadOnlyProbe.isRequested { return }
        #endif
        if userInitiated { requiresManualRetry = false }
        guard preferences.iCloudEnabled, !AppIdentity.isUITesting, !suspended, !requiresManualRetry,
              retryNotBefore.map({ $0 <= .now }) ?? true, operation == nil else { return }
        cycleError = nil
        let token = generation
        operation = Task { [weak self] in
            guard let self else { return }
            defer { if token == generation { operation = nil } }
            var step = "检查 iCloud 账户"
            do {
                guard try await container.accountStatus() == .available else { throw ShikeError.message("请先在系统设置登录 iCloud。倒数日已保存在本机。") }
                step = "验证同步账户"
                let account = try await container.userRecordID().recordName
                try Task.checkCancellation()
                guard token == generation, preferences.iCloudEnabled else { return }
                try store.bindAccount(account)
                if engine == nil {
                    step = "检查倒数日云端空间"
                    do { _ = try await container.privateCloudDatabase.recordZone(for: zoneID) }
                    catch let error as CKError where error.code == .zoneNotFound || error.code == .unknownItem {
                        step = "创建倒数日云端空间"
                        _ = try await container.privateCloudDatabase.save(CKRecordZone(zoneID: zoneID))
                    }
                    try Task.checkCancellation()
                    guard token == generation, preferences.iCloudEnabled else { return }
                    let saved = try store.document.engineState.map { try JSONDecoder().decode(CKSyncEngine.State.Serialization.self, from: $0) }
                    var config = CKSyncEngine.Configuration(database: container.privateCloudDatabase, stateSerialization: saved, delegate: self)
                    // Explicit cycles guarantee account verification before every send.
                    config.automaticallySync = false
                    // CKSyncEngine owns creation/discovery of this database subscription.
                    // Do not make a second standalone subscription save a prerequisite.
                    config.subscriptionID = "shike-countdowns-v1"
                    engine = CKSyncEngine(config)
                    UIApplication.shared.registerForRemoteNotifications()
                }
                guard let engine else { return }
                status = "正在同步倒数日…"
                // Fetch before enqueueing local writes; records are merged, never replaced wholesale.
                step = "下载倒数日与同步订阅"
                try await engine.fetchChanges(.init(scope: .zoneIDs([zoneID])))
                try Task.checkCancellation()
                guard token == generation, self.engine === engine else { return }
                guard cycleError == nil else { return }
                enqueue(engine)
                step = "上传倒数日"
                try await engine.sendChanges(.init(scope: .zoneIDs([zoneID])))
                guard token == generation else { return }
                status = cycleError ?? (store.document.pending.isEmpty ? "倒数日已同步" : "倒数日已保存，等待下一次同步")
                #if DEBUG
                if ProcessInfo.processInfo.arguments.contains("-cloudkit-diagnose-sync") {
                    print("[CloudKitSync] completed status=\(status) pending=\(store.document.pending.count)")
                    if cycleError == nil && store.document.pending.isEmpty {
                        let snapshot = store.records
                        var matched = 0
                        for start in stride(from: 0, to: snapshot.count, by: 100) {
                            let chunk = Array(snapshot[start..<min(start + 100, snapshot.count)])
                            let results = try await container.privateCloudDatabase.records(for: chunk.map { CKRecord.ID(recordName: $0.id.uuidString, zoneID: zoneID) })
                            for value in chunk {
                                let id = CKRecord.ID(recordName: value.id.uuidString, zoneID: zoneID)
                                if let record = try results[id]?.get(), try payload(record) == value { matched += 1 }
                            }
                        }
                        print("[CloudKitSync] serverReadback matched=\(matched) local=\(snapshot.count) allEqual=\(matched == snapshot.count)")
                    }
                }
                #endif
                if cycleError == nil { diagnostic = nil; retryNotBefore = nil }
            } catch is CancellationError { }
            catch {
                guard token == generation else { return }
                report(error, operation: step)
            }
        }
    }
    private func report(_ error: Error, operation: String) {
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("-cloudkit-diagnose-sync") {
            print("[CloudKitSync] failed step=\(operation)")
            print(CloudSyncFailure(error, operation: operation, container: container.containerIdentifier ?? "未配置").diagnostic)
        }
        #endif
        let failure = CloudSyncFailure(error, operation: operation, container: container.containerIdentifier ?? "未配置")
        cycleError = failure.message; status = failure.message; diagnostic = failure.diagnostic
        requiresManualRetry = !failure.automaticRetryAllowed
        if let delay = failure.retryAfter { retryNotBefore = .now.addingTimeInterval(max(0, delay)) }
    }
    func synchronizeNow() async {
        refresh()
        await operation?.value
    }
    private func enqueue(_ engine: CKSyncEngine) {
        engine.state.add(pendingRecordZoneChanges: store.document.pending.map { .saveRecord(CKRecord.ID(recordName: $0.uuidString, zoneID: zoneID)) })
    }
    func handleEvent(_ event: CKSyncEngine.Event, syncEngine: CKSyncEngine) async {
        guard engine === syncEngine, preferences.iCloudEnabled else { return }
        do {
            switch event {
            case .stateUpdate(let event): try store.saveEngineState(JSONEncoder().encode(event.stateSerialization))
            case .accountChange(let event):
                switch event.changeType {
                case .signIn(let user):
                    do { try store.bindAccount(user.recordName) }
                    catch {
                        generation = UUID(); operation?.cancel(); operation = nil; engine = nil; suspended = true
                        Task { await syncEngine.cancelOperations() }
                        throw error
                    }
                case .signOut, .switchAccounts:
                    generation = UUID(); operation?.cancel(); operation = nil; engine = nil; suspended = true
                    status = "Apple 账户已改变，倒数日同步已暂停，本地数据已保留。"
                    Task { await syncEngine.cancelOperations() }
                @unknown default: break
                }
            case .fetchedRecordZoneChanges(let event):
                for modification in event.modifications { try accept(modification.record) }
                // All app deletions are tombstones. A physical server deletion is treated
                // as a tombstone too, so an offline copy cannot recreate the deleted item.
                for deleted in event.deletions {
                    if let id = UUID(uuidString: deleted.recordID.recordName) { try store.delete(id) }
                }
            case .sentRecordZoneChanges(let event):
                for record in event.savedRecords { try store.acknowledge(payload(record), fields: systemFields(record)) }
                for failure in event.failedRecordSaves {
                    switch failure.error.code {
                    case .serverRecordChanged:
                        if let server = failure.error.serverRecord { try accept(server) }
                        enqueue(syncEngine)
                    case .zoneNotFound, .unknownItem:
                        try store.resetCloudZone()
                        syncEngine.state.add(pendingDatabaseChanges: [.saveZone(CKRecordZone(zoneID: zoneID))])
                        enqueue(syncEngine)
                    default: report(failure.error, operation: "上传倒数日记录")
                    }
                }
                // An edit may arrive while an earlier revision is in flight.
                enqueue(syncEngine)
            case .fetchedDatabaseChanges(let event):
                if event.deletions.contains(where: { $0.zoneID == zoneID }) {
                    // Server zone deletion must not silently resurrect a whole library.
                    generation = UUID(); operation?.cancel(); operation = nil; engine = nil; suspended = true
                    status = "云端倒数日空间已删除。本地数据已保留，请关闭再开启同步以重新上传。"
                    try store.resetCloudZone()
                    Task { await syncEngine.cancelOperations() }
                }
            case .didFetchRecordZoneChanges(let event):
                if let error = event.error, error.code != .zoneNotFound { report(error, operation: "下载倒数日记录") }
            case .sentDatabaseChanges(let event):
                if let failed = event.failedZoneSaves.first { report(failed.error, operation: "保存倒数日云端空间") }
            default: break
            }
        } catch { report(error, operation: "合并同步记录") }
    }
    func nextRecordZoneChangeBatch(_ context: CKSyncEngine.SendChangesContext, syncEngine: CKSyncEngine) async -> CKSyncEngine.RecordZoneChangeBatch? {
        guard engine === syncEngine, preferences.iCloudEnabled else { return nil }
        do {
            let records = try store.records.filter { store.document.pending.contains($0.id) }.prefix(100).compactMap { value -> CKRecord? in
                let id = CKRecord.ID(recordName: value.id.uuidString, zoneID: zoneID)
                guard context.options.scope.contains(id) else { return nil }
                let record: CKRecord
                if let data = store.document.serverFields[value.id.uuidString] {
                    let coder = try NSKeyedUnarchiver(forReadingFrom: data); coder.requiresSecureCoding = true
                    defer { coder.finishDecoding() }
                    guard let restored = CKRecord(coder: coder) else { throw ShikeError.message("无法读取云端记录版本。") }
                    record = restored
                } else { record = CKRecord(recordType: "ShikeCountdownRecord", recordID: id) }
                record["payload"] = try JSONEncoder().encode(value) as CKRecordValue
                return record
            }
            return records.isEmpty ? nil : CKSyncEngine.RecordZoneChangeBatch(recordsToSave: records)
        } catch { report(error, operation: "准备待同步记录"); return nil }
    }
    private func payload(_ record: CKRecord) throws -> CountdownRecord {
        guard record.recordType == "ShikeCountdownRecord", let data = record["payload"] as? Data, data.count <= 200_000 else { throw ShikeError.message("云端倒数日格式无法读取，未覆盖本地数据。") }
        let value = try JSONDecoder().decode(CountdownRecord.self, from: data)
        guard value.id.uuidString == record.recordID.recordName else { throw ShikeError.message("云端倒数日标识无效。") }
        try value.validate(); return value
    }
    private func systemFields(_ record: CKRecord) -> Data {
        let coder = NSKeyedArchiver(requiringSecureCoding: true); record.encodeSystemFields(with: coder); coder.finishEncoding(); return coder.encodedData
    }
    private func accept(_ record: CKRecord) throws {
        let value = try payload(record)
        try store.merge([value], fields: [value.id.uuidString: systemFields(record)])
    }
}
