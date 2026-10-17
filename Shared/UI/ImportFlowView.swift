import SwiftUI
import ShikeCore

struct ImportFlowView: View {
    @Environment(\.workspaceWidth) private var workspaceWidth
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @ObservedObject var controller: ImportController
    @ObservedObject var calendars: CalendarService
    var isExtension = false
    var showsAPIProfilePicker = false
    var isLoadingInput = false
    var isPlanningContent = false
    var onVoiceInput: (() -> Void)?
    var voiceRecording = false
    var voicePreparing = false
    var voiceFinishing = false
    var voiceInputEnabled = true
    @State private var isEditing = false
    @State private var editing: EventDraft?
    @State private var batchCalendar = ""
    @FocusState private var textFocused: Bool

    var body: some View {
        let wide = WorkspaceLayout.usesColumns(width: workspaceWidth, dynamicTypeSize: dynamicTypeSize) && !isExtension && !isPlanningContent
        let columns = wide ? AnyLayout(HStackLayout(alignment: .top, spacing: 28)) : AnyLayout(VStackLayout(alignment: .leading, spacing: 20))
        columns {
            if !isPlanningContent {
            VStack(alignment: .leading, spacing: 20) {
            PaperCard {
                VStack(alignment: .leading, spacing: 10) {
                    SourceTextHeader(preferences: controller.environment.preferences,
                                     characterCount: controller.session.text.count,
                                     showsAPIProfilePicker: showsAPIProfilePicker,
                                     isBusy: controller.isBusy || isLoadingInput)
                    ZStack(alignment: .topLeading) {
                        Text(sourcePlaceholder)
                            .foregroundStyle(Notebook.secondaryInk.opacity(0.85)).padding(.top, 9).padding(.leading, 4)
                            .opacity(controller.session.text.isEmpty ? 1 : 0).allowsHitTesting(false)
                            .accessibilityHidden(!controller.session.text.isEmpty)
                        TextEditor(text: $controller.session.text)
                            .foregroundColor(Notebook.ink).tint(Notebook.accent)
                            .scrollContentBackground(.hidden).frame(minHeight: 130, maxHeight: 200)
                            .focused($textFocused).accessibilityIdentifier(isExtension ? "share-sourceText" : "sourceText")
                            .disabled(sourceEditingDisabled)
                    }.font(.body)
                    HStack(spacing: 5) {
                        Button { controller.refreshReferenceDate() } label: {
                            HStack(spacing: 5) {
                                Image(systemName: "clock").fixedSize()
                                Text("相对日期按 \(referenceDateText) 理解")
                                    .lineLimit(1).minimumScaleFactor(0.7).allowsTightening(true)
                            }.frame(minHeight: 44, alignment: .leading).contentShape(Rectangle())
                        }.buttonStyle(.plain).font(.caption).foregroundStyle(Notebook.secondaryInk)
                            .disabled(sourceEditingDisabled || controller.review != nil || controller.consentRequest != nil)
                            .accessibilityHint("点击更新为当前时间，之后提取时生效")
                            .accessibilityValue(controller.session.effectiveReferenceDate.formatted(.iso8601))
                            .accessibilityIdentifier("refreshReferenceDate")
                        Spacer(minLength: 0)
                        if let onVoiceInput {
                            Button { textFocused = false; onVoiceInput() } label: {
                                Group {
                                    if voicePreparing || voiceFinishing { ProgressView() }
                                    else { Image(systemName: voiceRecording ? "stop.circle.fill" : "mic") }
                                }.font(.system(size: 18, weight: .medium)).frame(width: 44, height: 44)
                            }.buttonStyle(.plain).foregroundStyle(voiceRecording ? Notebook.red : Notebook.accent)
                                .disabled(!voiceInputEnabled || voicePreparing || voiceFinishing)
                                .accessibilityLabel(voiceRecording ? "停止语音输入" : "语音输入").accessibilityIdentifier("voiceInput")
                        }
                        ExpandTextEditorControl(text: $controller.session.text, title: "原文",
                                                editorID: isExtension ? "share-sourceText" : "sourceText",
                                                placeholder: sourcePlaceholder) { textFocused = false }
                            .disabled(sourceEditingDisabled)
                    }
                    if voiceRecording || voicePreparing || voiceFinishing {
                        Text(voicePreparing ? "正在开启麦克风…" : voiceFinishing ? "正在完成转写…" : "正在录音，点击停止按钮结束。")
                            .font(.caption).foregroundStyle(Notebook.red).accessibilityIdentifier("voiceInputStatus")
                    }
                }
            }

            if let error = controller.errorMessage {
                NoteMessage(text: error, isError: true).accessibilityIdentifier("errorMessage")
            }
            if let information = controller.information {
                NoteMessage(text: information).accessibilityIdentifier("statusMessage")
            }

            if !controller.session.pendingImages.isEmpty && !controller.isBusy {
                PaperCard {
                    VStack(alignment: .leading, spacing: 10) {
                        Text("还有 \(controller.session.pendingImages.count) 张图片待识别").font(.subheadline)
                        Button("继续识别图片") { controller.resumeImages() }.buttonStyle(InkButtonStyle(prominent: false))
                        Button("移除这些图片", role: .destructive) {
                            controller.session.pendingImages.forEach(ImageStaging.remove)
                            controller.session.pendingImages = []
                            controller.persistReportingError()
                        }.font(.subheadline)
                    }
                }.disabled(isLoadingInput)
            }

            if let busy = controller.busyMessage {
                HStack(spacing: 12) {
                    ProgressView().tint(Notebook.accent)
                    Text(busy).font(.subheadline)
                    Spacer()
                    if !busy.contains("加入日历") { Button("取消") { controller.cancel() } }
                }.padding(.vertical, 9).accessibilityIdentifier("progress")
            } else if controller.session.savedCount == 0 {
                HStack {
                    Text("日程类别").font(.subheadline)
                    Spacer()
                    Picker("日程类别", selection: $controller.session.forcedCategory) {
                        Text("AI 自动判断").tag(EventCategory?.none)
                        ForEach(EventCategory.allCases) { Text("指定为\($0.title)").tag(Optional($0)) }
                    }.pickerStyle(.menu).tint(Notebook.accent).accessibilityIdentifier("importCategory")
                }.disabled(isLoadingInput)
                let actionLayout = dynamicTypeSize.isAccessibilitySize
                    ? AnyLayout(VStackLayout(spacing: 10)) : AnyLayout(HStackLayout(spacing: 12))
                actionLayout {
                    if !isExtension {
                        Button { textFocused = false; controller.openPlanning() } label: {
                            Label("帮我安排", systemImage: "bubble.left.and.bubble.right")
                        }.buttonStyle(InkButtonStyle(prominent: false)).accessibilityIdentifier("planEvents")
                    }
                    Button { textFocused = false; controller.parse() } label: {
                        Label(controller.session.hasParsed ? "重新提取日程" : "提取日程", systemImage: "sparkle")
                    }.buttonStyle(InkButtonStyle()).accessibilityIdentifier(isExtension ? "share-parseEvents" : "parseEvents")
                }.disabled(controller.session.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || isLoadingInput)
                if isExtension {
                    Text(transmissionNote).font(.caption).foregroundStyle(Notebook.secondaryInk).frame(maxWidth: .infinity, alignment: .center)
                }
            }

            }.frame(maxWidth: .infinity, alignment: .topLeading)
            }
            VStack(alignment: .leading, spacing: 20) {
            if !controller.session.drafts.isEmpty {
                let summaryLayout = dynamicTypeSize.isAccessibilitySize
                    ? AnyLayout(VStackLayout(alignment: .leading, spacing: 6)) : AnyLayout(HStackLayout())
                summaryLayout {
                    Text("整理好了").font(Notebook.handwriting(27))
                    if !dynamicTypeSize.isAccessibilitySize { Spacer() }
                    Text("\(controller.session.drafts.count) 个日程").font(.subheadline).foregroundStyle(Notebook.secondaryInk)
                }.padding(.top, 5)

                if !calendars.authorized {
                    PaperCard {
                        VStack(alignment: .leading, spacing: 12) {
                            Text("选一本日历，放好这些安排。").font(Notebook.handwriting(20))
                            Text("允许完全访问后，即可选择日历，并在保存后继续修改。安排时只会经授权发送可用时段，已有事件内容不会发送给模型。")
                                .font(.subheadline).foregroundStyle(Notebook.secondaryInk)
                            Button("允许日历访问") { Task { await controller.requestCalendarAccess() } }
                                .buttonStyle(InkButtonStyle(prominent: false)).accessibilityIdentifier("grantCalendar")
                        }
                    }
                } else if calendars.calendars.isEmpty {
                    NoteMessage(text: "没有可写的日历。请先在系统日历 App 创建日历，或在系统设置中添加日历账户。", isError: true)
                } else if controller.session.drafts.contains(where: { !$0.isSaved }) {
                    Menu {
                        Button("逐项选择日历") { batchCalendar = "" }
                        ForEach(calendars.calendars) { calendar in
                            Button("\(calendar.title) · \(calendar.account)") { batchCalendar = calendar.id }
                        }
                    } label: {
                        Label(calendars.calendars.first(where: { $0.id == batchCalendar }).map { "\($0.title) · \($0.account)" } ?? "逐项选择日历", systemImage: "calendar")
                            .multilineTextAlignment(.leading).fixedSize(horizontal: false, vertical: true)
                            .frame(minHeight: 44, alignment: .leading)
                    }.font(.subheadline).tint(Notebook.accent).accessibilityLabel("统一加入日历")
                    .onChange(of: batchCalendar) { _, id in if !id.isEmpty { controller.setBatchCalendar(id) } }
                }

                ForEach($controller.session.drafts) { $draft in
                    draftRow($draft)
                }

                let pendingCount = controller.session.drafts.filter { $0.selected && !$0.isSaved }.count
                if pendingCount > 0 {
                    Button { textFocused = false; controller.saveSelected() } label: {
                        Label("将 \(pendingCount) 个日程加入日历", systemImage: "checkmark")
                    }.buttonStyle(InkButtonStyle()).disabled(controller.isBusy || !calendars.authorized || calendars.calendars.isEmpty)
                        .accessibilityIdentifier(isExtension ? "share-saveEvents" : (isPlanningContent ? "planning-saveEvents" : "saveEvents"))
                } else if controller.session.savedCount == controller.session.drafts.count {
                    HStack { Image(systemName: "checkmark.seal"); Text("都放进日历了，记得留一点时间给自己。") }
                        .font(Notebook.handwriting(18)).foregroundStyle(Notebook.ink).padding(.vertical, 8)
                }
            }
            else if wide {
                PaperCard {
                    VStack(alignment: .leading, spacing: 18) {
                        Label("留一页，给新的安排", systemImage: "calendar.badge.clock").font(Notebook.handwriting(26))
                        Text("在左边写下日程或想做的事。整理好的安排会出现在这里，核对后即可放进日历。")
                            .font(.subheadline).foregroundStyle(Notebook.secondaryInk)
                    }.frame(maxWidth: .infinity, minHeight: 210, alignment: .topLeading)
                }.accessibilityIdentifier("resultsPlaceholder")
            }
            }.frame(maxWidth: .infinity, alignment: .topLeading).disabled(isLoadingInput)
        }.foregroundStyle(Notebook.ink)
        .accessibilityHidden(controller.showsPlanning && !isPlanningContent)
        .sheet(item: $editing) { draft in
            DraftEditor(draft: draft, calendars: calendars) { changed in try controller.applyEdit(changed, expected: draft) }
                .presentationDetents([.large]).workspaceSheet()
        }
        .sheet(isPresented: Binding(get: { controller.review != nil && (isPlanningContent || !controller.showsPlanning) }, set: { if !$0 { controller.cancelReview() } })) {
            GuidedReviewView(controller: controller).presentationDetents([.large]).workspaceSheet()
        }
        .sheet(item: Binding(get: { (isPlanningContent || !controller.showsPlanning) ? controller.consentRequest : nil }, set: { if $0 == nil && controller.consentRequest != nil { controller.declineExtraction() } })) { scope in
            ExtractionConsentView(scope: scope, allow: controller.allowExtraction, cancel: controller.declineExtraction)
                .presentationDetents([.large]).workspaceSheet()
        }
        .sheet(isPresented: Binding(get: { controller.showsPlanning && !isPlanningContent && !isExtension }, set: { if !$0 && !isPlanningContent { controller.showsPlanning = false } })) {
            PlanningView(controller: controller, calendars: calendars, preferences: controller.environment.preferences).workspaceSheet(wide: true)
        }
        .toolbar {
            if !isPlanningContent && !controller.showsPlanning {
                ToolbarItemGroup(placement: .keyboard) { Spacer(); Button("收起键盘") { textFocused = false } }
            }
        }
    }

