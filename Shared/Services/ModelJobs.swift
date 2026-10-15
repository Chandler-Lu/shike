import Foundation
import SwiftUI
import ShikeCore
#if !SHARE_EXTENSION
import UIKit
import UserNotifications
#if !targetEnvironment(macCatalyst)
import BackgroundTasks
#endif
#endif

enum ModelJobKind: String, Codable {
    case extraction, planning, countdowns, summary, connection, models
    var title: String {
        switch self {
        case .extraction: return "提取日程"
        case .planning: return "帮我安排"
        case .countdowns: return "识别倒数日"
        case .summary: return "日历总结"
        case .connection: return "测试连接"
        case .models: return "获取模型"
        }
    }
}

enum ModelJobOutput: Codable {
    case session(ImportSession)
    case countdowns(text: String, reference: Date, drafts: [CountdownDraft])
    case summary(title: String, value: CalendarSummary)
    case connection(String)
    case models([APIModel])
    var notice: String {
        switch self {
        case .session(let value): return value.planning?.awaitingReply == false && value.drafts.isEmpty ? "问答已就绪，打开拾刻计划继续。" : "已整理 \(value.drafts.count) 个日程，请打开核对。"
        case .countdowns(_, _, let drafts): return "已识别 \(drafts.count) 个日子，请打开核对。"
        case .summary: return "总结已就绪，打开拾刻计划查看。"
        case .connection: return "连接测试已完成，打开拾刻计划查看。"
        case .models(let models): return "已获取 \(models.count) 个模型，打开拾刻计划查看。"
        }
    }
}

struct ModelJobRecord: Codable, Identifiable {
    enum Status: String, Codable { case running, completed, failed, cancelled, interrupted }
    let id: UUID
    let kind: ModelJobKind
    let createdAt: Date
    var status: Status = .running
    var output: ModelJobOutput?
    var inputText: String?
    var referenceDate: Date?
    var error: String?
    var notified = false
    var seen = false
    var sessionApplied = false
}

/// The task, execution allowance and durable result belong to the app, never a sheet's .task.
@MainActor final class ModelJobCenter: ObservableObject {
    static let shared = ModelJobCenter()
    @Published private(set) var records: [ModelJobRecord] = []
    @Published private(set) var progress: [UUID: String] = [:]
    @Published var requestedID: UUID?
    @Published private(set) var storageError: String?
    private var tasks: [UUID: Task<Void, Never>] = [:]
    private var leases: [UUID: ModelExecutionLease] = [:]
    private var interruptions: Set<UUID> = []
    private let directory: URL
    private let platformEnabled: Bool
    #if DEBUG
    var executionObserver: ((UUID, String) -> Void)?
    #endif
    var isBackground: () -> Bool
    var deliver: (ModelJobRecord) async -> Void

