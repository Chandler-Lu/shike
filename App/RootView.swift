import SwiftUI
import PhotosUI
import AVFoundation
import ShikeCore

struct RootView: View {
    @Environment(\.scenePhase) private var scenePhase
    @ObservedObject var environment: AppEnvironment
    @StateObject private var controller: ImportController
    @StateObject private var countdownCoordinator: CountdownCoordinator
    @State private var selection = 0
    @StateObject private var quickImport = QuickImportRouter.shared
    @StateObject private var countdownNavigation = CountdownNavigation()

    init(environment: AppEnvironment) {
        self.environment = environment
        _countdownCoordinator = StateObject(wrappedValue: CountdownCoordinator(store: environment.countdowns, preferences: environment.preferences))
        let unfinished = (try? environment.store?.all())?.first { (!$0.text.isEmpty || !$0.pendingImages.isEmpty) && ($0.drafts.isEmpty || $0.savedCount < $0.drafts.count) }
        _controller = StateObject(wrappedValue: ImportController(environment: environment, session: unfinished ?? ImportSession()))
    }
    var body: some View {
        TabView(selection: $selection) {
            NavigationStack { HomeView(controller: controller) }
                .tabItem { Label("导入", systemImage: "square.and.pencil") }.tag(0)
            NavigationStack { CalendarScreen(calendars: environment.calendars, preferences: environment.preferences, countdowns: environment.countdowns, reminders: countdownCoordinator.reminders) }
                .tabItem { Label("日历", systemImage: "calendar") }.tag(3)
            NavigationStack { CountdownScreen(store: environment.countdowns, coordinator: countdownCoordinator, preferences: environment.preferences, navigation: countdownNavigation) }
                .tabItem { Label("倒数日", systemImage: "heart.text.clipboard") }.tag(4)
            NavigationStack { HistoryView(environment: environment) }
                .tabItem { Label("记录", systemImage: "book.closed") }.tag(1)
            NavigationStack { SettingsView(environment: environment, countdownSync: countdownCoordinator.sync) }
                .tabItem { Label("设置", systemImage: "slider.horizontal.3") }.tag(2)
        }.tint(Notebook.accent)
            .onOpenURL { url in
                guard CountdownRoute(url: url) != nil else { return }
                countdownNavigation.open(url); selection = 4
            }
            .onChange(of: quickImport.pending?.id) { _, id in if id != nil { selection = 0 } }
            .onAppear { if quickImport.pending != nil { selection = 0 }; countdownCoordinator.refresh(); environment.backups.start() }
            .onReceive(NotificationCenter.default.publisher(for: .shikeCloudPush)) { _ in countdownCoordinator.refresh() }
            .onReceive(NotificationCenter.default.publisher(for: .NSSystemTimeZoneDidChange)) { _ in countdownCoordinator.refresh() }
            .onReceive(NotificationCenter.default.publisher(for: .NSCalendarDayChanged)) { _ in countdownCoordinator.refresh() }
            .onReceive(Timer.publish(every: 60, on: .main, in: .common).autoconnect()) { _ in
                if scenePhase == .active { countdownCoordinator.sync.refresh() }
            }
            .onChange(of: scenePhase) { _, phase in
                if phase == .active { environment.refresh(); countdownCoordinator.refresh(); environment.backups.schedule() }
                if phase == .background && selection == 0 { controller.persistReportingError() }
                if phase == .background { environment.backups.schedule(immediately: true) }
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
}

struct HomeView: View {
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.scenePhase) private var scenePhase
    @StateObject private var quickImport = QuickImportRouter.shared
    @State private var quickImportError: String?
    @State private var quickImportFailed = false
    @ScaledMetric(relativeTo: .body) private var importHeight: CGFloat = 50
    @ObservedObject var controller: ImportController
    @State private var photos: [PhotosPickerItem] = []
    @State private var showCamera = false
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
                            Text("把零散安排，\n收进日历。").font(Notebook.handwriting(34, relativeTo: .largeTitle)).lineSpacing(3)
                            Text("一段文字，一张截图，一天井井有条。")
                                .font(.subheadline).foregroundStyle(Notebook.secondaryInk).fixedSize(horizontal: false, vertical: true)
                        }.frame(maxWidth: .infinity, alignment: .leading)
                        if !dynamicTypeSize.isAccessibilitySize { CalendarDoodle().padding(.top, 13) }
                    }.padding(.top, 5)

                    importLayout {
                        importTile {
                            PasteImportButton { providers in
                                loadProviders(providers)
                            }.frame(height: importHeight)
                        }
                        importTile {
                            PhotosPicker(selection: $photos, maxSelectionCount: 5, matching: .images) {
                                Label("相册", systemImage: "photo.on.rectangle.angled").frame(maxWidth: .infinity, minHeight: importHeight)
                            }.accessibilityIdentifier("choosePhotos")
                        }
                        importTile {
                            Button { Task { await openCamera() } } label: {
                                Label("拍照", systemImage: "camera").frame(maxWidth: .infinity, minHeight: importHeight)
                            }.accessibilityIdentifier("takePhoto")
                        }
                    }.font(.subheadline.weight(.medium)).disabled(controller.isBusy || isLoadingInput)

                    if isLoadingInput {
                        HStack { ProgressView("正在读取素材…"); Spacer(); Button("取消") { importTask?.cancel() } }
                    }
                    if let quickImportError { NoteMessage(text: quickImportError, isError: quickImportFailed) }

                    ImportFlowView(controller: controller, calendars: controller.environment.calendars,
                                   showsAPIProfilePicker: true, isLoadingInput: isLoadingInput)
                    if controller.session.text.isEmpty && controller.session.drafts.isEmpty {
                        HStack(alignment: .top, spacing: 10) {
                            Image(systemName: "square.and.arrow.up")
                            Text("也可以从其他 App 的分享菜单找到「拾刻计划」，直接整理成日程。")
                        }.font(.footnote).foregroundStyle(Notebook.secondaryInk).padding(.horizontal, 8)
                    }
                }.padding(.horizontal, 22).padding(.bottom, 32).frame(maxWidth: 680)
                    .frame(maxWidth: .infinity)
            }.scrollDismissesKeyboard(.interactively)
        }.foregroundStyle(Notebook.ink)
            .task(id: quickImport.pending?.id) {
                while quickImport.pending != nil && !Task.isCancelled {
                    processQuickImport()
                    if quickImport.pending == nil { break }
                    do { try await Task.sleep(for: .milliseconds(350)) } catch { return }
                }
            }
            .onChange(of: scenePhase) { _, phase in if phase == .active { processQuickImport() } }
            .onChange(of: controller.isBusy) { _, busy in if !busy { processQuickImport() } }
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
                        .accessibilityLabel("新建导入").disabled(controller.isBusy || isLoadingInput)
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
                    if ProcessInfo.processInfo.arguments.contains("-store-screenshots") {
                        controller.session.createdAt = ISO8601DateFormatter().date(from: "2026-10-13T09:41:00+08:00")!
                        controller.session.referenceTimeZone = "Asia/Shanghai"
                    }
                }
                #endif
            }
    }

    private var importLayout: AnyLayout {
        dynamicTypeSize.isAccessibilitySize ? AnyLayout(VStackLayout(spacing: 12)) : AnyLayout(HStackLayout(spacing: 12))
    }

    private func importTile<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        content().frame(maxWidth: .infinity).background(Notebook.paper)
            .overlay(PencilBorder().stroke(Notebook.ink.opacity(0.30), lineWidth: 1.1))
    }

    private func processQuickImport() {
        guard scenePhase == .active, !controller.isBusy, !isLoadingInput, !controller.showsPlanning,
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

    private func loadProviders(_ providers: [NSItemProvider]) {
        isLoadingInput = true
        importTask = Task {
            defer { isLoadingInput = false }
            do {
                let (text, images) = try await ItemLoader.load(providers)
                if images.isEmpty { controller.appendText(text, source: "剪贴板") }
                else { controller.importImageFiles(images, source: "剪贴板", appendedText: text) }
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

