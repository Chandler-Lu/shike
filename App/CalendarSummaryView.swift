import SwiftUI
import ShikeCore

struct CalendarSummaryRequest: Identifiable {
    let id = UUID()
    let title: String
    let input: CalendarSummaryInput
}

/// The original snapshot and every answer survive dismissal, background work and reopening a task.
@MainActor final class CalendarSummaryController: ObservableObject {
    @Published private(set) var context: CalendarSummaryContext?
    @Published private(set) var error: String?
    @Published private(set) var recipient = ""
    @Published private(set) var progressMessage = "正在整理这些安排…"
    @Published private(set) var needsPresentation = false
    @Published private(set) var running = false
    @Published private(set) var pendingQuestion: String?
    private(set) var jobID: UUID?
    private let jobs: ModelJobCenter
    private var visible = false
    var summary: CalendarSummary? { context?.exchanges.last?.answer }
    var shouldPresentResult: Bool {
        needsPresentation && (summary == nil || jobID.flatMap(jobs.record)?.seen != true)
    }

    init(jobs: ModelJobCenter? = nil, restored: ModelJobRecord? = nil) {
        self.jobs = jobs ?? .shared
        guard let restored else { return }
        jobID = restored.id
        context = restored.summaryContext
        if case .summary(let title, let value) = restored.output {
            if context == nil { context = CalendarSummaryContext(title: title, input: nil) }
            context?.exchanges.append(.init(question: restored.inputText, answer: value))
        } else {
            pendingQuestion = restored.inputText
            error = restored.error
        }
    }

    func setVisible(_ value: Bool) {
        visible = value
        if value && !running && !jobs.isBackground() && (summary != nil || error != nil) {
            needsPresentation = false
            if let jobID { jobs.acknowledge(jobID) }
        }
    }
    func cancel() { if let jobID { jobs.cancel(jobID) } }

    func generate(_ request: CalendarSummaryRequest, preferences: Preferences) {
        guard !running else { return }
        context = CalendarSummaryContext(title: request.title, input: request.input)
        pendingQuestion = nil
        perform(question: nil, preferences: preferences)
    }
    func followUp(_ question: String, preferences: Preferences) {
        guard !running, summary != nil else { return }
        let clean = question.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty else { return }
        perform(question: clean, preferences: preferences)
    }
    func retry(preferences: Preferences) {
        guard !running else { return }
        perform(question: pendingQuestion, preferences: preferences)
    }
    private func perform(question: String?, preferences: Preferences) {
        guard let snapshot = context else { return }
        pendingQuestion = question; error = nil
        do {
            if let question { _ = try snapshot.encoded(question: question) }
            #if DEBUG
            if AppIdentity.isUITesting {
                execute(context: snapshot, question: question) { _ in
                    if ProcessInfo.processInfo.arguments.contains("-summary-delay-fixture") {
                        try await Task.sleep(for: .seconds(ProcessInfo.processInfo.arguments.contains("-summary-routing-fixture") ? 20 : 10))
                    }
                    if let question {
                        return CalendarSummary(overview: "关于“\(question)”：可以在相邻安排之间预留 15 分钟。", agenda: [], attention: [], suggestions: ["建议根据原日程安排休息。"])
                    }
                    return CalendarSummary(overview: "这段时间有 \(snapshot.input?.events.count ?? 0) 个安排。", agenda: snapshot.input?.events.map(\.title) ?? [], attention: [], suggestions: ["为相邻安排留出缓冲时间。"])
                }
                return
            }
            #endif
            let profile = preferences.activeProfile
            let configuration = profile?.configuration ?? preferences.configuration
            recipient = URL(string: configuration.baseURL)?.host ?? ""
            let key = try profile.map { try preferences.profileKey($0) } ?? ""
            execute(context: snapshot, question: question) { [self] job in
                let observer = job.observer { update in
                    guard case .progress(let progress) = update else { return }
                    Task { @MainActor [weak self] in
                        guard self?.jobID == job.id, self?.running == true else { return }
                        self?.progressMessage = progress.message
                    }
                }
                if let question {
                    return try await LLMClient().followUpCalendarSummary(snapshot, question: question, configuration: configuration, apiKey: key, observer: observer)
                }
                guard let input = snapshot.input else { throw ShikeError.message("原始日程快照不可用，请在日历页重新总结。") }
                return try await LLMClient().summarizeCalendar(input, configuration: configuration, apiKey: key, observer: observer)
            }
        } catch {
            self.error = error.localizedDescription
            needsPresentation = !visible || jobs.isBackground()
        }
    }