    private var sourceEditingDisabled: Bool {
        controller.isBusy || isLoadingInput || controller.session.savedCount > 0
    }

    private var referenceDateText: String {
        let format = Date.FormatStyle(timeZone: TimeZone(identifier: controller.session.referenceTimeZone) ?? .current)
            .month().day().hour().minute()
        return controller.session.effectiveReferenceDate.formatted(format)
    }

    private var sourcePlaceholder: String {
        isExtension ? "例如：明天下午两点到三点半，\n在三楼会议室做产品设计评审。" : "明天下午两点开会；\n或：这周想读完一本书，帮我安排。"
    }

    private var transmissionNote: String {
        if AppIdentity.usesFixtureModel { return "自动化测试：使用固定模型响应" }
        let host = URL(string: controller.environment.preferences.configuration.baseURL)?.host
        return host.map { "解析时将上方文字\(controller.environment.preferences.categoryRoutingEnabled ? "与候选日历名称" : "")发送至 \($0)" } ?? "请先在设置中配置大模型接口"
    }

    private func draftRow(_ binding: Binding<EventDraft>) -> some View {
        let draft = binding.wrappedValue
        let calendar = calendars.calendars.first { $0.id == draft.calendarID }
        return PaperCard(tint: draft.isSaved ? Notebook.green.opacity(0.12) : Notebook.paper) {
            VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .top, spacing: 9) {
                    if draft.isSaved {
                        Image(systemName: "checkmark.circle.fill").foregroundStyle(Notebook.accent).padding(.top, 5)
                    } else {
                        Button { binding.wrappedValue.selected.toggle() } label: {
                            Image(systemName: draft.selected ? "checkmark.square" : "square").font(.title3)
                                .foregroundStyle(Notebook.accent).frame(width: 44, height: 44)
                        }.accessibilityLabel(draft.selected ? "取消选择 \(draft.title)" : "选择 \(draft.title)")
                    }
                    Button {
                        editing = controller.prepareEdit(draft)
                    } label: {
                        HStack(alignment: .top, spacing: 9) {
                            VStack(alignment: .leading, spacing: 7) {
                                Text(draft.title.isEmpty ? "未命名日程" : draft.title).font(Notebook.handwriting(23))
                                Text(EventFormatting.schedule(draft)).font(.subheadline).foregroundStyle(Notebook.secondaryInk)
                            }.frame(maxWidth: .infinity, alignment: .leading)
                            Image(systemName: "pencil").foregroundStyle(Notebook.ink.opacity(0.55)).padding(.top, 5).accessibilityHidden(true)
                        }.contentShape(Rectangle())
                    }.buttonStyle(.plain).accessibilityIdentifier("\(isExtension ? "share-" : (isPlanningContent ? "planning-" : ""))editEvent-\(draft.title)")
                        .accessibilityValue("\(draft.category?.title ?? "未分类")，日历：\(calendar?.title ?? "未选择")")
                }
                if !draft.location.isEmpty {
                    Label(draft.location, systemImage: "mappin.and.ellipse").font(.subheadline).foregroundStyle(Notebook.secondaryInk)
                }
                HStack(spacing: 6) {
                    Circle().fill(calendar?.color ?? Notebook.ink.opacity(0.3)).frame(width: 7, height: 7)
                    Text(calendar?.title ?? "请选择日历").font(.caption)
                    if let category = draft.category {
                        Text(category.title).font(.caption).foregroundStyle(Notebook.secondaryInk)
                    }
                    Spacer()
                    if draft.isSaved { Text("已加入").font(.caption).foregroundStyle(Notebook.accent) }
                    else {
                        Menu {
                            Button("修改") { editing = controller.prepareEdit(draft) }
                            Button("移除草稿", role: .destructive) { controller.session.drafts.removeAll { $0.id == draft.id } }
                        } label: { Image(systemName: "ellipsis").frame(width: 44, height: 30) }.accessibilityLabel("日程操作")
                    }
                }
                if !draft.isSaved && !controller.saveIssues(draft).isEmpty {
                    Text(controller.saveIssues(draft).joined(separator: " · "))
                        .font(.caption).padding(.horizontal, 8).padding(.vertical, 6)
                        .background(Notebook.yellow.opacity(0.32), in: RoundedRectangle(cornerRadius: 4))
                }
                if let error = draft.saveError { Text(error).font(.caption).foregroundStyle(Notebook.red) }
            }
        }.disabled(controller.isBusy)
    }
}

