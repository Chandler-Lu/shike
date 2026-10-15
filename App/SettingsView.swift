import SwiftUI
import ShikeCore

struct SettingsView: View {
    @ObservedObject var environment: AppEnvironment
    @ObservedObject var countdownSync: CountdownSync
    @ObservedObject private var calendars: CalendarService
    @ObservedObject private var preferences: Preferences
    @State private var apiExpanded = false
    @State private var calendarExpanded = false
    @State private var promptsExpanded = false
    @State private var syncExpanded = false
    @State private var editingPrompt: PromptPurpose?
    @State private var calendarMessage: String?
    @State private var syncError: String?
    @State private var consentMessage: String?
    @State private var showShortcutGuide = false

    init(environment: AppEnvironment, countdownSync: CountdownSync) {
        self.countdownSync = countdownSync
        self.environment = environment
        calendars = environment.calendars
        preferences = environment.preferences
    }
    var body: some View {
        ZStack {
            PaperBackground()
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    VStack(spacing: 10) {
                        ReadingCompanions().frame(maxWidth: 390)
                        Text("把每一刻，好好放好。").font(Notebook.handwriting(28, relativeTo: .title))
                        Text("按你的习惯，安排每一天。")
                            .font(.subheadline).foregroundStyle(Notebook.secondaryInk)
                    }.frame(maxWidth: .infinity).padding(.bottom, 8)

                    calendarSettings

                    PaperCard {
                        DisclosureGroup(isExpanded: $apiExpanded) {
                            ModelAPISettingsView(preferences: preferences).padding(.top, 18)
                        } label: {
                            VStack(alignment: .leading, spacing: 7) {
                                Label("模型与 API", systemImage: "sparkle").font(Notebook.handwriting(23))
                                Text(preferences.configuration.model.isEmpty ? "连接服务，选择你喜欢的模型" : preferences.configuration.model)
                                    .font(.caption).foregroundStyle(Notebook.secondaryInk).lineLimit(2)
                            }.padding(.vertical, 5)
                        }
                    }

                    promptSettings
                    cloudSettings
                    DataExportView(environment: environment)

                    NavigationLink {
                        ModelJobListView(jobs: environment.modelJobs, environment: environment, reminders: CountdownReminderService())
                    } label: { Label("模型任务与结果", systemImage: "sparkles").frame(minHeight: 44) }
                    usageTips

                    DisclosureGroup {
                        VStack(alignment: .leading, spacing: 12) {
                            Text("图片在设备上识别。经你允许后，将原文、参考日期、时区和指定类别发送到你配置的模型服务，安排时另经授权发送问答与可用时段。点击日历页“总结”会直接发送当前显示日程的标题、时间与地点，不发送备注、账户或内部标识。原图不上传。")
                            Text("开启自动选择日历后，会将可写日历名称交给模型匹配，不发送已有日历事件。手动指定的类别和日历优先。开启 iCloud 后，设置、日历名称和倒数日会在你的设备间同步。")
                            Text("草稿与导入记录保存在本机；开启云端备份后，JSON 副本会保存到 iCloud Drive。系统日历的同步由你配置的日历账户负责。")
                            Text("语音由系统转写，优先在设备上识别，不保存录音。")
                            NavigationLink("隐私政策") { LegalDocumentView() }.frame(minHeight: 44).accessibilityIdentifier("privacyPolicy")
                            NavigationLink("字体许可") { LegalDocumentView(showsFontLicense: true) }.frame(minHeight: 44)
                            Link("帮助与支持", destination: AppLegal.supportURL).frame(minHeight: 44)
                            Link("联系作者", destination: AppLegal.emailURL).frame(minHeight: 44)
                            Button("撤销模型发送授权") {
                                environment.consent.revokeAll()
                                consentMessage = "已撤销。本设备下次提取时会重新询问；已经发送的内容无法撤回。"
                            }.frame(minHeight: 44).accessibilityIdentifier("revokeExtractionConsent")
                            if let consentMessage { Text(consentMessage).font(.caption) }
                        }.font(.subheadline).foregroundStyle(Notebook.secondaryInk).padding(.top, 12)
                    } label: {
                        Label("关于内容与隐私", systemImage: "lock").font(.subheadline)
                    }.padding(.horizontal, 8)
                    VStack(spacing: 8) {
                        Text(AppLegal.version).font(Notebook.handwriting(17))
                        Text("作者：Chandler-Lu").font(.subheadline)
                        Link("作者主页 · www.yeslu.cn", destination: URL(string: "https://www.yeslu.cn")!)
                            .font(.footnote).foregroundStyle(Notebook.accent)
                    }.foregroundStyle(Notebook.secondaryInk).frame(maxWidth: .infinity)
                }.padding(22).frame(maxWidth: 680).frame(maxWidth: .infinity)
            }.scrollDismissesKeyboard(.interactively)
        }.foregroundStyle(Notebook.ink).navigationTitle("设置").navigationBarTitleDisplayMode(.inline)
            .sheet(item: $editingPrompt) { purpose in
                PromptEditorView(preferences: preferences, purpose: purpose)
            }
            .sheet(isPresented: $showShortcutGuide) { ShortcutGuideView().workspaceSheet() }
            .onAppear { preferences.updateCalendars(calendars.calendars) }
            .onChange(of: calendars.calendars.map(\.id)) { _, _ in preferences.updateCalendars(calendars.calendars) }
    }

    private var usageTips: some View {
        DisclosureGroup {
            VStack(alignment: .leading, spacing: 18) {
                VStack(alignment: .leading, spacing: 8) {
                    Label("从分享菜单导入", systemImage: "square.and.arrow.up").foregroundStyle(Notebook.ink)
                    Text("在其他 App 中选中文字或图片，打开分享菜单，选择「拾刻计划」保存内容，再打开主 App 识别、核对并加入日历。若未显示，可在分享菜单的「更多」中启用。")
                        .accessibilityIdentifier("sharingTip")
                }
                VStack(alignment: .leading, spacing: 8) {
                    Label("通过捷径识别当前页面", systemImage: "square.stack.3d.up").foregroundStyle(Notebook.ink)
                    Text("在系统「快捷指令」中连接「截屏」和「识别图片并提取日程」，也可以导入剪贴板或听写文字。")
                    Button("查看捷径设置方法") { showShortcutGuide = true }
                        .frame(minHeight: 44).accessibilityIdentifier("shortcutGuide")
                }
                VStack(alignment: .leading, spacing: 8) {
                    Label("在输入框中说下安排", systemImage: "mic").foregroundStyle(Notebook.ink)
                    Text("点击首页输入框右下角、放大按钮左侧的麦克风，即可开始录音，转写文字会直接追加到原文，再点一次停止。")
                }
            }.font(.subheadline).foregroundStyle(Notebook.secondaryInk).padding(.top, 12)
        } label: {
            Label("使用技巧", systemImage: "lightbulb").font(.subheadline)
        }.padding(.horizontal, 8)
    }

    private var calendarSettings: some View {
        PaperCard {
            DisclosureGroup(isExpanded: $calendarExpanded) {
            VStack(alignment: .leading, spacing: 16) {
                if calendars.authorized {
                    calendarPicker("默认日历", selected: Binding(get: { preferences.defaultCalendarID }, set: { preferences.setDefaultCalendar($0) }), fallback: "跟随系统默认")
                    if calendars.calendars.isEmpty {
                        Text("请先在系统日历中添加可写日历。").foregroundStyle(Notebook.red).font(.subheadline)
                    }
                } else {
                    Button("允许日历访问") {
                        Task {
                            do { try await calendars.requestAccess(); calendarMessage = nil }
                            catch { calendarMessage = error.localizedDescription }
                        }
                    }.buttonStyle(InkButtonStyle(prominent: false))
                }
                Divider()
                Toggle("日程类别判断", isOn: Binding(get: { preferences.categoryRoutingEnabled }, set: { preferences.setCategoryRouting($0) }))
                    .padding(.trailing, 4)
                    .font(.subheadline).tint(Notebook.accent).accessibilityIdentifier("categoryRouting")
                Text(preferences.categoryRoutingEnabled ? "按日程类别自动选择日历。指定对应日历时优先使用；未指定则由 AI 按日历名称匹配，例如出行安排优选“个人出行”。" : "关闭时，新日程统一使用默认日历。")
                    .font(.caption).foregroundStyle(Notebook.secondaryInk).fixedSize(horizontal: false, vertical: true)
                if preferences.categoryRoutingEnabled {
                    if calendars.authorized {
                        ForEach(EventCategory.allCases) { category in
                            calendarPicker(category.title, selected: Binding(
                                get: { preferences.categoryCalendars[category.rawValue] ?? "" },
                                set: { preferences.setCategoryCalendar($0, for: category) }), fallback: "AI 按名称匹配")
                                .accessibilityIdentifier("categoryCalendar-\(category.rawValue)")
                        }
                        Text("AI 无法确定或指定日历不可用时，使用默认日历；原文和候选日历名称会发送到所选接口")
                            .font(.caption).foregroundStyle(Notebook.secondaryInk)
                    } else {
                        Text("允许日历访问后，即可为每个类别选择日历。").font(.caption).foregroundStyle(Notebook.secondaryInk)
                    }
                }
                if let calendarMessage { NoteMessage(text: calendarMessage, isError: true) }
            }.padding(.top, 18)
            } label: {
                sectionLabel("日历偏好", symbol: "calendar", detail: preferences.categoryRoutingEnabled ? "按类别选择日历" : "默认日历与类别规则")
            }
        }
    }

    private var promptSettings: some View {
        PaperCard {
            DisclosureGroup(isExpanded: $promptsExpanded) {
                VStack(alignment: .leading, spacing: 12) {
                    ForEach(PromptPurpose.allCases) { purpose in
                        Button { editingPrompt = purpose } label: {
                            HStack {
                                VStack(alignment: .leading, spacing: 5) {
                                    Text(purpose.title).font(.subheadline)
                                    Text(preferences.promptSettings.customText(for: purpose) == nil ? "默认提示词" : "自定义提示词")
                                        .font(.caption).foregroundStyle(Notebook.secondaryInk)
                                }
                                Spacer()
                                Image(systemName: "pencil").accessibilityHidden(true)
                            }.frame(minHeight: 44).contentShape(Rectangle())
                        }.buttonStyle(.plain).accessibilityIdentifier("editPrompt-\(purpose.rawValue)")
                    }
                }.padding(.top, 18)
            } label: {
                sectionLabel("提示词", symbol: "text.bubble", detail: "自定义识别规则与安排习惯")
            }
        }
    }

    private var cloudSettings: some View {
        PaperCard {
            DisclosureGroup(isExpanded: $syncExpanded) {
                VStack(alignment: .leading, spacing: 14) {
                    Toggle("同步设置、API 与倒数日", isOn: Binding(get: { preferences.iCloudEnabled }, set: { enabled in
                        do { try preferences.setCloudEnabled(enabled); syncError = nil }
                        catch { syncError = error.localizedDescription }
                    })).padding(.trailing, 4).font(.subheadline).tint(Notebook.accent).accessibilityIdentifier("iCloudSettings")
                    Text("同步接口、模型、提示词、日历偏好和倒数日。API Key 通过 iCloud 钥匙串同步，需在系统设置中开启。")
                        .font(.caption).foregroundStyle(Notebook.secondaryInk)
                    if preferences.iCloudEnabled {
                        Text(preferences.syncStatus).font(.caption).foregroundStyle(Notebook.secondaryInk)
                        Text(countdownSync.status).font(.caption).foregroundStyle(Notebook.secondaryInk)
                        Button("检查同步") { preferences.checkCloudSync(); countdownSync.refresh(userInitiated: true) }.font(.subheadline)
                        if let diagnostic = countdownSync.diagnostic {
                            DisclosureGroup("同步诊断") {
                                Text(diagnostic).font(.caption).textSelection(.enabled).padding(.top, 8)
                            }.font(.subheadline)
                        }
                        Text("在其他设备也开启此开关，已有云端设置会优先载入；如首次使用则上传本机已保存的设置；关闭只停止本设备同步。")
                            .font(.caption).foregroundStyle(Notebook.secondaryInk)
                    }
                    if let syncError { NoteMessage(text: syncError, isError: true) }
                }.padding(.top, 18)
            } label: {
                sectionLabel("iCloud 同步", symbol: "icloud", detail: preferences.iCloudEnabled ? preferences.syncStatus : "在你的设备间同步设置与倒数日")
            }
        }
    }

    private func sectionLabel(_ title: String, symbol: String, detail: String) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            Label(title, systemImage: symbol).font(Notebook.handwriting(23))
            Text(detail).font(.caption).foregroundStyle(Notebook.secondaryInk).lineLimit(2)
        }.padding(.vertical, 5)
    }

    private func calendarPicker(_ title: String, selected: Binding<String>, fallback: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.caption).foregroundStyle(Notebook.secondaryInk)
            Picker(title, selection: selected) {
                Text(fallback).tag("")
                ForEach(calendars.calendars) { Text("\($0.title)（\($0.account)）").tag($0.id) }
                if !selected.wrappedValue.isEmpty && !calendars.calendars.contains(where: { $0.id == selected.wrappedValue }) {
                    Text("原日历不可用，请重新选择").tag(selected.wrappedValue)
                }
            }
            .pickerStyle(.menu).font(.subheadline).tint(Notebook.accent)
        }
    }
}

