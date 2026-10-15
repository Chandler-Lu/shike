import SwiftUI
import ShikeCore

struct HistoryView: View {
    @Environment(\.workspaceWidth) private var workspaceWidth
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @EnvironmentObject private var workspace: Workspace
    @State private var inlineSession: ImportSession?
    @State private var pushedSession: ImportSession?
    @State private var showingSession = false
    @FocusState private var searchFocused: Bool
    private var usesColumns: Bool { workspaceWidth >= 880 && !dynamicTypeSize.isAccessibilitySize }
    @Environment(\.scenePhase) private var scenePhase
    @ObservedObject var environment: AppEnvironment
    @State private var sessions: [ImportSession] = []
    @State private var errorMessage: String?
    @State private var deleting: ImportSession?
    @State private var query = ""

    private var filtered: [ImportSession] {
        query.isEmpty ? sessions : sessions.filter { $0.displayTitle.localizedCaseInsensitiveContains(query) || $0.text.localizedCaseInsensitiveContains(query) }
    }
    var body: some View {
        ZStack {
            PaperBackground()
            HStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    MarginTitle(title: "翻翻记录", subtitle: "保存的安排和没写完的草稿，都在这里。")
                    TextField("查找日程或原文", text: $query)
                        .textFieldStyle(.roundedBorder).focused($searchFocused).accessibilityIdentifier("historySearch")
                    if let errorMessage { NoteMessage(text: errorMessage, isError: true) }
                    if sessions.isEmpty {
                        VStack(spacing: 18) {
                            Image(systemName: "book.closed").font(.system(size: 44, weight: .ultraLight)).foregroundStyle(Notebook.accent)
                            Text("日子，一页一页记下来。").font(Notebook.handwriting(24))
                            Text("从一段文字或一张图片开始，\n导入记录会自动保存在这里。")
                                .font(.subheadline).foregroundStyle(Notebook.secondaryInk).multilineTextAlignment(.center)
                        }.frame(maxWidth: .infinity).padding(.vertical, 75)
                    }
                    ForEach(filtered) { session in
                        Button {
                            if usesColumns || inlineSession != nil { inlineSession = session }
                            else { pushedSession = session; showingSession = true }
                        } label: {
                            PaperCard {
                                VStack(alignment: .leading, spacing: 10) {
                                    HStack {
                                        Text(session.createdAt.formatted(.dateTime.month().day().hour().minute())).font(.caption).foregroundStyle(Notebook.secondaryInk)
                                        Spacer(); Text(session.source).font(.caption).foregroundStyle(Notebook.accent)
                                    }
                                    Text(session.displayTitle.isEmpty ? "未完成的导入" : session.displayTitle).font(Notebook.handwriting(23)).lineLimit(2)
                                    HStack {
                                        Text(session.drafts.isEmpty ? "原文待整理" : "\(session.drafts.count) 个日程，\(session.savedCount) 个已加入日历").font(.subheadline).foregroundStyle(Notebook.secondaryInk)
                                        Spacer(); Image(systemName: "chevron.right").font(.caption)
                                    }
                                }
                            }
                        }.buttonStyle(.plain)
                        .contextMenu { Button("删除导入记录", role: .destructive) { deleting = session } }
                    }
                    if !sessions.isEmpty && filtered.isEmpty { Text("没有找到匹配的记录。").foregroundStyle(Notebook.secondaryInk) }
                }.padding(22).frame(maxWidth: 680).frame(maxWidth: .infinity)
            }.refreshable { refresh() }
                .frame(maxWidth: inlineSession != nil && !usesColumns ? 0 : .infinity)
                .clipped().accessibilityHidden(inlineSession != nil && !usesColumns)
            if usesColumns || inlineSession != nil {
                Divider()
                ZStack {
                    if let inlineSession {
                        NavigationStack {
                            SessionDetailView(environment: environment, session: inlineSession)
                                .environment(\.workspaceWidth, 0)
                                .toolbar { ToolbarItem(placement: .cancellationAction) { Button("返回记录") { self.inlineSession = nil; refresh() } } }
                        }.id(inlineSession.id)
                    } else {
                        VStack(spacing: 18) {
                            Image(systemName: "book.closed").font(.system(size: 48, weight: .ultraLight)).foregroundStyle(Notebook.accent)
                            Text("选一页，接着写。 ").font(Notebook.handwriting(26))
                        }
                    }
                }.frame(maxWidth: .infinity, maxHeight: .infinity).accessibilityIdentifier("historyDetailPane")
            }
            }
        }.foregroundStyle(Notebook.ink)
            .navigationTitle("记录").navigationBarTitleDisplayMode(.inline)
            .navigationDestination(isPresented: $showingSession) {
                if let pushedSession { SessionDetailView(environment: environment, session: pushedSession) }
            }
            .onChange(of: workspace.pending?.id) { _, _ in processWorkspaceAction() }
            .onAppear { processWorkspaceAction() }
            .onAppear(perform: refresh)
            .onChange(of: scenePhase) { _, phase in if phase == .active { refresh() } }
            .confirmationDialog("删除这条导入记录？", isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } }), titleVisibility: .visible) {
                Button("删除记录", role: .destructive) {
                    if let session = deleting {
                        do {
                            if inlineSession?.id == session.id { inlineSession = nil }
                            try environment.store?.delete(session.id)
                            session.pendingImages.forEach(ImageStaging.remove)
                            refresh()
                        } catch { errorMessage = error.localizedDescription }
                    }
                    deleting = nil
                }
            } message: { Text("已加入系统日历的事件会保留。") }
    }
    private func processWorkspaceAction() {
        guard let request = workspace.pending, request.section == 1, request.action == .search else { return }
        workspace.consume(request.id); searchFocused = true
    }
    private func refresh() {
        do { sessions = try environment.store?.all() ?? []; errorMessage = nil }
        catch { errorMessage = error.localizedDescription }
    }
}

struct SessionDetailView: View {
    @StateObject private var controller: ImportController
    init(environment: AppEnvironment, session: ImportSession) {
        _controller = StateObject(wrappedValue: ImportController(environment: environment, session: session))
    }
    var body: some View {
        ZStack {
            PaperBackground()
            ScrollView {
                ImportFlowView(controller: controller, calendars: controller.environment.calendars)
                    .padding(22).frame(maxWidth: 680).frame(maxWidth: .infinity)
            }
        }.navigationTitle("这一页安排").navigationBarTitleDisplayMode(.inline)
            .onDisappear {
                // Deleting the selected record must not recreate it on pane dismissal.
                if (try? controller.environment.store?.all().contains { $0.id == controller.session.id }) == true {
                    controller.persistReportingError()
                }
            }
    }
}
