import SwiftUI
import UIKit
import ShikeCore

@main struct ShikeApp: App {
    @UIApplicationDelegateAdaptor(QuickActionAppDelegate.self) private var appDelegate
    @StateObject private var workspace = Workspace()
    @StateObject private var environment: AppEnvironment
    init() {
        AppIdentity.configureDebugLaunch()
        StoreCaptureStyle.configureBars()
        #if DEBUG
        if AppIdentity.isUITesting {
            UserDefaults(suiteName: "Shike.UITests")?.removePersistentDomain(forName: "Shike.UITests")
            if ProcessInfo.processInfo.arguments.contains("-paste-fixture") {
                UIPasteboard.general.string = "明天下午两点开会，三楼会议室。"
            }
            if ProcessInfo.processInfo.arguments.contains("-shortcut-fixture") {
                try? ShortcutInbox.shared.enqueue(text: "明天下午两点到三点半产品设计评审，三楼会议室。", source: "捷径文字")
            }
        }
        #endif
        let environment = AppEnvironment()
        #if DEBUG
        if AppIdentity.isUITesting && ProcessInfo.processInfo.arguments.contains("-history-fixture") {
            for title in ["保留记录", "阅读记录", "旅行记录"] {
                var record = ImportSession(); record.text = title
                try? environment.store?.save(record)
            }
        }
        #endif
        _environment = StateObject(wrappedValue: environment)
        #if DEBUG
        if CloudKitReadOnlyProbe.isRequested { Task { await CloudKitReadOnlyProbe.run() } }
        if LLMReadOnlyProbe.isRequested { Task { await LLMReadOnlyProbe.run() } }
        if ModelBackgroundProbe.isRequested { Task { await ModelBackgroundProbe.run() } }
        #endif
    }
    var body: some Scene {
        WindowGroup {
            if let error = environment.startupError {
                ZStack {
                    PaperBackground()
                    VStack(spacing: 24) {
                        CalendarDoodle()
                        MarginTitle(title: "还差一点准备", subtitle: "共享存储尚未就绪")
                        NoteMessage(text: error, isError: true)
                    }.padding(28)
                }
            } else { RootView(environment: environment).environmentObject(workspace).storeCaptureAppearance().task { ShikeShortcuts.updateAppShortcutParameters() } }
        }.commands { WorkspaceCommands(workspace: workspace) }
    }
}

#if DEBUG
/// Explicit launch-only diagnostic. Sends fixed synthetic events, never saved user content.
@MainActor private enum LLMReadOnlyProbe {
    static var isRequested: Bool { ProcessInfo.processInfo.arguments.contains("-llm-probe") }
    private static func argument(_ name: String, fallback: String) -> String {
        let args = ProcessInfo.processInfo.arguments
        guard let index = args.firstIndex(of: name), args.indices.contains(index + 1) else { return fallback }
        return args[index + 1]
    }
    static func run() async {
        let wasIdleDisabled = UIApplication.shared.isIdleTimerDisabled
        UIApplication.shared.isIdleTimerDisabled = true
        defer { UIApplication.shared.isIdleTimerDisabled = wasIdleDisabled }
        let mode = argument("-llm-probe-mode", fallback: "stream")
        let index = Int(argument("-llm-probe-profile", fallback: "0")) ?? 0
        let repeats = min(3, max(1, Int(argument("-llm-probe-repeat", fallback: "1")) ?? 1))
        let defaults = UserDefaults(suiteName: AppIdentity.appGroup)
        guard let data = defaults?.data(forKey: "apiProfiles"),
              let profiles = try? JSONDecoder().decode([APIProfile].self, from: data), profiles.indices.contains(index) else {
            print("LLM_PROBE unavailable: no configured profile"); return
        }
        let profile = profiles[index]
        let file = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("LLMProbe-\(mode)-\(index).txt")
        let sink = LLMProbeSink(file: file)
        do {
            try Data().write(to: file)
            sink.line("probe_started=true")
            let key = try KeychainStore.readProfile(profile, synchronizable: defaults?.bool(forKey: "iCloudSettingsEnabled") == true)
            guard !key.isEmpty else { sink.line("credential_unavailable=true\nLLM_PROBE_COMPLETE"); return }
            let reference = ISO8601DateFormatter().date(from: "2026-10-15T10:00:00+08:00")!
            let samples = ["2026年12月15日下午2点到3点，在线测试会议。",
                           "2026年12月15日上午9点到10点在三楼开项目会，下午2点到3点在线讨论设计，晚上7点到8点在公园跑步。"]
            let client = LLMClient(policy: mode == "legacy" ? .legacyComparison : .init())
            for repetition in 1...repeats {
                for (sample, text) in samples.enumerated() {
                    sink.line("mode=\(mode) repetition=\(repetition) sample=\(sample + 1)")
                    do {
                        let events = try await client.extract(text: text, referenceDate: reference, timeZone: TimeZone(identifier: "Asia/Shanghai")!,
                            configuration: profile.configuration, apiKey: key, observer: { update in
                                if case .diagnostics(let report) = update { sink.line(report.text) }
                            })
                        sink.line("events=\(events.count)")
                    } catch { sink.line("request_failed=true") }
                }
            }
            sink.line("LLM_PROBE_COMPLETE")
        } catch {
            let description = error.localizedDescription
            if let range = description.range(of: #"（-?[0-9]+）"#, options: .regularExpression) {
                sink.line("credential_status=" + description[range])
            }
            sink.line("credential_or_file_error=true\nLLM_PROBE_COMPLETE")
        }
    }
}
private final class LLMProbeSink: @unchecked Sendable {
    let file: URL
    private let lock = NSLock()
    init(file: URL) { self.file = file }
    func line(_ value: String) {
        lock.lock(); defer { lock.unlock() }
        print("LLM_PROBE " + value)
        guard let handle = try? FileHandle(forWritingTo: file) else { return }
        defer { try? handle.close() }
        _ = try? handle.seekToEnd(); try? handle.write(contentsOf: Data((value + "\n").utf8))
    }
}
#endif