    @discardableResult func run(_ request: CalendarSummaryRequest,
        work: @escaping @MainActor (ModelJobContext) async throws -> CalendarSummary) -> Task<Void, Never> {
        execute(context: CalendarSummaryContext(title: request.title, input: request.input), question: nil, work: work)
    }
    @discardableResult func execute(context snapshot: CalendarSummaryContext, question: String?,
        work: @escaping @MainActor (ModelJobContext) async throws -> CalendarSummary) -> Task<Void, Never> {
        let token = UUID(); jobID = token
        context = snapshot; pendingQuestion = question; error = nil; needsPresentation = false; running = true
        progressMessage = question == nil ? "正在整理这些安排…" : "正在结合日程回答…"
        return jobs.start(id: token, kind: .summary, inputText: question, summaryContext: snapshot, work: { job in
            .summary(title: snapshot.title, value: try await work(job))
        }, completion: { [self] result in
            guard jobID == token else { return }
            running = false
            switch result {
            case .success(.summary(_, let value)):
                context?.exchanges.append(.init(question: question, answer: value)); pendingQuestion = nil
                needsPresentation = !visible || jobs.isBackground()
                if !needsPresentation { jobs.acknowledge(token) }
            case .failure(let failure):
                error = failure is CancellationError ? "已取消，之前的总结和追问仍保留。" : failure.localizedDescription
                needsPresentation = !(failure is CancellationError) && (!visible || jobs.isBackground())
            default: break
            }
        })
    }
}