private struct PromptEditorView: View {
    @ObservedObject var preferences: Preferences
    let purpose: PromptPurpose
    @Environment(\.dismiss) private var dismiss
    @State private var text = ""
    @State private var saved = ""
    @State private var error: String?
    @State private var remoteChanged = false
    @State private var loaded = false
    @FocusState private var focused: Bool

    var body: some View {
        NavigationStack {
            ZStack {
                PaperBackground()
                ScrollView {
                    VStack(alignment: .leading, spacing: 18) {
                        Text(purpose == .extraction ? "告诉拾刻计划，怎样整理你的日程。" : "告诉拾刻计划，你喜欢怎样安排时间。")
                            .font(Notebook.handwriting(25))
                        Text("这套提示词会随请求发送给当前模型服务。日程字段格式由拾刻计划自动补充。")
                            .font(.subheadline).foregroundStyle(Notebook.secondaryInk)
                        if remoteChanged {
                            NoteMessage(text: "同步的提示词有更新，当前未保存的输入已保留。")
                            Button("载入已同步提示词") { load() }.font(.subheadline)
                        }
                        PaperCard {
                            VStack(alignment: .leading, spacing: 12) {
                                TextEditor(text: $text).frame(minHeight: 330).scrollContentBackground(.hidden)
                                    .font(.body).focused($focused).accessibilityIdentifier("promptText")
                                HStack {
                                    Text("\(text.count) / 12000 字").font(.caption).foregroundStyle(Notebook.secondaryInk)
                                    Spacer(minLength: 0)
                                    ExpandTextEditorControl(text: $text, title: purpose.title + "提示词",
                                                            editorID: "promptText", characterLimit: 12000) { focused = false }
                                }
                            }
                        }
                        Button("恢复默认提示词") { text = purpose.defaultText; error = nil }
                            .font(.subheadline).accessibilityIdentifier("resetPrompt")
                        Text("编辑后点击保存生效；留空会使用默认提示词。")
                            .font(.caption).foregroundStyle(Notebook.secondaryInk)
                        if let error { NoteMessage(text: error, isError: true) }
                    }.padding(22)
                }.scrollDismissesKeyboard(.interactively)
            }.foregroundStyle(Notebook.ink)
                .navigationTitle(purpose.title + "提示词").navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } }
                    ToolbarItem(placement: .confirmationAction) {
                        Button("保存") {
                            do { try preferences.setPrompt(text, for: purpose); dismiss() }
                            catch { self.error = error.localizedDescription }
                        }.accessibilityIdentifier("savePrompt")
                    }
                    ToolbarItemGroup(placement: .keyboard) { Spacer(); Button("收起键盘") { focused = false } }
                }
                .onAppear { if !loaded { load(); loaded = true } }
                .onChange(of: preferences.promptSettings) { _, _ in
                    if text == saved { load() } else { remoteChanged = true }
                }
        }.tint(Notebook.accent)
    }
    private func load() {
        text = preferences.promptSettings.text(for: purpose)
        saved = text; remoteChanged = false; error = nil
    }
}