private struct GuidedReviewView: View {
    @ObservedObject var controller: ImportController
    @State private var errorMessage: String?

    var body: some View {
        if let progress = controller.review {
            if let draft = controller.reviewDraft {
                DraftEditor(draft: draft, calendars: controller.environment.calendars,
                            reviewStep: DraftReviewStep(number: progress.completedCount + 1,
                                                        total: progress.completedCount + progress.pendingIDs.count,
                                                        saveCount: controller.reviewSaveCount,
                                                        isLast: progress.pendingIDs.count == 1,
                                                        skip: controller.skipReview, cancel: controller.cancelReview),
                            onSave: controller.confirmReview)
                    .id(draft.id)
            } else {
                NavigationStack {
                    ZStack {
                        PaperBackground()
                        ScrollView {
                            VStack(alignment: .leading, spacing: 20) {
                                MarginTitle(title: "剩下的安排，准备好了", subtitle: "暂不加入的日程保留在草稿中。")
                                Text("将 \(controller.reviewSaveCount) 个日程加入日历。")
                                if let errorMessage { NoteMessage(text: errorMessage, isError: true) }
                                Button("加入 \(controller.reviewSaveCount) 个日程") {
                                    do { try controller.finishReview() } catch { errorMessage = error.localizedDescription }
                                }.buttonStyle(InkButtonStyle()).accessibilityIdentifier("reviewSaveRemaining")
                            }.padding(22)
                        }
                    }.navigationTitle("完成核对").navigationBarTitleDisplayMode(.inline)
                        .toolbar {
                            ToolbarItem(placement: .cancellationAction) {
                                Button("退出核对") { controller.cancelReview() }.accessibilityIdentifier("exitReview")
                            }
                        }
                }.tint(Notebook.accent)
            }
        }
    }
}

