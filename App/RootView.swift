import SwiftUI
import PhotosUI
import AVFoundation
import UniformTypeIdentifiers
import ShikeCore

struct RootView: View {
    @Environment(\.scenePhase) private var scenePhase
    @ObservedObject var environment: AppEnvironment
    @StateObject private var controller: ImportController
    @StateObject private var countdownCoordinator: CountdownCoordinator
    @EnvironmentObject private var workspace: Workspace
    private var selection: Int { workspace.selection }
    @ObservedObject private var modelJobs: ModelJobCenter
    @State private var modelJobPresentation: ModelJobPresentation?
    @State private var hiddenModelBanner: String?
    @StateObject private var quickImport = QuickImportRouter.shared
    @StateObject private var countdownNavigation = CountdownNavigation()
    @StateObject private var shortcutInbox = ShortcutInbox.shared

    init(environment: AppEnvironment) {
        self.environment = environment
        _modelJobs = ObservedObject(wrappedValue: environment.modelJobs)
        environment.modelJobs.applySessions(to: environment.store)
        _countdownCoordinator = StateObject(wrappedValue: CountdownCoordinator(store: environment.countdowns, preferences: environment.preferences))
        let unfinished = (try? environment.store?.all())?.first { (!$0.text.isEmpty || !$0.pendingImages.isEmpty || $0.planning != nil) && ($0.drafts.isEmpty || $0.savedCount < $0.drafts.count) }
        _controller = StateObject(wrappedValue: ImportController(environment: environment, session: unfinished ?? ImportSession()))
    }
    var body: some View {
        GeometryReader { geometry in
            let showsSidebar = !PlatformSupport.usesSystemWorkspaceNavigation && geometry.size.width >= 820 && workspace.sidebarOverride != false
            VStack(spacing: 0) {
                modelJobBanner
                HStack(spacing: 0) {
                    if showsSidebar {
                        WorkspaceSidebar(workspace: workspace).frame(width: 220)
                    }
                    TabView(selection: $workspace.selection) {
                        NavigationStack { WorkspaceViewport { HomeView(controller: controller) } }
                            .tabItem { Label("计划", systemImage: "square.and.pencil") }.tag(0)
                        NavigationStack { WorkspaceViewport { CalendarScreen(calendars: environment.calendars, preferences: environment.preferences, countdowns: environment.countdowns, reminders: countdownCoordinator.reminders) } }
                            .tabItem { Label("日历", systemImage: "calendar") }.tag(3)
                        NavigationStack { WorkspaceViewport { CountdownScreen(store: environment.countdowns, coordinator: countdownCoordinator, preferences: environment.preferences, navigation: countdownNavigation) } }
                            .tabItem { Label("倒数日", systemImage: "heart.text.clipboard") }.tag(4)
                        NavigationStack { WorkspaceViewport { HistoryView(environment: environment) } }
                            .tabItem { Label("记录", systemImage: "book.closed") }.tag(1)
                        NavigationStack { WorkspaceViewport { SettingsView(environment: environment, countdownSync: countdownCoordinator.sync) } }
                            .tabItem { Label("设置", systemImage: "slider.horizontal.3") }.tag(2)
                    }.workspaceTabs(hidesLegacyBar: showsSidebar)
                }
                .overlay(alignment: .topLeading) {
                    if PlatformSupport.isMac && geometry.size.width >= 820 {
                        Button { workspace.sidebarOverride = !showsSidebar } label: { Image(systemName: "sidebar.left") }
                            .padding(8).accessibilityLabel("切换侧边栏")
                    }
                }
            }
        }.tint(Notebook.accent)
            .sheet(item: $modelJobPresentation, onDismiss: refreshCurrentSession) { presentation in
                switch presentation {
                case .list:
                    ModelJobListView(jobs: modelJobs, environment: environment, reminders: countdownCoordinator.reminders).workspaceSheet()
                case .result(let record):
                    ModelJobResultView(record: record, environment: environment, reminders: countdownCoordinator.reminders)
                        .workspaceSheet().onAppear { modelJobs.acknowledge(record.id) }
                }
            }
            .onChange(of: modelJobs.requestedID) { _, _ in routeModelJob() }
            .onAppear {
                modelJobs.applySessions(to: environment.store)
                routeModelJob()
            }
            .onOpenURL { url in
                guard CountdownRoute(url: url) != nil else { return }
                countdownNavigation.open(url); workspace.selection = 4
            }
            .onChange(of: quickImport.pending?.id) { _, id in if id != nil { workspace.selection = 0 } }
            .onReceive(NotificationCenter.default.publisher(for: .shikeSessionChanged)) { notification in
                if let ids = notification.userInfo?["deletedIDs"] as? Set<UUID> { controller.discardDeletedSession(ids) }
            }
            .onChange(of: shortcutInbox.pending?.id) { _, id in if id != nil { workspace.selection = 0 } }
            .onAppear { shortcutInbox.refresh(); if shortcutInbox.pending != nil { workspace.selection = 0 } }
            .onAppear { if quickImport.pending != nil { workspace.selection = 0 }; countdownCoordinator.refresh(); environment.backups.start() }
            .onReceive(NotificationCenter.default.publisher(for: .shikeCloudPush)) { _ in countdownCoordinator.refresh() }
            .onReceive(NotificationCenter.default.publisher(for: .NSSystemTimeZoneDidChange)) { _ in countdownCoordinator.refresh() }
            .onReceive(NotificationCenter.default.publisher(for: .NSCalendarDayChanged)) { _ in countdownCoordinator.refresh() }
            .onReceive(Timer.publish(every: 60, on: .main, in: .common).autoconnect()) { _ in
                if scenePhase == .active { countdownCoordinator.sync.refresh() }
            }
            .onChange(of: scenePhase) { _, phase in
                if phase == .active { modelJobs.applySessions(to: environment.store); refreshCurrentSession(); environment.refresh(); countdownCoordinator.refresh(); environment.backups.schedule(); environment.backups.checkCloudBackup(); shortcutInbox.refresh() }
                if (phase == .background || PlatformSupport.isMac && phase == .inactive) && selection == 0 { controller.persistReportingError() }
                if phase == .background || PlatformSupport.isMac && phase == .inactive { environment.backups.schedule(immediately: true) }
            }
            .onChange(of: selection) { old, new in
                if old == 0 { controller.persistReportingError() }
                if new == 0 && !controller.isBusy {
                    do {
                        let latest = try environment.store?.all().first { $0.id == controller.session.id }
                        controller.session = latest ?? ImportSession()
                    } catch { controller.errorMessage = error.localizedDescription }
                }
            }
    }
    @ViewBuilder private var modelJobBanner: some View {
        if !bannerRecords.isEmpty, hiddenModelBanner != bannerSignature {
            HStack {
                Image(systemName: "sparkles")
                Text(bannerRecords.contains(where: { $0.status == .completed }) ? "模型结果已就绪" : "模型正在处理，可稍后查看")
                Spacer(); Image(systemName: "chevron.right")
            }.font(.subheadline).padding(.horizontal, 22).frame(minHeight: 44)
                .padding(.vertical, 4).background(Notebook.paper).contentShape(Rectangle())
                .gesture(DragGesture(minimumDistance: 15).exclusively(before: TapGesture()).onEnded { value in
                    switch value {
                    case .first(let drag):
                        if drag.translation.width < -55 && abs(drag.translation.width) > abs(drag.translation.height) {
                            hiddenModelBanner = bannerSignature
                        }
                    case .second: openBannerResult()
                    }
                })
                .accessibilityElement(children: .combine).accessibilityAddTraits(.isButton)
                .accessibilityIdentifier("modelJobBanner")
                .accessibilityAction { openBannerResult() }
                .accessibilityAction(named: "隐藏提示") { hiddenModelBanner = bannerSignature }
                .zIndex(1)
        }
    }
    private func openBannerResult() {
        if let ready = bannerRecords.first(where: { $0.status == .completed }) {
            modelJobPresentation = .result(ready)
        } else { modelJobPresentation = .list }
    }
    private var bannerRecords: [ModelJobRecord] {
        modelJobs.records.filter { $0.status == .running || !$0.seen && $0.status == .completed }
    }
    private var bannerSignature: String {
        bannerRecords.map { $0.id.uuidString + $0.status.rawValue }.joined(separator: "|")
    }
    private func routeModelJob() {
        guard let id = modelJobs.requestedID else { return }
        if let record = modelJobs.record(id), record.status != .running {
            modelJobPresentation = .result(record)
            modelJobs.requestedID = nil
        } else { modelJobPresentation = .list }
    }
    private func refreshCurrentSession() {
        guard !controller.isBusy, controller.review == nil, !controller.showsPlanning else { return }
        do {
            if let latest = try environment.store?.all().first(where: { $0.id == controller.session.id }) { controller.session = latest }
        } catch { controller.errorMessage = error.localizedDescription }
    }
}