private struct ReadingCompanions: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @GestureState private var isHolding = false
    @State private var accessibilityReaction = false
    private var chubby: Bool { isHolding || accessibilityReaction }

    private var petGesture: some Gesture {
        LongPressGesture(minimumDuration: 0.5)
            .sequenced(before: DragGesture(minimumDistance: 0))
            .updating($isHolding) { value, state, _ in
                if case .second(true, _) = value { state = true }
            }
    }

    var body: some View {
        VStack(spacing: 4) {
            ZStack {
                Image("SettingsCompanions").resizable().scaledToFit()
                    .accessibilityLabel("兔兔和长毛缅因猫趴着一起看书").accessibilityIdentifier("settingsCompanions")
                Image("SettingsCompanionsChubby").resizable().scaledToFit()
                    .mask(CatReactionMask().blur(radius: 0.8)).opacity(chubby ? 1 : 0).accessibilityHidden(true)
            }.overlay {
                GeometryReader { geometry in
                    Color.clear.frame(width: geometry.size.width * 0.52, height: geometry.size.height * 0.88)
                        .contentShape(Rectangle())
                        .gesture(petGesture)
                        .accessibilityElement().accessibilityLabel("长按缅因猫")
                        .accessibilityValue(chubby ? "胖猫猫" : "普通猫猫")
                        .accessibilityHint("按住变胖，松手恢复；双击可短暂预览胖猫猫")
                        .accessibilityAddTraits(.isButton).accessibilityAction { accessibilityReaction = true }
                        .accessibilityIdentifier("petMaineCoon")
                        .position(x: geometry.size.width * 0.74, y: geometry.size.height * 0.5)
                }
            }
        }
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.25), value: chubby)
        .task(id: accessibilityReaction) {
            guard accessibilityReaction else { return }
            do { try await Task.sleep(for: .seconds(1.5)) } catch { return }
            accessibilityReaction = false
        }
        .onDisappear { accessibilityReaction = false }
    }
}