struct CalendarSummaryView: View {
    @ObservedObject var controller: CalendarSummaryController
    @ObservedObject var preferences: Preferences
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    @State private var copied: String?
    @State private var question = ""
    @State private var detent: PresentationDetent = .medium
    @FocusState private var questionFocused: Bool
    var body: some View {
        NavigationStack {
            ZStack {
                PaperBackground()
                ScrollView {
                    VStack(alignment: .leading, spacing: 22) {
                        header
                        if let context = controller.context, context.exchanges.count > 1 {
                            DisclosureGroup("此前的总结与追问（\(context.exchanges.count - 1)）") {
                                VStack(alignment: .leading, spacing: 20) {
                                    ForEach(Array(context.exchanges.dropLast().enumerated()), id: \.offset) { _, exchange in
                                        VStack(alignment: .leading, spacing: 10) {
                                            Text(exchange.question ?? "最初的总结").font(.subheadline.weight(.semibold))
                                            Text(exchange.answer.text(title: "", markdown: false).trimmingCharacters(in: .whitespacesAndNewlines))
                                                .font(.subheadline).textSelection(.enabled)
                                        }.frame(maxWidth: .infinity, alignment: .leading)
                                    }
                                }.padding(.top, 12)
                            }.font(.subheadline).accessibilityIdentifier("summaryHistory")
                        }
                        if let summary = controller.summary {
                            if let asked = controller.context?.exchanges.last?.question {
                                Label(asked, systemImage: "bubble.left").font(.subheadline.weight(.medium))
                                    .frame(maxWidth: .infinity, alignment: .leading).accessibilityIdentifier("summaryQuestion")
                            }
                            PaperCard(tint: Notebook.yellow.opacity(0.13)) {
                                Text(summary.overview).lineSpacing(5).textSelection(.enabled)
                                    .frame(maxWidth: .infinity, alignment: .leading).accessibilityIdentifier("calendarSummaryOverview")
                            }
                            section("日程安排", icon: "calendar", values: summary.agenda)
                            section("需要留意", icon: "bell", values: summary.attention)
                            section("安排建议", icon: "lightbulb", values: summary.suggestions)
                            ViewThatFits {
                                HStack(spacing: 12) { copyButtons(summary) }
                                VStack(spacing: 10) { copyButtons(summary) }
                            }
                            if let copied { Text(copied).font(.caption).foregroundStyle(Notebook.accent) }
                        }
                        if let pending = controller.pendingQuestion {
                            Label(pending, systemImage: "bubble.left").font(.subheadline).accessibilityIdentifier("pendingSummaryQuestion")
                        }
                        if controller.running { progressCard }
                        if let error = controller.error {
                            NoteMessage(text: error, isError: true)
                            Button(controller.pendingQuestion == nil ? "重新总结" : "重试追问") { copied = nil; controller.retry(preferences: preferences) }
                                .buttonStyle(InkButtonStyle(prominent: false))
                        }
                        if controller.summary != nil {
                            Text("基于本次日程快照，建议不会修改日历。")
                                .font(.caption).foregroundStyle(Notebook.secondaryInk)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(22).frame(maxWidth: 720).frame(maxWidth: .infinity)
                }.scrollDismissesKeyboard(.interactively)
            }
            .safeAreaInset(edge: .bottom, spacing: 0) { if controller.summary != nil { composer } }
            .foregroundStyle(Notebook.ink)
            .navigationTitle("日历总结").navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button(controller.running ? "收起" : "完成") { dismiss() }.accessibilityIdentifier("closeCalendarSummary")
                }
                ToolbarItemGroup(placement: .keyboard) { Spacer(); Button("收起键盘") { questionFocused = false } }
            }
        }.tint(Notebook.accent)
            .presentationDetents([.medium, .large], selection: $detent).presentationDragIndicator(.visible)
            .onChange(of: questionFocused) { _, focused in if focused { detent = .large } }
            .onAppear { controller.setVisible(true) }
            .onDisappear { controller.setVisible(false) }
            .onChange(of: scenePhase) { _, phase in if phase == .active { controller.setVisible(true) } }
    }
    private var header: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "text.book.closed").font(.title2).foregroundStyle(Notebook.accent)
                .frame(width: 42, height: 46).background(Notebook.accent.opacity(0.08), in: RoundedRectangle(cornerRadius: 12))
            VStack(alignment: .leading, spacing: 7) {
                Text(controller.context?.title ?? "日历总结").font(Notebook.handwriting(25)).fixedSize(horizontal: false, vertical: true)
                if let input = controller.context?.input {
                    Text("\(input.events.count) 个日程 · \(controller.summary == nil ? "整理重点与安排" : "总结与追问")")
                        .font(.caption).foregroundStyle(Notebook.secondaryInk)
                }
                if !controller.recipient.isEmpty {
                    Text(controller.recipient).font(.caption2).foregroundStyle(Notebook.secondaryInk).lineLimit(1)
                }
            }.frame(maxWidth: .infinity, alignment: .leading)
        }.accessibilityIdentifier("summaryHeader")
    }
    private var progressCard: some View {
        PaperCard(tint: Notebook.accent.opacity(0.04)) {
            VStack(alignment: .leading, spacing: 16) {
                HStack(spacing: 12) {
                    ProgressView().tint(Notebook.accent)
                    VStack(alignment: .leading, spacing: 5) {
                        Text(controller.pendingQuestion == nil ? "正在整理日程" : "正在回答追问").font(.subheadline.weight(.semibold))
                        Text(controller.progressMessage).font(.caption).foregroundStyle(Notebook.secondaryInk)
                    }.frame(maxWidth: .infinity, alignment: .leading)
                }
                HStack(alignment: .center) {
                    Text("可以先收起，完成后再查看。")
                        .font(.caption).foregroundStyle(Notebook.secondaryInk).frame(maxWidth: .infinity, alignment: .leading)
                    Button("取消") { controller.cancel() }.font(.subheadline)
                        .frame(minWidth: 44, minHeight: 44).accessibilityIdentifier("cancelCalendarSummary")
                }
            }
        }.accessibilityIdentifier("summaryProgress")
    }
    private var composer: some View {
        HStack(alignment: .bottom, spacing: 12) {
            TextField("继续问问这些安排…", text: $question, axis: .vertical)
                .lineLimit(1...4).focused($questionFocused).padding(12)
                .background(Notebook.ink.opacity(0.04), in: RoundedRectangle(cornerRadius: 12))
                .accessibilityIdentifier("summaryFollowUpInput")
            Button {
                controller.followUp(question, preferences: preferences)
                if controller.running { question = ""; questionFocused = false; copied = nil }
            } label: {
                Image(systemName: "arrow.up").font(.body.weight(.semibold)).foregroundStyle(.white)
                    .frame(width: 44, height: 44).background(Notebook.blue, in: Circle())
            }.buttonStyle(.plain).disabled(controller.running || question.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                .opacity(controller.running || question.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? 0.45 : 1)
                .accessibilityLabel("发送追问").accessibilityIdentifier("sendSummaryFollowUp")
        }.frame(maxWidth: 676).padding(.horizontal, 22).padding(.vertical, 12)
            .frame(maxWidth: .infinity).background(Notebook.paper)
            .overlay(alignment: .top) { Rectangle().fill(Notebook.ink.opacity(0.1)).frame(height: 0.5) }
    }
    @ViewBuilder private func section(_ title: String, icon: String, values: [String]) -> some View {
        if !values.isEmpty {
            VStack(alignment: .leading, spacing: 12) {
                Label(title, systemImage: icon).font(Notebook.handwriting(21)).foregroundStyle(Notebook.accent)
                ForEach(Array(values.enumerated()), id: \.offset) { _, value in
                    HStack(alignment: .top, spacing: 10) {
                        Circle().fill(Notebook.accent.opacity(0.5)).frame(width: 5, height: 5).padding(.top, 9)
                        Text(value).lineSpacing(4).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }.frame(maxWidth: .infinity, alignment: .leading)
        }
    }
    @ViewBuilder private func copyButtons(_ value: CalendarSummary) -> some View {
        Button("复制纯文本") { copy(value, markdown: false) }.buttonStyle(InkButtonStyle(prominent: false)).accessibilityIdentifier("copySummaryPlain")
        Button("复制 Markdown") { copy(value, markdown: true) }.buttonStyle(InkButtonStyle(prominent: false)).accessibilityIdentifier("copySummaryMarkdown")
    }
    private func copy(_ value: CalendarSummary, markdown: Bool) {
        UIPasteboard.general.string = value.text(title: controller.context?.title ?? "日历总结", markdown: markdown)
        copied = markdown ? "已复制 Markdown" : "已复制纯文本"
    }
}