    init(directory: URL? = nil, platformEnabled: Bool = true,
         isBackground: (() -> Bool)? = nil, deliver: ((ModelJobRecord) async -> Void)? = nil) {
        self.platformEnabled = platformEnabled && !AppIdentity.isUITesting && ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] == nil
        self.directory = directory ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent((AppIdentity.isUITesting || ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil) ? "ModelJobsTests-" + UUID().uuidString : "ModelJobs", isDirectory: true)
        self.isBackground = isBackground ?? {
            #if !SHARE_EXTENSION
            // Locking and app switching pass through .inactive before .background.
            UIApplication.shared.applicationState != .active
            #else
            false
            #endif
        }
        self.deliver = deliver ?? { record in
            #if !SHARE_EXTENSION
            let center = UNUserNotificationCenter.current()
            let settings = await center.notificationSettings()
            guard [.authorized, .provisional, .ephemeral].contains(settings.authorizationStatus) else { return }
            let content = UNMutableNotificationContent()
            content.title = record.kind.title + "已完成"
            content.body = record.output?.notice ?? "打开拾刻计划查看结果。"
            content.sound = .default
            content.userInfo = ["modelJobID": record.id.uuidString]
            try? await center.add(UNNotificationRequest(identifier: "modeltask." + record.id.uuidString, content: content, trigger: nil))
            #endif
        }
        load()
    }

    @discardableResult func start(id: UUID = UUID(), kind: ModelJobKind, inputText: String? = nil, referenceDate: Date? = nil,
        work: @escaping @MainActor (ModelJobContext) async throws -> ModelJobOutput,
        completion: @escaping @MainActor (Result<ModelJobOutput, Error>) -> Void) -> Task<Void, Never> {
        var record = ModelJobRecord(id: id, kind: kind, createdAt: .now)
        record.inputText = inputText; record.referenceDate = referenceDate
        records.insert(record, at: 0)
        do { try write(record) }
        catch {
            storageError = "无法保存任务：" + error.localizedDescription
            records[0].status = .failed; records[0].error = storageError
            return Task { completion(.failure(error)) }
        }
        let context = ModelJobContext(id: id, center: self)
        let lease = ModelExecutionLease(id: id, title: kind.title, enabled: platformEnabled, event: { [weak self] value in
            #if DEBUG
            self?.executionObserver?(id, value)
            #endif
        }) { [weak self] in self?.interrupt(id) }
        leases[id] = lease
        lease.begin()
        #if !SHARE_EXTENSION
        if platformEnabled && !isBackground() {
            Task {
                let center = UNUserNotificationCenter.current()
                if await center.notificationSettings().authorizationStatus == .notDetermined {
                    _ = try? await center.requestAuthorization(options: [.alert, .sound])
                }
            }
        }
        #endif
        let task = Task { [self] in
            var result: Result<ModelJobOutput, Error>
            do {
                try Task.checkCancellation()
                let output = try await work(context)
                try Task.checkCancellation()
                result = .success(output)
            } catch { result = .failure(error) }
            if interruptions.contains(id) {
                result = .failure(ShikeError.message("系统已结束后台执行，输入已保留。请回到 App 后重试。"))
            } else if Task.isCancelled { result = .failure(CancellationError()) }
            guard let index = records.firstIndex(where: { $0.id == id }) else { return }
            var final = records[index]
            switch result {
            case .success(let output): final.status = .completed; final.output = output
            case .failure(let error):
                final.status = interruptions.contains(id) ? .interrupted : (error is CancellationError || Task.isCancelled ? .cancelled : .failed)
                final.error = final.status == .cancelled ? "已取消，输入已保留。" : error.localizedDescription
            }
            // Commit before publishing success or sending a notification. The journal remains readable while locked.
            do { try write(final) }
            catch {
                final.status = .failed; final.error = "结果保存失败：" + error.localizedDescription
                storageError = final.error; result = .failure(ShikeError.message(final.error!))
            }
            final.seen = !isBackground()
            try? write(final)
            records[index] = final
            completion(result)
            if final.status == .completed && isBackground() && !final.notified {
                final = self.record(id) ?? final
                final.notified = true
                do {
                    try write(final)
                    if let current = records.firstIndex(where: { $0.id == id }) { records[current] = final }
                    await deliver(final)
                } catch { storageError = "完成通知暂未发送：" + error.localizedDescription }
            }
            leases.removeValue(forKey: id)?.finish(success: final.status == .completed)
            tasks[id] = nil; progress[id] = nil; interruptions.remove(id)
        }
        tasks[id] = task
        return task
    }
    func cancel(_ id: UUID) { tasks[id]?.cancel() }
    func interrupt(_ id: UUID) { guard tasks[id] != nil else { return }; interruptions.insert(id); tasks[id]?.cancel() }
    func update(_ id: UUID, progress value: LLMProgress) {
        guard tasks[id] != nil else { return }
        progress[id] = value.message
        leases[id]?.update(value)
    }
    func record(_ id: UUID) -> ModelJobRecord? { records.first { $0.id == id } }
    func acknowledge(_ id: UUID) { change(id) { $0.seen = true } }
    func applySessions(to store: SessionStore?) {
        guard let store else { return }
        // Oldest first if more than one turn completed before persistence became available.
        for record in records.reversed() where record.status == .completed && !record.sessionApplied {
            guard case .session(let session) = record.output else { continue }
            do { try store.save(session); change(record.id) { $0.sessionApplied = true } }
            catch { storageError = "结果已保留，解锁后将继续保存草稿。" }
        }
    }
    func delete(_ id: UUID) {
        guard record(id)?.status != .running else { return }
        do {
            let file = directory.appendingPathComponent(id.uuidString + ".json")
            if FileManager.default.fileExists(atPath: file.path) { try FileManager.default.removeItem(at: file) }
            records.removeAll { $0.id == id }
        } catch { storageError = "任务记录删除失败：" + error.localizedDescription }
    }
    private func change(_ id: UUID, mutation: (inout ModelJobRecord) -> Void) {
        guard let index = records.firstIndex(where: { $0.id == id }) else { return }
        var value = records[index]; mutation(&value)
        do { try write(value); records[index] = value }
        catch { storageError = error.localizedDescription }
    }
    private func write(_ record: ModelJobRecord) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication])
        try JSONEncoder().encode(record).write(to: directory.appendingPathComponent(record.id.uuidString + ".json"), options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
    }
    private func load() {
        guard FileManager.default.fileExists(atPath: directory.path) else { return }
        do {
            let files = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil).filter { $0.pathExtension == "json" }
            records = files.compactMap { file in
                do { return try JSONDecoder().decode(ModelJobRecord.self, from: Data(contentsOf: file)) }
                catch { storageError = "部分任务记录无法读取，原文件已保留。"; return nil }
            }.sorted { $0.createdAt > $1.createdAt }
            for index in records.indices where records[index].status == .running {
                records[index].status = .interrupted
                records[index].error = "上次执行被系统中断，输入已保留。请重新发起请求。"
                try write(records[index])
            }
        } catch { storageError = "任务记录读取失败：" + error.localizedDescription }
    }
}