// Composite only the cat so the original bunny and book remain stationary.
private struct CatReactionMask: Shape {
    func path(in rect: CGRect) -> Path {
        func point(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: rect.width * x, y: rect.height * y) }
        var path = Path()
        path.move(to: point(0.55, 0)); path.addLine(to: point(1, 0)); path.addLine(to: point(1, 0.9))
        // Follow the book's clasp and the paws instead of cutting across them.
        path.addLine(to: point(0.75, 0.81))
        path.addQuadCurve(to: point(0.747, 0.763), control: point(0.753, 0.785))
        path.addQuadCurve(to: point(0.704, 0.738), control: point(0.738, 0.738))
        path.addQuadCurve(to: point(0.684, 0.694), control: point(0.702, 0.70))
        path.addQuadCurve(to: point(0.598, 0.693), control: point(0.646, 0.705))
        path.addLine(to: point(0.59, 0.669))
        path.addQuadCurve(to: point(0.485, 0.669), control: point(0.535, 0.688))
        path.addLine(to: point(0.485, 0.565))
        path.addQuadCurve(to: point(0.515, 0.43), control: point(0.53, 0.50))
        path.addQuadCurve(to: point(0.50, 0.27), control: point(0.50, 0.32))
        path.addQuadCurve(to: point(0.55, 0), control: point(0.51, 0.16))
        path.closeSubpath(); return path
    }
}

