import SwiftUI
import ShikeCore

@MainActor final class CountdownNaturalLanguageController: ObservableObject {
    @Published var text = ""
    @Published var drafts: [CountdownDraft] = []
    @Published var error: String?
    @Published private(set) var busy = false
    @Published private(set) var progressMessage = "正在识别日子…"
    @Published private(set) var recognizedText: String?
    @Published var consentRequest: ExtractionConsent?
    private(set) var referenceDate = Date.now
    private var jobID: UUID?
    let preferences: Preferences
    private let consent: ExtractionConsentStore
    private let client: LLMClient
    private let store: CountdownStore
    private var operation: Task<Void, Never>?
    private var generation = UUID()
    init(preferences: Preferences, store: CountdownStore, consent: ExtractionConsentStore? = nil, client: LLMClient = LLMClient(), restored: ModelJobRecord? = nil) {
        self.preferences = preferences; self.store = store; self.consent = consent ?? ExtractionConsentStore(); self.client = client
        if let restored {
            text = restored.inputText ?? ""; referenceDate = restored.referenceDate ?? .now; jobID = restored.id
        }
        if let restored, case .countdowns(let input, let reference, let drafts) = restored.output {
            text = input; recognizedText = input; referenceDate = reference; self.drafts = drafts; jobID = restored.id
        }
    }
    var inputChanged: Bool { recognizedText != nil && recognizedText != text }
    var canSave: Bool { !busy && !inputChanged && !drafts.filter(\.selected).isEmpty && drafts.filter(\.selected).allSatisfy { !$0.dateMissing } }
    func allow() {
        if let consentRequest { consent.grant(consentRequest) }
        consentRequest = nil; recognize()
    }
    func recognize() {
        guard !busy else { return }
        error = nil
        do {
            guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, text.count <= 30_000 else { throw ShikeError.message("请填写 1–30000 字的日子描述。") }
            let configuration = preferences.activeProfile?.configuration ?? preferences.configuration
            #if DEBUG
            let fixture = AppIdentity.usesFixtureModel
            #else
            let fixture = false
            #endif
            if !fixture {
                let scope = try ExtractionConsent(configuration: configuration, includesCalendarNames: false)
                guard consent.allows(scope) else { consentRequest = scope; return }
            }
            let key = fixture ? "" : try preferences.activeProfile.map { try preferences.profileKey($0) } ?? ""
            let input = text, categories = store.categories, zone = TimeZone.current
            let token = UUID(); generation = token; busy = true; progressMessage = "正在识别日子…"
            let observer: LLMObserver = { [weak self] update in
                guard case .progress(let progress) = update else { return }
                Task { @MainActor [weak self] in
                    guard let self, self.generation == token, self.busy else { return }
                    self.progressMessage = progress.message
                }
            }
            jobID = token
            operation = ModelJobCenter.shared.start(id: token, kind: .countdowns, inputText: input, referenceDate: referenceDate, work: { [self] context in
                    let result: [CountdownDraft]
                    #if DEBUG
                    if fixture {
                        try await Task.sleep(for: .milliseconds(250))
                        result = try CountdownExtraction.decode(Self.fixtureResponse, referenceDate: referenceDate, timeZone: zone, categories: categories)
                    } else {
                        result = try await client.extractCountdowns(text: input, referenceDate: referenceDate, timeZone: zone, configuration: configuration, apiKey: key, categories: categories, observer: context.observer(observer))
                    }
                    #else
                    result = try await client.extractCountdowns(text: input, referenceDate: referenceDate, timeZone: zone, configuration: configuration, apiKey: key, categories: categories, observer: context.observer(observer))
                    #endif
                    try Task.checkCancellation()
                    return .countdowns(text: input, reference: referenceDate, drafts: result)
            }, completion: { [self] result in
                guard generation == token else { return }
                busy = false; operation = nil
                switch result {
                case .success(.countdowns(_, _, let values)):
                    drafts = values; recognizedText = input
                    if values.isEmpty { error = "没有识别到日子，试着写上名称和日期，例如“12 月 1 日去看海”。" }
                case .failure(let error): if !(error is CancellationError) { self.error = error.localizedDescription }
                default: break
                }
            })
        } catch { self.error = error.localizedDescription }
    }
    func cancel() { generation = UUID(); operation?.cancel(); operation = nil; busy = false }
    func save() throws -> [Countdown] {
        guard canSave else { throw ShikeError.message("请先补全所选日子的日期。") }
        let entries = drafts.filter(\.selected).map(\.entry)
        try store.insert(entries)
        if let jobID { ModelJobCenter.shared.acknowledge(jobID) }
        return entries
    }
    #if DEBUG
    private static let fixtureResponse = #"{"countdowns":[{"title":"自然语言去看海","date":"2026-12-01","category":"生活"},{"title":"自然语言纪念日","date":"2020-05-20","recurrence":"yearly","includesStartDay":true,"reminder":{"milestoneDays":[]}},{"title":"等你确定的日子","date":null,"reviewNotes":["请补充出发日期"]}]}"#
    #endif
}