@MainActor final class ModelJobContext {
    let id: UUID
    private weak var center: ModelJobCenter?
    init(id: UUID, center: ModelJobCenter) { self.id = id; self.center = center }
    func observer(_ downstream: LLMObserver? = nil) -> LLMObserver {
        let id = id, center = center
        return { update in
            if case .progress(let value) = update { Task { @MainActor in center?.update(id, progress: value) } }
            downstream?(update)
        }
    }
}

/// Native execution allowance. Expiry is cancellation, never a fabricated network failure/retry.
@MainActor private final class ModelExecutionLease {
    let id: UUID
    let title: String
    let enabled: Bool
    let expired: () -> Void
    let event: (String) -> Void
    private var submission: Task<Void, Never>?
    private var finished = false
    private var lastReceivedBytes = 0
    private var totalReceivedBytes: Int64 = 0
    #if !SHARE_EXTENSION
    private var assertion: UIBackgroundTaskIdentifier = .invalid
    private var activity: NSObjectProtocol?
    #if !targetEnvironment(macCatalyst)
    private var continuedTask: BGTask?
    private var registered = false
    private var identifier: String { (Bundle.main.bundleIdentifier ?? "com.chandler.shike") + ".model." + id.uuidString }
    #endif
    #endif
    init(id: UUID, title: String, enabled: Bool, event: @escaping (String) -> Void, expired: @escaping () -> Void) {
        self.id = id; self.title = title; self.enabled = enabled; self.event = event; self.expired = expired
    }
    func begin() {
        guard enabled else { return }
        #if !SHARE_EXTENSION
        #if targetEnvironment(macCatalyst)
        activity = ProcessInfo.processInfo.beginActivity(options: [.userInitiated, .idleSystemSleepDisabled], reason: title)
        #else
        assertion = UIApplication.shared.beginBackgroundTask(withName: title) { [weak self] in
            Task { @MainActor in self?.event("finite_allowance_expired"); self?.expired(); self?.endAssertion() }
        }
        if #available(iOS 26.0, *) {
            registered = BGTaskScheduler.shared.register(forTaskWithIdentifier: identifier, using: .main) { [weak self] task in
                MainActor.assumeIsolated {
                    guard let self, !self.finished else { task.setTaskCompleted(success: false); return }
                    self.continuedTask = task
                    self.event("continued_processing_granted")
                    task.expirationHandler = { [weak self] in Task { @MainActor in self?.event("continued_processing_expired"); self?.expired() } }
                    self.endAssertion()
                }
            }
            guard registered else { event("registration_refused"); return }
            let request = BGContinuedProcessingTaskRequest(identifier: identifier, title: title, subtitle: "正在连接模型")
            request.strategy = .fail
            // If denied (including simulator), the finite assertion remains the only allowance.
            if #available(iOS 27.0, *) {
                submission = Task { [weak self] in
                    do { try await BGTaskScheduler.shared.submitTaskRequest(request) }
                    catch { self?.event("continued_processing_refused_\((error as NSError).code)") }
                    if self?.finished == true { BGTaskScheduler.shared.cancel(taskRequestWithIdentifier: request.identifier) }
                }
            } else {
                do { try BGTaskScheduler.shared.submit(request) }
                catch { event("continued_processing_refused_\((error as NSError).code)") }
            }
        }
        #endif
        #endif
    }
    func update(_ value: LLMProgress) {
        #if !SHARE_EXTENSION && !targetEnvironment(macCatalyst)
        if #available(iOS 26.0, *), let task = continuedTask as? BGContinuedProcessingTask {
            task.updateTitle(title, subtitle: value.message)
            // There is no known token total: report an indeterminate operation, not a fake percentage.
            let bytes = max(0, value.receivedBytes)
            totalReceivedBytes += Int64(bytes >= lastReceivedBytes ? bytes - lastReceivedBytes : bytes)
            lastReceivedBytes = bytes
            task.progress.totalUnitCount = -1
            task.progress.completedUnitCount = totalReceivedBytes
        }
        #endif
    }
    func finish(success: Bool) {
        guard !finished else { return }; finished = true
        #if !SHARE_EXTENSION
        if let activity { ProcessInfo.processInfo.endActivity(activity); self.activity = nil }
        #if !targetEnvironment(macCatalyst)
        if #available(iOS 26.0, *) {
            if let task = continuedTask as? BGContinuedProcessingTask {
                task.progress.totalUnitCount = 1; task.progress.completedUnitCount = success ? 1 : 0
            }
            continuedTask?.setTaskCompleted(success: success); continuedTask = nil
            if registered { BGTaskScheduler.shared.cancel(taskRequestWithIdentifier: identifier) }
        }
        #endif
        endAssertion()
        #endif
    }
    #if !SHARE_EXTENSION
    private func endAssertion() {
        if assertion != .invalid { UIApplication.shared.endBackgroundTask(assertion); assertion = .invalid }
    }
    #endif
}