private struct ModelAPISettingsView: View {
    @ObservedObject var preferences: Preferences
    @State private var configuration = APIConfiguration()
    @State private var key = ""
    @State private var loaded = false
    @State private var testing = false
    @State private var testProgress: String?
    @State private var diagnostics: LLMDiagnostics?
    @State private var diagnosticsExpanded = false
    @State private var fetchingModels = false
    @State private var models: [APIModel] = []
    @State private var showModels = false
    @State private var message: String?
    @State private var isError = false
    @State private var operation: Task<Void, Never>?
    @State private var requestID = UUID()
    @State private var savedConfiguration = APIConfiguration()
    @State private var savedKey = ""
    @State private var hasSyncedChanges = false
    @State private var profileID: String?
    @State private var profileName = ""
    @State private var savedName = ""
    private enum ProfileAction { case select(String), createBlank, duplicate(String) }
    @State private var pendingProfileAction: ProfileAction?
    @State private var confirmSwitch = false
    @State private var confirmDelete = false
    @FocusState private var inputFocused: Bool

    private var isBusy: Bool { testing || fetchingModels }
    private var isDirty: Bool { configuration != savedConfiguration || key != savedKey || profileName != savedName }
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Menu {
                ForEach(preferences.profiles) { profile in
                    Button { requestProfileAction(.select(profile.id)) } label: {
                        if preferences.activeProfileID == profile.id { Label(profile.name, systemImage: "checkmark") }
                        else { Text(profile.name) }
                    }.accessibilityIdentifier("profile-\(profile.id)")
                }
                Divider()
                Button("新增空白接口", systemImage: "plus") { requestProfileAction(.createBlank) }
                    .accessibilityIdentifier("newAPIProfile")
                Button("复制当前接口", systemImage: "doc.on.doc") {
                    if let profileID { requestProfileAction(.duplicate(profileID)) }
                }.disabled(profileID == nil).accessibilityIdentifier("duplicateAPIProfile")
            } label: {
                HStack {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("选择接口").font(.caption).foregroundStyle(Notebook.secondaryInk)
                        Text(profileID == nil ? "新接口" : (preferences.activeProfile?.name ?? "新接口"))
                    }
                    Spacer(); Image(systemName: "chevron.up.chevron.down")
                }.padding(.vertical, 5).contentShape(Rectangle())
            }.disabled(isBusy).accessibilityIdentifier("apiProfiles")
            if hasSyncedChanges {
                Text("iCloud 中的配置有更新，当前未保存的输入已保留。").font(.caption).foregroundStyle(Notebook.secondaryInk)
                Button("载入已同步配置") { loadSavedConfiguration() }.font(.subheadline)
            }
            fieldLabel("接口名称")
            TextField("例如：日常使用、备用接口", text: $profileName).accessibilityIdentifier("apiProfileName").focused($inputFocused)
            fieldLabel("API 格式")
            Picker("API 格式", selection: $configuration.format) {
                ForEach(APIFormat.allCases) { Text($0.title).tag($0) }
            }.pickerStyle(.segmented).accessibilityIdentifier("apiFormat")
            Text("每个接口独立保存地址、Key 和模型，支持自定义服务地址。").font(.caption).foregroundStyle(Notebook.secondaryInk)
            fieldLabel("接口地址")
            TextField("https://api.example.com/v1", text: $configuration.baseURL)
                .keyboardType(.URL).textContentType(.URL).accessibilityIdentifier("apiURL").focused($inputFocused)
            Divider()
            fieldLabel("API Key")
            SecureField("填写你的 API Key", text: $key).accessibilityIdentifier("apiKey").focused($inputFocused)
            Text(preferences.iCloudEnabled ? "Key 使用 iCloud 钥匙串同步。" : "Key 保存在此设备的钥匙串中。")
                .font(.caption).foregroundStyle(Notebook.secondaryInk)
            Divider()
            Button {
                inputFocused = false
                if fetchingModels { invalidateRequest() } else { fetchModels() }
            } label: {
                HStack {
                    if fetchingModels { ProgressView() } else { Image(systemName: "arrow.clockwise") }
                    Text(fetchingModels ? "取消获取" : (models.isEmpty ? "获取可用模型" : "刷新模型列表"))
                }
            }.buttonStyle(InkButtonStyle(prominent: false)).disabled(testing).accessibilityIdentifier("fetchModels")
            if !models.isEmpty {
                Button { inputFocused = false; showModels = true } label: {
                    HStack {
                        Text("从 \(models.count) 个模型中选择").multilineTextAlignment(.leading)
                        Spacer(); Image(systemName: "chevron.right")
                    }.padding(.vertical, 8)
                }.accessibilityIdentifier("chooseModel")
            }
            fieldLabel("当前模型 / 自定义 ID")
            TextField("选择模型，或直接输入模型 ID", text: $configuration.model)
                .accessibilityIdentifier("modelName").focused($inputFocused)
            Text("列表由当前接口和 Key 决定；请选支持文字对话的模型。服务未提供列表时，也可直接填写 ID。").font(.caption).foregroundStyle(Notebook.secondaryInk)
            Button("保存配置") {
                inputFocused = false
                do {
                    try preferences.saveProfile(id: profileID, name: profileName, configuration: configuration, key: key)
                    profileID = preferences.activeProfileID
                    savedConfiguration = configuration; savedKey = key; savedName = profileName; hasSyncedChanges = false
                    isError = false; message = "配置已保存。"
                } catch { isError = true; message = error.localizedDescription }
            }.buttonStyle(InkButtonStyle()).disabled(isBusy).accessibilityIdentifier("saveAPI")
            Button {
                inputFocused = false
                if testing { operation?.cancel() } else { testConnection() }
            } label: {
                HStack { if testing { ProgressView() }; Text(testing ? "取消测试" : "测试连接") }
            }.buttonStyle(InkButtonStyle(prominent: false)).disabled(fetchingModels).accessibilityIdentifier("testAPI")
            Text("测试连接会发送一条示例日程，可能产生少量调用费用。")
                .font(.caption).foregroundStyle(Notebook.secondaryInk)
            if testing, let testProgress { Text(testProgress).font(.caption).foregroundStyle(Notebook.secondaryInk) }
            if let message { NoteMessage(text: message, isError: isError).accessibilityIdentifier("apiStatus") }
            if let diagnostics {
                VStack(alignment: .leading, spacing: 10) {
                    Button { diagnosticsExpanded.toggle() } label: {
                        HStack {
                            Text("请求诊断")
                            Spacer()
                            Image(systemName: diagnosticsExpanded ? "chevron.down" : "chevron.right")
                        }.frame(minHeight: 44).contentShape(Rectangle())
                    }.buttonStyle(.plain).accessibilityIdentifier("apiDiagnostics")
                        .accessibilityValue(diagnosticsExpanded ? "已展开" : "已收起")
                    if diagnosticsExpanded {
                        Text(diagnostics.text).font(.caption).textSelection(.enabled)
                            .fixedSize(horizontal: false, vertical: true)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        Button { UIPasteboard.general.string = diagnostics.text } label: {
                            Text("复制诊断").frame(maxWidth: .infinity, minHeight: 44, alignment: .leading).contentShape(Rectangle())
                        }.buttonStyle(.plain).accessibilityIdentifier("copyAPIDiagnostics")
                    }
                }.font(.subheadline)
            }
            if profileID != nil {
                Button("删除此接口", role: .destructive) { confirmDelete = true }
                    .font(.subheadline).disabled(isBusy).accessibilityIdentifier("deleteAPIProfile")
            }
        }.textInputAutocapitalization(.never).autocorrectionDisabled()
            .toolbar { ToolbarItemGroup(placement: .keyboard) { Spacer(); Button("收起键盘") { inputFocused = false } } }
            .onAppear {
                guard !loaded else { return }
                loadSavedConfiguration()
                loaded = true
            }
            .onChange(of: preferences.syncRevision) { _, _ in
                if !isDirty && !isBusy { loadSavedConfiguration() }
                else { hasSyncedChanges = true }
            }
            .onChange(of: configuration.baseURL) { _, _ in invalidateModels() }
            .onChange(of: key) { _, _ in invalidateModels() }
            .onChange(of: configuration.format) { _, _ in invalidateModels() }
            .onChange(of: configuration.model) { _, _ in if testing { invalidateRequest() } }

            .sheet(isPresented: $showModels) {
                ModelSelectionView(models: models, selection: $configuration.model).presentationDetents([.large])
            }
            .confirmationDialog("当前输入尚未保存，继续将放弃这些修改？", isPresented: $confirmSwitch, titleVisibility: .visible) {
                Button("放弃修改并继续", role: .destructive) {
                    if let action = pendingProfileAction { performProfileAction(action) }
                }
                Button("继续编辑", role: .cancel) {}
            }
            .confirmationDialog("删除此接口配置？", isPresented: $confirmDelete, titleVisibility: .visible) {
                Button("删除接口", role: .destructive) {
                    if let profileID { preferences.deleteProfile(profileID); loadSavedConfiguration() }
                }
                Button("取消", role: .cancel) {}
            }
    }
    private func fieldLabel(_ text: String) -> some View { Text(text).font(.caption.weight(.medium)).foregroundStyle(Notebook.secondaryInk) }
    private func loadSavedConfiguration() {
        profileID = preferences.activeProfile?.id
        profileName = preferences.activeProfile?.name ?? ""; savedName = profileName
        configuration = preferences.configuration; savedConfiguration = configuration
        key = ""; savedKey = ""
        do { key = try preferences.activeProfile.map { try preferences.profileKey($0) } ?? ""; savedKey = key; hasSyncedChanges = false }
        catch { message = error.localizedDescription; isError = true }
    }
    private func requestProfileAction(_ action: ProfileAction) {
        inputFocused = false
        if isDirty { pendingProfileAction = action; confirmSwitch = true }
        else { performProfileAction(action) }
    }
    private func performProfileAction(_ action: ProfileAction) {
        invalidateModels()
        do {
            switch action {
            case .select(let id): preferences.selectProfile(id)
            case .createBlank: try preferences.createBlankProfile()
            case .duplicate(let id): try preferences.duplicateProfile(id)
            }
            loadSavedConfiguration()
        } catch { message = error.localizedDescription; isError = true }
        pendingProfileAction = nil
    }
    private func invalidateRequest() {
        requestID = UUID(); operation?.cancel(); testing = false; fetchingModels = false
    }
    private func invalidateModels() {
        invalidateRequest(); models = []; showModels = false; message = nil; diagnostics = nil; testProgress = nil
    }
    private func fetchModels() {
        let id = UUID(); requestID = id
        fetchingModels = true; message = nil
        let config = configuration; let currentKey = key
        operation = ModelJobCenter.shared.start(id: id, kind: .models, work: { context in
                let result: [APIModel]
                #if DEBUG
                if AppIdentity.isUITesting && ProcessInfo.processInfo.arguments.contains("-model-list-fixture") {
                    try await Task.sleep(for: .milliseconds(200))
                    result = [APIModel(id: "test-chat-alpha", ownedBy: "测试服务"), APIModel(id: "test-chat-beta", ownedBy: "测试服务")]
                } else { result = try await LLMClient().listModels(configuration: config, apiKey: currentKey, observer: context.observer()) }
                #else
                result = try await LLMClient().listModels(configuration: config, apiKey: currentKey, observer: context.observer())
                #endif
                return .models(result)
        }, completion: { result in
            guard requestID == id else { return }
            fetchingModels = false
            switch result {
            case .success(.models(let values)):
                models = values; isError = false
                message = values.isEmpty ? "接口未返回可用模型，可以直接填写自定义 ID。" : "已获取 \(values.count) 个模型，选择后记得保存配置。"
                showModels = !values.isEmpty
            case .failure(let error): if !(error is CancellationError) { message = error.localizedDescription; isError = true }
            default: break
            }
        })
    }
    private func testConnection() {
        let id = UUID(); requestID = id
        testing = true; message = nil; diagnostics = nil; diagnosticsExpanded = false; testProgress = "正在准备请求…"
        var currentConfig = configuration; var currentKey = key
        var client = LLMClient()
        #if DEBUG
        if AppIdentity.isUITesting && ProcessInfo.processInfo.arguments.contains("-api-stream-fixture") {
            currentConfig = APIConfiguration(baseURL: "https://fixture.invalid/v1", model: "stream-fixture")
            currentKey = "fixture-key"
            let config = URLSessionConfiguration.ephemeral; config.protocolClasses = [APIStreamUIFixture.self]
            client = LLMClient(session: URLSession(configuration: config))
        }
        #endif
        operation = ModelJobCenter.shared.start(id: id, kind: .connection, work: { context in
                let events = try await client.extract(text: "2026年12月15日下午2点到3点，在线测试会议。", referenceDate: .now,
                                                         timeZone: .current, configuration: currentConfig, apiKey: currentKey, observer: context.observer { update in
                    Task { @MainActor in
                        guard requestID == id else { return }
                        switch update {
                        case .progress(let progress): if testing { testProgress = progress.message }
                        case .diagnostics(let report): diagnostics = report
                        }
                    }
                })
                guard !events.isEmpty else { throw ShikeError.message("接口已连接，但未能提取示例日程，请检查模型是否适合此任务。") }
                return .connection("连接成功，模型已返回可读取的日程。")
        }, completion: { result in
            guard requestID == id else { return }
            testing = false
            switch result {
            case .success(.connection(let text)): message = text; isError = false
            case .failure(let error):
                message = error is CancellationError ? "已取消测试。" : error.localizedDescription
                isError = !(error is CancellationError)
            default: break
            }
        })
    }
}