private struct SourceTextHeader: View {
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @ObservedObject var preferences: Preferences
    let characterCount: Int
    let showsAPIProfilePicker: Bool
    let isBusy: Bool

    var body: some View {
        HStack(spacing: 8) {
            if showsAPIProfilePicker && !preferences.profiles.isEmpty {
                let titleLayout = dynamicTypeSize.isAccessibilitySize
                    ? AnyLayout(VStackLayout(alignment: .leading, spacing: 2))
                    : AnyLayout(HStackLayout(alignment: .firstTextBaseline, spacing: 8))
                titleLayout {
                    title
                    characterCountLabel
                }.fixedSize(horizontal: true, vertical: false)
                Spacer(minLength: 8)
                profileMenu
            } else {
                title
                Spacer()
                characterCountLabel
            }
        }
    }

    private var title: some View {
        Text("原文").font(Notebook.handwriting(21))
    }

    private var characterCountLabel: some View {
        Text("\(characterCount) 字").font(.caption).foregroundStyle(Notebook.secondaryInk)
    }

    private var profileMenu: some View {
        Menu {
            ForEach(preferences.profiles) { profile in
                Button { preferences.selectProfile(profile.id) } label: {
                    if profile.id == preferences.activeProfileID { Label(profile.name, systemImage: "checkmark") }
                    else { Text(profile.name) }
                }
            }
        } label: {
            Group {
                if dynamicTypeSize.isAccessibilitySize {
                    Image(systemName: "network").font(.title3).frame(width: 44, height: 44)
                } else {
                    HStack(spacing: 5) {
                        Text(preferences.activeProfile?.name ?? "选择接口")
                            .lineLimit(1).truncationMode(.tail)
                        Image(systemName: "chevron.down").font(.caption2.weight(.semibold))
                    }.font(.subheadline)
                        .frame(minWidth: 44, maxWidth: 140, minHeight: 44, alignment: .trailing)
                }
            }.contentShape(Rectangle())
        }.buttonStyle(.plain).tint(Notebook.accent).foregroundStyle(Notebook.accent)
            .disabled(isBusy)
            .accessibilityIdentifier("homeAPIProfile")
            .accessibilityLabel("解析接口").accessibilityValue(preferences.activeProfile?.name ?? "")
    }
}
