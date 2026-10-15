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
    @State private var query = ""
    @State private var searchExpanded = false
    @State private var restingScrollTop: CGFloat?
    @State private var selecting = false
    @State private var selectedIDs: Set<UUID> = []
    @State private var pendingDeletion: Set<UUID> = []
    @State private var deleteRequested = false

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
                    if searchExpanded { searchBar }
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
                            if selecting { toggleSelection(session.id) }
                            else if usesColumns || inlineSession != nil { inlineSession = session }
                            else { pushedSession = session; showingSession = true }
                        } label: {
                            PaperCard {
                                HStack(alignment: .top, spacing: 12) {
                                    if selecting {
                                        Image(systemName: selectedIDs.contains(session.id) ? "checkmark.circle.fill" : "circle")
                                            .font(.title3).foregroundStyle(Notebook.accent).accessibilityHidden(true)
                                    }
                                    VStack(alignment: .leading, spacing: 10) {
                                        HStack {
                                            Text(session.createdAt.formatted(.dateTime.month().day().hour().minute())).font(.caption).foregroundStyle(Notebook.secondaryInk)
                                            Spacer(); Text(session.source).font(.caption).foregroundStyle(Notebook.accent)
                                        }
                                        Text(session.displayTitle.isEmpty ? "未完成的导入" : session.displayTitle).font(Notebook.handwriting(23)).lineLimit(2)
                                        HStack {
                                            Text(session.drafts.isEmpty ? "原文待整理" : "\(session.drafts.count) 个日程，\(session.savedCount) 个已加入日历").font(.subheadline).foregroundStyle(Notebook.secondaryInk)
                                            Spacer()
                                            if !selecting { Image(systemName: "chevron.right").font(.caption) }
                                        }
                                    }.frame(maxWidth: .infinity, alignment: .leading)
                                }
                            }
                        }.buttonStyle(HoldActionButtonStyle(holdLabel: "批量选择") { beginSelection(session.id) })
                            .accessibilityIdentifier("history-\(session.id)")
                            .accessibilityValue(selecting ? (selectedIDs.contains(session.id) ? "已选择" : "未选择") : "")
                            .accessibilityAddTraits(selectedIDs.contains(session.id) ? .isSelected : [])
                            .accessibilityHint(selecting ? "轻点切换选择" : "轻点查看，长按批量选择")
                    }
                    if !sessions.isEmpty && filtered.isEmpty { Text("没有找到匹配的记录。").foregroundStyle(Notebook.secondaryInk) }
                }.padding(22).frame(maxWidth: 680).frame(maxWidth: .infinity)
                    .onGeometryChange(for: CGFloat.self) { geometry in
                        geometry.frame(in: .named("historyViewport")).minY
                    } action: { top in
                        guard let restingScrollTop else { self.restingScrollTop = top; return }
                        if !searchExpanded && top > restingScrollTop + 55 { searchExpanded = true }
                    }
            }.scrollBounceBehavior(.always).scrollDismissesKeyboard(.interactively)
                .accessibilityIdentifier("historyList")
                .accessibilityAction(named: "展开搜索") { searchExpanded = true; searchFocused = true }
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
        }.coordinateSpace(name: "historyViewport").foregroundStyle(Notebook.ink)
            .navigationTitle("记录").navigationBarTitleDisplayMode(.inline)
            .safeAreaInset(edge: .bottom, spacing: 0) { if selecting { selectionBar } }
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    if selecting { Button("完成") { endSelection() }.accessibilityIdentifier("finishHistorySelection") }
                }
                ToolbarItem(placement: .primaryAction) {
                    if PlatformSupport.isMac {
                        Button { searchExpanded = true; searchFocused = true } label: { Image(systemName: "magnifyingglass") }.accessibilityLabel("搜索记录")
                    }
                }
            }
            .navigationDestination(isPresented: $showingSession) {
                if let pushedSession { SessionDetailView(environment: environment, session: pushedSession) }
            }
            .onChange(of: workspace.pending?.id) { _, _ in processWorkspaceAction() }
            .onAppear { processWorkspaceAction() }
            .onAppear(perform: refresh)
            .onReceive(NotificationCenter.default.publisher(for: .shikeSessionChanged)) { _ in refresh() }
            .onChange(of: query) { _, _ in selectedIDs.formIntersection(filtered.map(\.id)) }
            .onDisappear { endSelection() }
            .onChange(of: scenePhase) { _, phase in if phase == .active { refresh() } }
            .alert("删除这 \(pendingDeletion.count) 条记录？", isPresented: $deleteRequested) {
                Button("删除", role: .destructive) { deleteSelection() }.accessibilityIdentifier("confirmDeleteHistory")
                Button("取消", role: .cancel) { pendingDeletion = [] }
            } message: { Text("已加入系统日历的事件会保留。") }
    }
    private var searchBar: some View {
        HStack(spacing: 10) {
            HStack(spacing: 10) {
                Image(systemName: "magnifyingglass").foregroundStyle(Notebook.secondaryInk)
                TextField("查找日程或原文", text: $query).focused($searchFocused).accessibilityIdentifier("historySearch")
                if !query.isEmpty { Button { query = "" } label: { Image(systemName: "xmark.circle.fill") }.accessibilityLabel("清除搜索") }
            }.padding(14).background(Notebook.ink.opacity(0.05), in: RoundedRectangle(cornerRadius: 13))
            Button("取消") { query = ""; searchFocused = false; searchExpanded = false }
                .frame(minHeight: 44).accessibilityIdentifier("closeHistorySearch")
        }
    }
    private var selectionBar: some View {
        VStack(spacing: 8) {
            HStack {
                Text("已选择 \(selectedIDs.count) 条记录").font(.subheadline).accessibilityIdentifier("historySelectionCount")
                Spacer()
                Button(selectedIDs.count == filtered.count && !filtered.isEmpty ? "取消全选" : "全选") {
                    selectedIDs = selectedIDs.count == filtered.count ? [] : Set(filtered.map(\.id))
                }.frame(minHeight: 36).accessibilityIdentifier("selectAllHistory")
            }
            Button(role: .destructive) { pendingDeletion = selectedIDs; deleteRequested = true } label: {
                Label("删除", systemImage: "trash").frame(maxWidth: .infinity, minHeight: 44)
            }.disabled(selectedIDs.isEmpty).accessibilityIdentifier("deleteSelectedHistory")
        }.padding(.horizontal, 22).padding(.vertical, 8).frame(maxWidth: 680)
            .frame(maxWidth: .infinity).background(.regularMaterial)
    }
    private func beginSelection(_ id: UUID) {
        inlineSession = nil; searchFocused = false; errorMessage = nil
        selecting = true; selectedIDs.insert(id)
        PlatformSupport.lightFeedback()
    }
    private func toggleSelection(_ id: UUID) {
        if !selectedIDs.insert(id).inserted { selectedIDs.remove(id) }
    }
    private func endSelection() { selecting = false; selectedIDs = [] }
    private func deleteSelection() {
        defer { pendingDeletion = [] }
        do {
            guard let store = environment.store else { throw ShikeError.message("存储不可用") }
            let all = try store.all()
            let retainedImages = Set(all.filter { !pendingDeletion.contains($0.id) }.flatMap(\.pendingImages))
            let removedImages = Set(all.filter { pendingDeletion.contains($0.id) }.flatMap(\.pendingImages))
            try store.delete(pendingDeletion)
            if let inlineSession, pendingDeletion.contains(inlineSession.id) { self.inlineSession = nil }
            removedImages.subtracting(retainedImages).forEach(ImageStaging.remove)
            endSelection(); refresh()
        } catch { errorMessage = error.localizedDescription }
    }
    private func processWorkspaceAction() {
        guard let request = workspace.pending, request.section == 1, request.action == .search else { return }
        workspace.consume(request.id); searchExpanded = true; searchFocused = true
    }
    private func refresh() {
        do {
            sessions = try environment.store?.all() ?? []; errorMessage = nil
            selectedIDs.formIntersection(filtered.map(\.id))
        }
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
