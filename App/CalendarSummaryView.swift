import SwiftUI
import ShikeCore

struct CalendarSummaryRequest: Identifiable {
    let id = UUID()
    let title: String
    let input: CalendarSummaryInput
}

struct CalendarSummaryView: View {
    let request: CalendarSummaryRequest
    @ObservedObject var preferences: Preferences
    @Environment(\.dismiss) private var dismiss
    @State private var summary: CalendarSummary?
    @State private var error: String?
    @State private var copied: String?
    @State private var started = false
    @State private var recipient = ""
    @State private var progressMessage = "正在整理这些安排…"
    @State private var generation = UUID()
    var body: some View {
        NavigationStack {
            ZStack { PaperBackground(); ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    Text(request.title).font(Notebook.handwriting(25))
                    Text("\(request.input.events.count) 个日程" + (recipient.isEmpty ? "" : " · \(recipient)"))
                        .font(.caption).foregroundStyle(Notebook.secondaryInk)
                    if let summary {
                        Text(summary.overview).textSelection(.enabled).accessibilityIdentifier("calendarSummaryOverview")
                        section("日程安排", values: summary.agenda)
                        section("需要留意", values: summary.attention)
                        section("安排建议", values: summary.suggestions)
                        Text("模型总结仅供参考，日历内容未修改。").font(.caption).foregroundStyle(Notebook.secondaryInk)
                        ViewThatFits {
                            HStack { copyButtons(summary) }
                            VStack { copyButtons(summary) }
                        }
                        if let copied { Text(copied).font(.caption).foregroundStyle(Notebook.accent) }
                    } else if let error {
                        NoteMessage(text: error, isError: true)
                        Button("重新总结") { generate() }.buttonStyle(InkButtonStyle())
                    } else {
                        HStack { ProgressView(); Text(progressMessage) }.padding(.vertical, 25)
                    }
                }.padding(22).frame(maxWidth: 680).frame(maxWidth: .infinity, alignment: .leading)
            } }.navigationTitle("日历总结").navigationBarTitleDisplayMode(.inline)
                .toolbar { ToolbarItem(placement: .confirmationAction) { Button(summary == nil && error == nil ? "取消" : "完成") { if summary == nil && error == nil { ModelJobCenter.shared.cancel(generation) }; dismiss() } } }
        }.tint(Notebook.accent)
            .onAppear { if !started { started = true; generate() } }
    }
    @ViewBuilder private func section(_ title: String, values: [String]) -> some View {
        if !values.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                Text(title).font(Notebook.handwriting(21))
                ForEach(Array(values.enumerated()), id: \.offset) { _, value in Text("• " + value).textSelection(.enabled) }
            }
        }
    }
    @ViewBuilder private func copyButtons(_ value: CalendarSummary) -> some View {
        Button("复制纯文本") { copy(value, markdown: false) }.buttonStyle(InkButtonStyle(prominent: false)).accessibilityIdentifier("copySummaryPlain")
        Button("复制 Markdown") { copy(value, markdown: true) }.buttonStyle(InkButtonStyle(prominent: false)).accessibilityIdentifier("copySummaryMarkdown")
    }
    private func copy(_ value: CalendarSummary, markdown: Bool) {
        UIPasteboard.general.string = value.text(title: request.title, markdown: markdown)
        copied = markdown ? "已复制 Markdown" : "已复制纯文本"
    }
    @MainActor private func generate() {
        error = nil; summary = nil; copied = nil
        let token = UUID(); generation = token; progressMessage = "正在整理这些安排…"
        do {
            #if DEBUG
            if AppIdentity.isUITesting {
                summary = CalendarSummary(overview: "这段时间有 \(request.input.events.count) 个安排。", agenda: request.input.events.map(\.title), attention: [], suggestions: ["为相邻安排留出缓冲时间。"])
                return
            }
            #endif
            let profile = preferences.activeProfile
            let configuration = profile?.configuration ?? preferences.configuration
            recipient = URL(string: configuration.baseURL)?.host ?? ""
            let key = try profile.map { try preferences.profileKey($0) } ?? ""
            ModelJobCenter.shared.start(id: token, kind: .summary, work: { context in
                let value = try await LLMClient().summarizeCalendar(request.input, configuration: configuration, apiKey: key, observer: context.observer { update in
                    guard case .progress(let progress) = update else { return }
                    Task { @MainActor in
                        guard generation == token, summary == nil, error == nil else { return }
                        progressMessage = progress.message
                    }
                })
                return .summary(title: request.title, value: value)
            }, completion: { result in
                guard generation == token else { return }
                switch result {
                case .success(.summary(_, let value)): summary = value
                case .failure(let failure): if !(failure is CancellationError) { error = failure.localizedDescription }
                default: break
                }
            })
        } catch is CancellationError { }
        catch { if !Task.isCancelled { self.error = error.localizedDescription } }
    }
}