struct CountdownNaturalLanguageView: View {
    @ObservedObject var store: CountdownStore
    @ObservedObject var reminders: CountdownReminderService
    @ObservedObject var preferences: Preferences
    @StateObject private var controller: CountdownNaturalLanguageController
    @State private var editing: CountdownDraft?
    @State private var saving = false
    @FocusState private var focused: Bool
    @Environment(\.dismiss) private var dismiss
    let onSaved: () -> Void
    init(store: CountdownStore, reminders: CountdownReminderService, preferences: Preferences, restored: ModelJobRecord? = nil, onSaved: @escaping () -> Void) {
        self.store = store; self.reminders = reminders; self.preferences = preferences; self.onSaved = onSaved
        _controller = StateObject(wrappedValue: CountdownNaturalLanguageController(preferences: preferences, store: store, restored: restored))
    }
    var body: some View {
        NavigationStack {
            ZStack { PaperBackground(); ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    MarginTitle(title: "想记住的，都写下来。", subtitle: "一句话，也可以记下好几个日子。")
                    inputCard
                    if let error = controller.error { NoteMessage(text: error, isError: true) }
                    if controller.busy {
                        HStack { ProgressView(); Text(controller.progressMessage); Spacer(); Button("取消识别") { controller.cancel() } }
                    } else {
                        Button { focused = false; controller.recognize() } label: {
                            Label(controller.drafts.isEmpty ? "识别倒数日" : "重新识别", systemImage: "sparkles")
                        }.buttonStyle(InkButtonStyle()).disabled(controller.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || saving)
                            .accessibilityIdentifier("recognizeCountdowns")
                    }
                    if !controller.drafts.isEmpty {
                        Text("识别到 \(controller.drafts.count) 个日子").font(Notebook.handwriting(25))
                        Text("核对后保存。可以修改详情，也可以取消勾选。").font(.subheadline).foregroundStyle(Notebook.secondaryInk)
                        if controller.inputChanged { NoteMessage(text: "描述已修改，请重新识别后保存。") }
                        ForEach($controller.drafts) { $draft in resultCard($draft) }
                        Button("保存所选 \(controller.drafts.filter(\.selected).count) 个日子") { save() }
                            .buttonStyle(InkButtonStyle()).disabled(!controller.canSave || saving).accessibilityIdentifier("saveRecognizedCountdowns")
                    }
                }.padding(22).frame(maxWidth: 680).frame(maxWidth: .infinity)
            }.scrollDismissesKeyboard(.interactively) }
                .foregroundStyle(Notebook.ink).navigationTitle("自然语言识别").navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) { Button("完成") { dismiss() }.disabled(saving) }
                    ToolbarItemGroup(placement: .keyboard) { Spacer(); Button("收起键盘") { focused = false } }
                }
                .sheet(item: $controller.consentRequest) { scope in
                    ExtractionConsentView(scope: scope, allow: { controller.allow() }, cancel: { controller.consentRequest = nil })
                }
                .sheet(item: $editing) { draft in
                    CountdownEditor(store: store, reminders: reminders, entry: draft.entry, requiresDate: draft.dateMissing) { updated in
                        guard let index = controller.drafts.firstIndex(where: { $0.id == updated.id }) else { return }
                        controller.drafts[index].entry = updated
                        controller.drafts[index].dateMissing = false
                        controller.drafts[index].reviewNotes = []
                    }
                }

        }.tint(Notebook.accent).interactiveDismissDisabled(saving)
    }
    private var inputCard: some View {
        PaperCard { VStack(alignment: .leading, spacing: 14) {
            if !preferences.profiles.isEmpty {
                Picker("识别接口", selection: Binding(get: { preferences.activeProfileID }, set: { preferences.selectProfile($0) })) {
                    ForEach(preferences.profiles) { Text($0.name).tag($0.id) }
                }.disabled(controller.busy || saving)
            }
            TextField("例如：12 月 1 日去看海；2020 年 5 月 20 日是纪念日，每年重复，包含起始日。", text: $controller.text, axis: .vertical)
                .lineLimit(6...14).focused($focused).disabled(controller.busy || saving).accessibilityIdentifier("countdownNaturalText")
            Text("相对日期按 \(controller.referenceDate.formatted(date: .abbreviated, time: .shortened)) 理解，使用系统时区。")
                .font(.caption).foregroundStyle(Notebook.secondaryInk)
        } }
    }
    private func resultCard(_ binding: Binding<CountdownDraft>) -> some View {
        let draft = binding.wrappedValue
        return PaperCard { VStack(alignment: .leading, spacing: 12) {
            Toggle(isOn: binding.selected) { Text(draft.entry.title).font(Notebook.handwriting(23)) }
                .accessibilityIdentifier("selectRecognized-\(draft.entry.title)")
            Text(draft.dateMissing ? "待补全日期" : "\(CountdownDates.targetDescription(draft.entry)) · \(draft.entry.calendar.title) · \(draft.entry.recurrence.title)")
                .font(.subheadline).foregroundStyle(draft.dateMissing ? .orange : Notebook.secondaryInk)
            if !draft.entry.notes.isEmpty { Text(draft.entry.notes).font(.subheadline) }
            ForEach(Array(draft.reviewNotes.enumerated()), id: \.offset) { _, note in Text(note).font(.caption).foregroundStyle(Notebook.secondaryInk) }
            Button(draft.dateMissing ? "补全日期与详情" : "修改详情") { editing = draft }
                .frame(minHeight: 44).accessibilityIdentifier("editRecognized-\(draft.entry.title)")
        } }.disabled(controller.busy || saving)
    }
    private func save() {
        do {
            let entries = try controller.save()
            saving = true
            Task {
                if entries.contains(where: { $0.reminder.isEnabled }) { await reminders.requestAccess() }
                await reminders.replan(store.entries)
                onSaved(); dismiss()
            }
        } catch { controller.error = error.localizedDescription }
    }
}