private struct ModelSelectionView: View {
    @Environment(\.dismiss) private var dismiss
    let models: [APIModel]
    @Binding var selection: String
    @State private var query = ""
    private var filtered: [APIModel] {
        query.isEmpty ? models : models.filter { $0.id.localizedCaseInsensitiveContains(query) || ($0.ownedBy?.localizedCaseInsensitiveContains(query) ?? false) }
    }
    var body: some View {
        NavigationStack {
            List {
                Section {
                    Button("使用自定义模型 ID") { dismiss() }.accessibilityIdentifier("customModel")
                } footer: { Text("自定义 ID 可在设置中的“当前模型 / 自定义 ID”输入框填写。") }
                Section("可用模型 · \(models.count)") {
                    ForEach(filtered) { model in
                        Button {
                            selection = model.id; dismiss()
                        } label: {
                            HStack {
                                VStack(alignment: .leading, spacing: 5) {
                                    Text(model.id).foregroundStyle(Notebook.ink).textSelection(.disabled)
                                    if let owner = model.ownedBy, !owner.isEmpty { Text(owner).font(.caption).foregroundStyle(Notebook.secondaryInk) }
                                }
                                Spacer()
                                if selection == model.id { Image(systemName: "checkmark").foregroundStyle(Notebook.accent) }
                            }.padding(.vertical, 5)
                        }.accessibilityIdentifier("model-\(model.id)")
                    }
                    if filtered.isEmpty { Text("没有匹配的模型，试试其他关键词。") }
                }
            }.searchable(text: $query, prompt: "搜索模型名称或提供方")
                .scrollContentBackground(.hidden).background(PaperBackground())
                .navigationTitle("选择模型").navigationBarTitleDisplayMode(.inline)
                .toolbar { ToolbarItem(placement: .cancellationAction) { Button("完成") { dismiss() } } }
        }.tint(Notebook.accent)
    }
}

#if DEBUG
/// Exercises the real incremental transport in UI tests without contacting a provider.
private final class APIStreamUIFixture: URLProtocol {
    private var work: Task<Void, Never>?
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: ["Content-Type": "text/event-stream"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        work = Task {
            do {
                client?.urlProtocol(self, didLoad: Data(": heartbeat\n\n".utf8))
                try await Task.sleep(for: .seconds(2))
                let content = #"{"events":[{"title":"连接测试","start":"2026-12-15T14:00:00+08:00","end":"2026-12-15T15:00:00+08:00"}]}"#
                let envelope = try JSONSerialization.data(withJSONObject: ["choices": [["delta": ["content": content], "finish_reason": "stop"]]])
                var bytes = Data("data: ".utf8); bytes.append(envelope); bytes.append(Data("\n\ndata: [DONE]\n\n".utf8))
                try Task.checkCancellation()
                client?.urlProtocol(self, didLoad: bytes)
                client?.urlProtocolDidFinishLoading(self)
            } catch { }
        }
    }
    override func stopLoading() { work?.cancel() }
}
#endif