struct HomeView: View {
    @Environment(\.workspaceWidth) private var workspaceWidth
    @Environment(\.verticalSizeClass) private var verticalSizeClass
    @EnvironmentObject private var workspace: Workspace
    @State private var showFiles = false
    @State private var dropTargeted = false
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.scenePhase) private var scenePhase
    @StateObject private var quickImport = QuickImportRouter.shared
    @StateObject private var shortcutInbox = ShortcutInbox.shared
    @State private var quickImportError: String?
    @State private var quickImportFailed = false
    @ScaledMetric(relativeTo: .body) private var importHeight: CGFloat = 50
    @ObservedObject var controller: ImportController
    @State private var photos: [PhotosPickerItem] = []
    @State private var showCamera = false
    @StateObject private var voice = VoiceRecorder()
    @State private var voiceTask: Task<Void, Never>?
    @State private var voiceOriginalText = ""
    @State private var voiceSessionID: UUID?
    private var inputBusy: Bool { isLoadingInput || voice.busy }
    @State private var isLoadingInput = false
    @State private var importTask: Task<Void, Never>?
    @State private var showShareFixture = false

    var body: some View {
        ZStack {
            PaperBackground()
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    HStack(alignment: .top, spacing: 20) {
                        VStack(alignment: .leading, spacing: 10) {
                            Text("把零散安排，\n收进日历。").font(Notebook.handwriting(verticalSizeClass == .compact ? 26 : 34, relativeTo: .largeTitle)).lineSpacing(3)
                            Text("一段文字，一张截图，一天井井有条。")
                                .font(.subheadline).foregroundStyle(Notebook.secondaryInk).fixedSize(horizontal: false, vertical: true)
                        }.frame(maxWidth: .infinity, alignment: .leading)
                        if !dynamicTypeSize.isAccessibilitySize && workspaceWidth >= 360 && verticalSizeClass != .compact { CalendarDoodle().padding(.top, 13) }
                    }.padding(.top, 5)

                    importLayout {
                        importTile {
                            if PlatformSupport.isMac {
                                Button { loadProviders(UIPasteboard.general.itemProviders) } label: {
                                    Label("粘贴", systemImage: "doc.on.clipboard").frame(maxWidth: .infinity, minHeight: importHeight)
                                }.accessibilityIdentifier("pasteImport")
                            } else {
                                PasteImportButton { providers in
                                    loadProviders(providers)
                                }.frame(height: importHeight)
                            }
                        }
                        importTile {
                            PhotosPicker(selection: $photos, maxSelectionCount: 5, matching: .images) {
                                Label("相册", systemImage: "photo.on.rectangle.angled").frame(maxWidth: .infinity, minHeight: importHeight)
                            }.accessibilityIdentifier("choosePhotos")
                        }
                        importTile {
                            if PlatformSupport.isMac {
                                Button { showFiles = true } label: {
                                    Label("文件", systemImage: "folder").frame(maxWidth: .infinity, minHeight: importHeight)
                                }.accessibilityIdentifier("chooseFiles")
                            } else {
                                Button { Task { await openCamera() } } label: {
                                    Label("拍照", systemImage: "camera").frame(maxWidth: .infinity, minHeight: importHeight)
                                }.accessibilityIdentifier("takePhoto")
                            }
                        }
                    }.font(.subheadline.weight(.medium)).disabled(controller.isBusy || inputBusy)

                    if isLoadingInput {
                        HStack { ProgressView("正在读取素材…"); Spacer(); Button("取消") { importTask?.cancel() } }
                    }
                    if let quickImportError { NoteMessage(text: quickImportError, isError: quickImportFailed) }
                    if let error = shortcutInbox.error { NoteMessage(text: error, isError: true) }
                    if let error = voice.error { NoteMessage(text: error, isError: true) }

                    ImportFlowView(controller: controller, calendars: controller.environment.calendars,
                                   showsAPIProfilePicker: true, isLoadingInput: inputBusy,
                                   onVoiceInput: toggleVoiceInput, voiceRecording: voice.recording,
                                   voicePreparing: voice.preparing, voiceFinishing: voice.finishing,
                                   voiceInputEnabled: !controller.isBusy && !isLoadingInput && controller.session.savedCount == 0)
                }.padding(.horizontal, 22).padding(.bottom, 32).frame(maxWidth: WorkspaceLayout.usesColumns(width: workspaceWidth, dynamicTypeSize: dynamicTypeSize) ? 1200 : 680)
                    .frame(maxWidth: .infinity)
            }.scrollDismissesKeyboard(.interactively)
        }.foregroundStyle(Notebook.ink)
            .overlay { if dropTargeted { RoundedRectangle(cornerRadius: 20).strokeBorder(Notebook.accent, style: StrokeStyle(lineWidth: 3, dash: [8])).padding(8).allowsHitTesting(false) } }
            .onDrop(of: [.fileURL, .image, .plainText], isTargeted: $dropTargeted) { providers in
                guard !controller.isBusy, !inputBusy else { return false }
                loadProviders(providers, source: "拖入素材"); return true
            }
            .fileImporter(isPresented: $showFiles, allowedContentTypes: [.image, .plainText], allowsMultipleSelection: true) { result in
                switch result {
                case .success(let urls): loadFiles(urls)
                case .failure(let error): controller.errorMessage = error.localizedDescription
                }
            }
            .task(id: workspace.pending?.id) {
                while workspace.pending?.section == 0 && !Task.isCancelled {
                    processWorkspaceAction()
                    if workspace.pending == nil { break }
                    do { try await Task.sleep(for: .milliseconds(350)) } catch { return }
                }
            }
            .task(id: quickImport.pending?.id) {
                while quickImport.pending != nil && !Task.isCancelled {
                    processQuickImport()
                    if quickImport.pending == nil { break }
                    do { try await Task.sleep(for: .milliseconds(350)) } catch { return }
                }
            }
            .task(id: "\(shortcutInbox.pending?.id.uuidString ?? "")|\(scenePhase == .active)") {
                while scenePhase == .active && shortcutInbox.pending != nil && !Task.isCancelled {
                    if processShortcutInput() { break }
                    do { try await Task.sleep(for: .milliseconds(350)) } catch { return }
                }
            }
            .onChange(of: scenePhase) { _, phase in
                if phase == .active { processQuickImport() }
                else if phase == .background { voiceTask?.cancel(); applyVoiceTranscript(); voice.cancel(); voiceSessionID = nil }
                else if voice.recording { voice.stop() }
            }
            .onChange(of: voice.text) { _, _ in applyVoiceTranscript() }
            .onChange(of: voice.busy) { _, busy in
                if !busy {
                    applyVoiceTranscript(); controller.persistReportingError()
                    voiceSessionID = nil
                    processQuickImport(); processWorkspaceAction()
                }
            }
            .onDisappear { voiceTask?.cancel(); applyVoiceTranscript(); voice.cancel(); voiceSessionID = nil }
            .onChange(of: controller.session.id) { _, id in
                if let voiceSessionID, voiceSessionID != id { voiceTask?.cancel(); voice.cancel(); self.voiceSessionID = nil }
            }
            .onChange(of: controller.isBusy) { _, busy in if !busy { processQuickImport(); processWorkspaceAction() } }
            .onChange(of: controller.showsPlanning) { _, showing in if !showing { processQuickImport() } }
            .onAppear { processQuickImport() }
            .navigationTitle("拾刻计划").navigationBarTitleDisplayMode(.inline)
            .toolbar {
                #if DEBUG
                if ProcessInfo.processInfo.arguments.contains("-share-fixture") {
                    ToolbarItem(placement: .topBarLeading) {
                        Button("分享测试图片") { showShareFixture = true }.accessibilityIdentifier("shareFixture")
                    }
                }
                #endif
                ToolbarItem(placement: .topBarTrailing) {
                    Button { controller.startNew() } label: { Image(systemName: "plus") }
                        .accessibilityLabel("新建导入").disabled(controller.isBusy || inputBusy)
                }
            }
            .sheet(isPresented: $showCamera) {
                CameraPicker { data in controller.importImages([data], source: "拍照") }.ignoresSafeArea()
            }
            .sheet(isPresented: $showShareFixture) {
                #if DEBUG
                ShareFixtureSheet()
                #endif
            }
            .onChange(of: photos) { _, items in
                guard !items.isEmpty else { return }
                isLoadingInput = true
                importTask = Task {
                    defer { isLoadingInput = false; photos = [] }
                    var files: [String] = []
                    do {
                        for item in items {
                            guard let image = try await item.loadTransferable(type: Data.self) else { throw ShikeError.message("图片未能下载，请检查网络后重试。") }
                            guard image.count <= 30_000_000 else { throw ShikeError.message("单张图片超过 30 MB，请裁剪后导入。") }
                            files.append(try ImageStaging.write(image))
                        }
                        controller.importImageFiles(files, source: "相册")
                    } catch {
                        files.forEach(ImageStaging.remove)
                        controller.errorMessage = error.localizedDescription
                    }
                }
            }
            .onAppear {
                #if DEBUG
                if AppIdentity.isUITesting && ProcessInfo.processInfo.arguments.contains("-seed-example") && controller.session.text.isEmpty {
                    controller.session.text = "明天下午两点到三点半，产品设计评审，三楼会议室。带上新的交互稿。\n\n后天上午十点和小林在街角咖啡馆喝咖啡。"
                    if ProcessInfo.processInfo.arguments.contains("-planning-fixture") { controller.session.text = "这周想读完一本书，帮我找个安静的时间。" }
                    if ProcessInfo.processInfo.arguments.contains("-promotion-search-fixture") {
                        controller.session.text = "明天去北京玩一天，上午逛故宫，下午留点时间散步，帮我安排。"
                    }
                    if ProcessInfo.processInfo.arguments.contains("-store-screenshots") {
                        controller.session.createdAt = ISO8601DateFormatter().date(from: "2026-10-13T09:41:00+08:00")!
                        controller.session.referenceTimeZone = "Asia/Shanghai"
                    }
                }
                #endif
            }
    }

    private var importLayout: AnyLayout {
        dynamicTypeSize.isAccessibilitySize || workspaceWidth < 340 ? AnyLayout(VStackLayout(spacing: 12)) : AnyLayout(HStackLayout(spacing: 12))
    }

    private func toggleVoiceInput() {
        if voice.recording { voice.stop(); return }
        guard !voice.busy, !controller.isBusy, !isLoadingInput, controller.session.savedCount == 0 else { return }
        voiceOriginalText = controller.session.text
        voiceSessionID = controller.session.id
        voiceTask = Task { await voice.start() }
    }

    private func applyVoiceTranscript() {
        guard voiceSessionID == controller.session.id, !voice.text.isEmpty else { return }
        controller.session.text = voiceOriginalText + (voiceOriginalText.isEmpty ? "" : "\n\n") + voice.text
        controller.session.source = "语音录入"
    }

    private func importTile<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        content().frame(maxWidth: .infinity).background(Notebook.paper)
            .overlay(PencilBorder().stroke(Notebook.ink.opacity(0.30), lineWidth: 1.1))
    }

    private func processQuickImport() {
        guard scenePhase == .active, !controller.isBusy, !inputBusy, !controller.showsPlanning,
              controller.review == nil, controller.consentRequest == nil, let request = quickImport.pending else { return }
        // Existing sheets retain uncommitted edits; defer until the home page is visible again.
        if let scene = UIApplication.shared.connectedScenes.first as? UIWindowScene,
           scene.windows.first(where: \.isKeyWindow)?.rootViewController?.presentedViewController != nil { return }
        quickImport.consume(request.id)
        isLoadingInput = true; quickImportError = nil; quickImportFailed = false
        importTask = Task {
            defer { isLoadingInput = false }
            do {
                let text: String
                let files: [String]
                var limited = false
                switch request.action {
                case .clipboard:
                    (text, files) = try await ItemLoader.load(UIPasteboard.general.itemProviders)
                case .latestPhoto:
                    let result = try await LatestPhotoImporter.load()
                    try Task.checkCancellation()
                    text = ""; files = [try ImageStaging.write(result.0)]; limited = result.1
                }
                do {
                    try Task.checkCancellation()
                    try controller.persist()
                } catch { files.forEach(ImageStaging.remove); throw error }
                controller.session = ImportSession(source: request.action == .clipboard ? "桌面剪贴板" : (limited ? "已授权最新图片" : "最近图片"))
                if files.isEmpty { controller.appendText(text, source: controller.session.source) }
                else { controller.importImageFiles(files, source: controller.session.source, appendedText: text) }
                if limited { quickImportError = "已导入授权范围内的最新图片。需要其他图片时，可点击相册手动选择。" }
            } catch is CancellationError { quickImportError = "已取消导入，原来的内容已保留。" }
            catch { quickImportError = error.localizedDescription; quickImportFailed = true }
        }
    }

    /// Persist before acknowledging. Replaying a request after a crash uses the same session ID.
    private func processShortcutInput() -> Bool {
        guard scenePhase == .active, !controller.isBusy, !inputBusy, !controller.showsPlanning,
              controller.review == nil, controller.consentRequest == nil, let request = shortcutInbox.pending else { return false }
        if let scene = UIApplication.shared.connectedScenes.first as? UIWindowScene,
           scene.windows.first(where: \.isKeyWindow)?.rootViewController?.presentedViewController != nil { return false }
        do {
            try controller.persist()
            let previous = try controller.environment.store?.all().first { $0.id == request.id }
            var session = previous ?? ImportSession(source: request.source)
            session.id = request.id
            if previous == nil { session.text = request.text; session.createdAt = request.createdAt; session.pendingImages = request.images ?? [] }
            controller.session = session
            try controller.persist()
            try shortcutInbox.consume(request.id)
            if !session.pendingImages.isEmpty {
                // The durable session owns the staged images before the queue item is acknowledged.
                controller.resumeImages(parseAfterRecognition: true)
            } else if !session.hasParsed { controller.parse() }
        } catch { controller.errorMessage = "捷径导入失败，内容仍已保留：" + error.localizedDescription }
        return true
    }

    private func loadProviders(_ providers: [NSItemProvider], source: String = "剪贴板") {
        guard !controller.isBusy, !inputBusy else { return }
        isLoadingInput = true
        importTask = Task {
            defer { isLoadingInput = false }
            do {
                let (text, images) = try await ItemLoader.load(providers)
                if images.isEmpty { controller.appendText(text, source: source) }
                else { controller.importImageFiles(images, source: source, appendedText: text) }
            } catch { controller.errorMessage = error.localizedDescription }
        }
    }

    private func processWorkspaceAction() {
        guard let request = workspace.pending, request.section == 0, workspace.selection == 0,
              !controller.isBusy, !inputBusy, !controller.showsPlanning,
              controller.review == nil, controller.consentRequest == nil else { return }
        // A command must never replace an editor presented above the workspace.
        if let scene = UIApplication.shared.connectedScenes.first as? UIWindowScene,
           scene.windows.first(where: \.isKeyWindow)?.rootViewController?.presentedViewController != nil { return }
        workspace.consume(request.id)
        switch request.action {
        case .new: controller.startNew()
        case .files: showFiles = true
        case .paste: loadProviders(UIPasteboard.general.itemProviders)
        case .search: break
        }
    }

    private func loadFiles(_ urls: [URL]) {
        guard !controller.isBusy, !inputBusy else { return }
        isLoadingInput = true
        importTask = Task {
            defer { isLoadingInput = false }
            do {
                let (text, images) = try await ItemLoader.loadFiles(urls)
                if images.isEmpty { controller.appendText(text, source: "文件") }
                else { controller.importImageFiles(images, source: "文件", appendedText: text) }
            } catch { controller.errorMessage = error.localizedDescription }
        }
    }

    private func openCamera() async {
        guard UIImagePickerController.isSourceTypeAvailable(.camera) else {
            controller.errorMessage = "当前设备没有可用相机。模拟器中请使用相册或剪贴板图片。"; return
        }
        let status = AVCaptureDevice.authorizationStatus(for: .video)
        var allowed = status == .authorized
        if status == .notDetermined { allowed = await AVCaptureDevice.requestAccess(for: .video) }
        if allowed { showCamera = true }
        else { controller.errorMessage = "相机权限未开启，请到系统设置 → App → 拾刻计划 → 相机中允许访问。" }
    }
}

