#if DEBUG
import UIKit
import UserNotifications
import ShikeCore

/// Explicit Debug-only verification with synthetic input; no user text or credentials enter the log.
@MainActor enum ModelBackgroundProbe {
    static var isRequested: Bool { ProcessInfo.processInfo.arguments.contains("-llm-background-probe") }
    static func run() async {
        let file = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appendingPathComponent("ModelBackgroundProbe.txt")
        try? Data().write(to: file, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        let started = Date()
        func log(_ value: String) {
            let line = String(format: "%.1f %@\n", Date().timeIntervalSince(started), value)
            guard let handle = try? FileHandle(forWritingTo: file) else { return }
            defer { try? handle.close() }
            _ = try? handle.seekToEnd(); try? handle.write(contentsOf: Data(line.utf8))
        }
        for _ in 0..<50 where UIApplication.shared.applicationState != .active { try? await Task.sleep(for: .milliseconds(200)) }
        let preferences = Preferences()
        guard let profile = preferences.activeProfile else { log("profile_unavailable"); return }
        let key: String
        do { key = try preferences.profileKey(profile) }
        catch { log("credential_unavailable"); return }
        guard !key.isEmpty else { log("credential_empty"); return }
        let notifications = UNUserNotificationCenter.current()
        let authorization = await notifications.notificationSettings().authorizationStatus
        if authorization == .notDetermined { _ = try? await notifications.requestAuthorization(options: [.alert, .sound]) }
        log("notification_authorization=\((await notifications.notificationSettings()).authorizationStatus.rawValue)")
        let center = ModelJobCenter.shared, id = UUID()
        center.executionObserver = { job, value in if job == id { log(value) } }
        defer { center.executionObserver = nil }
        let reference = Date.now
        log("probe_started state=\(UIApplication.shared.applicationState.rawValue)")
        var lastProgress = -10
        let task = center.start(id: id, kind: .connection, work: { context in
            // A short foreground hand-off, followed by real network work, never artificial progress.
            try await Task.sleep(for: .seconds(20))
            var count = 0
            for iteration in 1...1 {
                log("request_started iteration=\(iteration) state=\(UIApplication.shared.applicationState.rawValue) protected=\(UIApplication.shared.isProtectedDataAvailable)")
                let result = try await LLMClient().extract(text: "2026年12月15日下午2点到3点，在线测试会议。", referenceDate: reference,
                    timeZone: TimeZone(identifier: "Asia/Shanghai")!, configuration: profile.configuration, apiKey: key,
                    observer: context.observer { update in
                        Task { @MainActor in
                            switch update {
                            case .diagnostics(let diagnostics): log(diagnostics.text)
                            case .progress(let progress):
                                if Int(progress.elapsed) >= lastProgress + 10 {
                                    lastProgress = Int(progress.elapsed)
                                    log("progress stage=\(progress.stage.rawValue) bytes=\(progress.receivedBytes) state=\(UIApplication.shared.applicationState.rawValue) protected=\(UIApplication.shared.isProtectedDataAvailable)")
                                }
                            }
                        }
                    })
                count += result.count
                log("model_completed events=\(result.count) state=\(UIApplication.shared.applicationState.rawValue) protected=\(UIApplication.shared.isProtectedDataAvailable)")
            }
            return .connection("后台模型验证完成，共识别 \(count) 个测试日程。")
        }, completion: { result in
            switch result {
            case .success: log("completion_success")
            case .failure: log("completion_failed")
            }
        })
        await task.value
        log("persisted_status=\(center.record(id)?.status.rawValue ?? "missing") notification_requested=\(center.record(id)?.notified == true)")
        try? await Task.sleep(for: .seconds(3))
        let delivered = await notifications.deliveredNotifications()
        log("notification_delivered=\(delivered.contains { $0.request.identifier == "modeltask." + id.uuidString })")
        log("PROBE_COMPLETE")
    }
}
#endif
