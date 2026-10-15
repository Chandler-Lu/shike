import SwiftUI
import UserNotifications
import ShikeCore

enum ModelJobPresentation: Identifiable {
    case list
    case result(ModelJobRecord)
    var id: String {
        switch self {
        case .list: return "tasks"
        case .result(let record): return record.id.uuidString
        }
    }
}

/// Kept alive by the app delegate; both warm and cold notification taps route by durable task ID.
final class ModelJobNotificationDelegate: NSObject, UNUserNotificationCenterDelegate {
    static let shared = ModelJobNotificationDelegate()
    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
                                withCompletionHandler completionHandler: @escaping () -> Void) {
        let value = response.notification.request.content.userInfo["modelJobID"] as? String
        Task { @MainActor in
            if let value, let id = UUID(uuidString: value) { ModelJobCenter.shared.requestedID = id }
            completionHandler()
        }
    }
}

struct ModelJobListView: View {
    @ObservedObject var jobs: ModelJobCenter
    @ObservedObject var environment: AppEnvironment
    @ObservedObject var reminders: CountdownReminderService
    @Environment(\.dismiss) private var dismiss
    @State private var selected: ModelJobRecord?
    var body: some View {
        NavigationStack {
            List {
                if let error = jobs.storageError { Text(error).foregroundStyle(.red) }
                if jobs.records.isEmpty { Text("还没有模型任务。") }
                ForEach(jobs.records) { record in
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Text(record.kind.title).font(Notebook.handwriting(21))
                            Spacer()
                            if record.status == .running {
                                ProgressView()
                                Button("取消") { jobs.cancel(record.id) }.buttonStyle(.borderless)
                            } else if record.output != nil || record.inputText != nil || record.summaryContext != nil {
                                Button(record.output == nil ? "查看详情" : "查看结果") { open(record) }.buttonStyle(.borderless)
                            }
                        }
                        Text(record.status == .running ? jobs.progress[record.id] ?? "正在处理…" : record.output?.notice ?? record.error ?? "已结束")
                            .font(.subheadline).foregroundStyle(Notebook.secondaryInk)
                        Text(record.createdAt.formatted(date: .abbreviated, time: .shortened)).font(.caption).foregroundStyle(Notebook.secondaryInk)
                    }.padding(.vertical, 6)
                        .swipeActions { if record.status != .running { Button("删除", role: .destructive) { jobs.delete(record.id) } } }
                }
                Text("已完成的任务可左滑删除；日程草稿与已保存的日子不受影响。").font(.caption).foregroundStyle(Notebook.secondaryInk)
            }.scrollContentBackground(.hidden).background(PaperBackground())
                .navigationTitle("模型任务").navigationBarTitleDisplayMode(.inline)
                .toolbar { ToolbarItem(placement: .confirmationAction) { Button("完成") { dismiss() } } }
                .sheet(item: $selected) { record in
                    ModelJobResultView(record: record, environment: environment, reminders: reminders).workspaceSheet()
                }
                .onAppear { route() }
                .onChange(of: jobs.requestedID) { _, _ in route() }
        }.tint(Notebook.accent)
    }
    private func route() {
        guard let id = jobs.requestedID, let record = jobs.record(id), record.output != nil else { return }
        jobs.requestedID = nil; open(record)
    }
    private func open(_ record: ModelJobRecord) { selected = record; jobs.acknowledge(record.id) }
}

struct ModelJobResultView: View {
    let record: ModelJobRecord
    @ObservedObject var environment: AppEnvironment
    @ObservedObject var reminders: CountdownReminderService
    @Environment(\.dismiss) private var dismiss
    @State private var copied = false
    var body: some View {
        if record.kind == .summary {
            ModelSummaryResult(record: record, environment: environment)
        } else if record.kind == .countdowns {
            CountdownNaturalLanguageView(store: environment.countdowns, reminders: reminders, preferences: environment.preferences, restored: record) { dismiss() }
        } else { switch record.output {
        case .session(let session):
            ModelSessionResult(environment: environment, session: session)
        case .countdowns:
            CountdownNaturalLanguageView(store: environment.countdowns, reminders: reminders, preferences: environment.preferences, restored: record) { dismiss() }
        default:
            NavigationStack {
                ZStack { PaperBackground(); ScrollView {
                    VStack(alignment: .leading, spacing: 20) {
                        switch record.output {
                        case .models(let models):
                            Text("点按模型名称复制，可在接口设置中填写。").font(.subheadline)
                            ForEach(models) { model in
                                Button(model.id) { UIPasteboard.general.string = model.id; copied = true }.frame(minHeight: 44)
                            }
                        case .connection(let message): Text(message)
                        default: Text(record.error ?? "任务结果暂不可用。")
                        }
                        if copied { Text("已复制").font(.caption).foregroundStyle(Notebook.accent) }
                    }.padding(22).frame(maxWidth: 680).frame(maxWidth: .infinity)
                } }.navigationTitle(record.kind.title).navigationBarTitleDisplayMode(.inline)
                    .toolbar { ToolbarItem(placement: .confirmationAction) { Button("完成") { dismiss() } } }
            }.tint(Notebook.accent)
        } }
    }
}

private struct ModelSummaryResult: View {
    @StateObject private var controller: CalendarSummaryController
    @ObservedObject var environment: AppEnvironment
    init(record: ModelJobRecord, environment: AppEnvironment) {
        self.environment = environment
        _controller = StateObject(wrappedValue: CalendarSummaryController(jobs: environment.modelJobs, restored: record))
    }
    var body: some View {
        CalendarSummaryView(controller: controller, preferences: environment.preferences)
    }
}

private struct ModelSessionResult: View {
    @StateObject private var controller: ImportController
    @Environment(\.dismiss) private var dismiss
    init(environment: AppEnvironment, session: ImportSession) {
        let latest = (try? environment.store?.all())?.first { $0.id == session.id } ?? session
        _controller = StateObject(wrappedValue: ImportController(environment: environment, session: latest))
    }
    var body: some View {
        NavigationStack {
            ZStack { PaperBackground(); ScrollView {
                ImportFlowView(controller: controller, calendars: controller.environment.calendars)
                    .padding(22).frame(maxWidth: 680).frame(maxWidth: .infinity)
            } }.navigationTitle(controller.session.planning == nil ? "日程结果" : "安排结果").navigationBarTitleDisplayMode(.inline)
                .toolbar { ToolbarItem(placement: .confirmationAction) { Button("完成") { dismiss() } } }
                .onAppear { if controller.session.planning != nil { controller.showsPlanning = true } }
        }.tint(Notebook.accent)
    }
}
