import SwiftUI
import UIKit
import ShikeCore

struct CountdownScreen: View {
    @Environment(\.workspaceWidth) private var workspaceWidth
    @EnvironmentObject private var workspace: Workspace
    @State private var inlineSelection: Countdown?
    private var usesColumns: Bool { workspaceWidth >= 880 && !dynamicTypeSize.isAccessibilitySize }
    @ObservedObject var store: CountdownStore
    let coordinator: CountdownCoordinator
    @ObservedObject var preferences: Preferences
    @ObservedObject var navigation: CountdownNavigation
    private var layout: CountdownLayout { preferences.calendarPreferences.countdownLayout ?? .single }
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @State private var search = ""
    @State private var searchExpanded = false
    @State private var restingScrollTop: CGFloat?
    @State private var pullDistance: CGFloat = 0
    private let addPullThreshold: CGFloat = 150
    private var pullArmed: Bool { pullDistance >= addPullThreshold }
    @FocusState private var searchFocused: Bool
    @State private var category = "all"
    @State private var adding = false
    @State private var managing = false
    @State private var selected: Countdown?
    @State private var routeMessage: String?
    @State private var selecting = false
    @State private var selectedIDs: Set<UUID> = []
    @State private var deleteRequested = false
    @State private var pendingDeletion: Set<UUID> = []
    @State private var batchError: String?
    private var entries: [Countdown] {
        store.entries.filter { entry in
            (category == "all" || (category == "none" ? entry.categoryID == nil : entry.categoryID?.uuidString == category)) &&
            (search.isEmpty || entry.title.localizedStandardContains(search) || entry.notes.localizedStandardContains(search))
        }.sorted {
            if $0.pinned != $1.pinned { return $0.pinned }
            let a = CountdownDates.distance($0), b = CountdownDates.distance($1)
            if a != b { return a >= 0 && b < 0 || (a >= 0) == (b >= 0) && abs(a) < abs(b) }
            return $0.id.uuidString < $1.id.uuidString
        }
    }
    var body: some View {
        ZStack {
            PaperBackground()
            HStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    CountdownYearProgress()
                    Text("把期待，写进日子。").font(Notebook.handwriting(30, relativeTo: .largeTitle)).fixedSize(horizontal: false, vertical: true)
                    if searchExpanded {
                        HStack(spacing: 10) {
                            HStack(spacing: 10) {
                                Image(systemName: "magnifyingglass").foregroundStyle(Notebook.secondaryInk)
                                TextField("搜索日子与备注", text: $search).font(.body).focused($searchFocused).accessibilityIdentifier("searchCountdowns")
                                if !search.isEmpty { Button { search = "" } label: { Image(systemName: "xmark.circle.fill") }.accessibilityLabel("清除搜索") }
                            }.padding(14).background(Notebook.ink.opacity(0.05), in: RoundedRectangle(cornerRadius: 13))
                            Button("取消") { search = ""; searchFocused = false; searchExpanded = false }
                                .frame(minHeight: 44).accessibilityIdentifier("closeCountdownSearch")
                        }
                    }
                    categoryLayout {
                        Picker("分类", selection: $category) {
                            Text("全部日子").tag("all"); Text("未分类").tag("none")
                            ForEach(store.categories) { Text($0.name).tag($0.id.uuidString) }
                        }.tint(Notebook.accent).accessibilityIdentifier("countdownCategoryFilter")
                        categoryLayout {
                            Text("\(entries.count) 个日子").font(.caption).foregroundStyle(Notebook.secondaryInk)
                            if !dynamicTypeSize.isAccessibilitySize { Spacer() }
                            Menu {
                                ForEach(CountdownLayout.allCases, id: \.self) { value in
                                    Button {
                                        var p = preferences.calendarPreferences; p.countdownLayout = value; preferences.setCalendarPreferences(p)
                                    } label: { Label(value.title, systemImage: layout == value ? "checkmark" : value.symbol) }
                                    .accessibilityIdentifier("countdownLayout-\(value.rawValue)")
                                }
                            } label: {
                                Group {
                                    if dynamicTypeSize.isAccessibilitySize { Text(layout.title) }
                                    else { Label(layout.title, systemImage: layout.symbol) }
                                }.font(.subheadline).frame(minHeight: 44)
                            }
                            .accessibilityIdentifier("countdownLayout")
                        }
                    }
                    if let error = store.error { NoteMessage(text: error, isError: true) }
                    if let batchError { NoteMessage(text: batchError, isError: true) }
                    if let routeMessage { NoteMessage(text: routeMessage, isError: false) }
                    if entries.isEmpty {
                        PaperCard {
                            VStack(alignment: .leading, spacing: 16) {
                                Image(systemName: "sun.max").font(.system(size: 36, weight: .light)).foregroundStyle(Notebook.accent)
                                Text(search.isEmpty && category == "all" ? "总有一天，值得记住。" : "这里还没有找到日子。").font(Notebook.handwriting(25))
                                Text("生日、旅行、纪念日，或是你正在期待的事。").font(.subheadline).foregroundStyle(Notebook.secondaryInk)
                                Button("记下一个日子") { adding = true }.buttonStyle(InkButtonStyle()).accessibilityIdentifier("addFirstCountdown")
                            }
                        }
                    }
                    TimelineView(.periodic(from: .now, by: entries.contains { $0.targetTime != nil } ? 1 : 60)) { context in
                        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 12, alignment: .top), count: layout == .double && !dynamicTypeSize.isAccessibilitySize ? 2 : 1), alignment: .leading, spacing: layout == .strip ? 10 : 16) {
                            ForEach(entries) { entry in
                                Button {
                                    if selecting { toggleSelection(entry.id) } else { open(entry) }
                                } label: {
                                    CountdownCard(entry: entry, category: store.categories.first { $0.id == entry.categoryID }?.name,
                                                  now: context.date, layout: layout, selection: selecting ? selectedIDs.contains(entry.id) : nil)
                                }.buttonStyle(HoldActionButtonStyle(holdLabel: "批量选择") { beginSelection(entry.id) })
                                    .accessibilityIdentifier("countdown-\(entry.id)")
                                    .accessibilityValue(selecting ? (selectedIDs.contains(entry.id) ? "已选择" : "未选择") : "")
                                    .accessibilityAddTraits(selectedIDs.contains(entry.id) ? .isSelected : [])
                                    .accessibilityHint(selecting ? "轻点切换选择" : "轻点查看，长按批量选择")
                            }
                        }
                    }
                }.padding(22).frame(maxWidth: 680).frame(maxWidth: .infinity)
                    .background(CountdownPullObserver(onPull: { distance in
                        guard !selecting, !adding, !managing, selected == nil else { return }
                        pullDistance = distance
                    }, onRelease: { distance in
                        pullDistance = 0
                        guard distance >= addPullThreshold, !selecting, !adding, !managing, selected == nil else { return }
                        searchFocused = false
                        adding = true
                    }))
                    .onGeometryChange(for: CGFloat.self) { geometry in
                        geometry.frame(in: .named("countdownViewport")).minY
                    } action: { top in
                        guard let restingScrollTop else { self.restingScrollTop = top; return }
                        if !searchExpanded && top > restingScrollTop + 55 { searchExpanded = true }
                    }
            }.scrollBounceBehavior(.always)
                .accessibilityAction(named: "展开搜索") { searchExpanded = true; searchFocused = true }
                .accessibilityAction(named: "新增倒数日") { adding = true }
                .overlay(alignment: .top) {
                    if pullDistance > 75 {
                        Label(pullArmed ? "松手新增日子" : "继续下拉，新增日子", systemImage: pullArmed ? "plus.circle.fill" : "arrow.down")
                            .font(.subheadline).foregroundStyle(Notebook.accent).padding(.top, 12)
                            .allowsHitTesting(false).accessibilityHidden(true)
                    }
                }
                .frame(maxWidth: inlineSelection != nil && !usesColumns ? 0 : .infinity)
                .clipped().accessibilityHidden(inlineSelection != nil && !usesColumns)
            if usesColumns || inlineSelection != nil {
                Divider()
                ZStack {
                    if let inlineSelection {
                        CountdownDetail(store: store, reminders: coordinator.reminders, id: inlineSelection.id, onClose: { self.inlineSelection = nil })
                            .id(inlineSelection.id)
                    } else {
                        VStack(spacing: 18) {
                            CalendarDoodle()
                            Text("选一个日子，慢慢翻看。").font(Notebook.handwriting(24))
                            Text("提醒、备注和分享卡片，都放在这里。")
                                .font(.subheadline).foregroundStyle(Notebook.secondaryInk)
                        }.padding(24)
                    }
                }.frame(maxWidth: .infinity, maxHeight: .infinity).accessibilityIdentifier("countdownDetailPane")
            }
            }
        }.coordinateSpace(name: "countdownViewport")
            .foregroundStyle(Notebook.ink).navigationTitle("倒数日").navigationBarTitleDisplayMode(.inline)
            .scrollDismissesKeyboard(.interactively)
            .safeAreaInset(edge: .bottom, spacing: 0) {
                if selecting { selectionBar }
            }
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    if selecting { Button("完成") { endSelection() }.accessibilityIdentifier("finishCountdownSelection") }
                    else { Button { managing = true } label: { Image(systemName: "folder") }.accessibilityLabel("管理倒数日分类") }
                }
                ToolbarItem(placement: .primaryAction) {
                    if PlatformSupport.isMac { Button { searchExpanded = true; searchFocused = true } label: { Image(systemName: "magnifyingglass") }.accessibilityLabel("搜索倒数日") }
                }
                ToolbarItem(placement: .primaryAction) { Button { adding = true } label: { Image(systemName: "plus") }.accessibilityLabel("新增倒数日").accessibilityIdentifier("addCountdown").disabled(selecting) }
            }
            .alert("删除这 \(pendingDeletion.count) 个日子？", isPresented: $deleteRequested) {
                Button("删除", role: .destructive) {
                    do {
                        try store.deleteEntries(pendingDeletion)
                        routeMessage = "已删除 \(pendingDeletion.count) 个日子。"
                        endSelection()
                    } catch { batchError = error.localizedDescription }
                    pendingDeletion = []
                }.accessibilityIdentifier("confirmDeleteCountdowns")
                Button("取消", role: .cancel) { pendingDeletion = [] }
            } message: { Text("删除后会同步到其他设备，无法撤销。") }
            .sheet(isPresented: $adding) { CountdownEditor(store: store, reminders: coordinator.reminders, entry: Countdown(), preferences: preferences).workspaceSheet() }
            .sheet(isPresented: $managing) { CountdownCategoriesView(store: store).workspaceSheet() }
            .sheet(item: $selected) { CountdownDetail(store: store, reminders: coordinator.reminders, id: $0.id).workspaceSheet() }
            .onChange(of: workspace.pending?.id) { _, _ in processWorkspaceAction() }
            .onAppear { processWorkspaceAction() }
            .onAppear { consumeRoute() }
            .onChange(of: navigation.pending) { _, _ in consumeRoute() }
            .onChange(of: pullArmed) { _, armed in if armed { PlatformSupport.lightFeedback() } }
            .onChange(of: store.categories) { _, values in if category != "all" && category != "none" && !values.contains(where: { $0.id.uuidString == category }) { category = "none" } }
            .onChange(of: category) { _, _ in selectedIDs = [] }
            .onChange(of: search) { _, _ in selectedIDs.formIntersection(entries.map(\.id)) }
            .onChange(of: store.revision) { _, _ in selectedIDs.formIntersection(entries.map(\.id)) }
            .onDisappear { endSelection() }
    }
    private var selectionBar: some View {
        VStack(spacing: 8) {
            HStack {
                Text("已选择 \(selectedIDs.count) 个日子").font(.subheadline).accessibilityIdentifier("countdownSelectionCount")
                Spacer()
                Button(selectedIDs.count == entries.count && !entries.isEmpty ? "取消全选" : "全选") {
                    selectedIDs = selectedIDs.count == entries.count ? [] : Set(entries.map(\.id))
                }.frame(minHeight: 36).accessibilityIdentifier("selectAllCountdowns")
            }
            HStack(spacing: 16) {
                Menu {
                    Button("未分类") { moveSelection(to: nil) }
                    ForEach(store.categories) { group in
                        Button(group.name) { moveSelection(to: group.id) }
                    }
                } label: { Label("移动分组", systemImage: "folder").frame(maxWidth: .infinity, minHeight: 44) }
                    .accessibilityIdentifier("moveSelectedCountdowns")
                Button(role: .destructive) { pendingDeletion = selectedIDs; deleteRequested = true } label: {
                    Label("删除", systemImage: "trash").frame(maxWidth: .infinity, minHeight: 44)
                }.accessibilityIdentifier("deleteSelectedCountdowns")
            }.disabled(selectedIDs.isEmpty)
        }.padding(.horizontal, 22).padding(.vertical, 8).frame(maxWidth: 680)
            .frame(maxWidth: .infinity).background(.regularMaterial)
    }
    private func beginSelection(_ id: UUID) {
        selected = nil; inlineSelection = nil; searchFocused = false; batchError = nil
        selecting = true; selectedIDs.insert(id); pullDistance = 0
        PlatformSupport.lightFeedback()
    }
    private func toggleSelection(_ id: UUID) {
        if !selectedIDs.insert(id).inserted { selectedIDs.remove(id) }
    }
    private func endSelection() { selecting = false; selectedIDs = []; batchError = nil }
    private func moveSelection(to group: UUID?) {
        let count = selectedIDs.count
        do {
            try store.moveEntries(selectedIDs, to: group)
            routeMessage = "已将 \(count) 个日子移到「\(store.categories.first { $0.id == group }?.name ?? "未分类")」。"
            endSelection()
        } catch { batchError = error.localizedDescription }
    }
    private func open(_ entry: Countdown) {
        // Keep the presentation chosen at open time, even if the window rotates or shrinks.
        if usesColumns || inlineSelection != nil { inlineSelection = entry }
        else { selected = entry }
    }
    private func processWorkspaceAction() {
        guard let request = workspace.pending, request.section == 4, !adding, !managing, selected == nil else { return }
        workspace.consume(request.id)
        switch request.action {
        case .new: endSelection(); adding = true
        case .search: searchExpanded = true; searchFocused = true
        default: break
        }
    }
    private func consumeRoute() {
        guard let route = navigation.pending else { return }
        endSelection()
        navigation.pending = nil; search = ""; searchExpanded = false; adding = false; managing = false
        category = route.group; selected = nil; inlineSelection = nil; routeMessage = nil
        if category != "all" && category != "none" && !store.categories.contains(where: { $0.id.uuidString == category }) {
            routeMessage = "这个分组已被删除，请重新选择。"
        }
        if let id = route.id {
            if let entry = store.entries.first(where: { $0.id == id }) { open(entry) }
            else { routeMessage = "这个日子已被删除。" }
        }
    }
    private var categoryLayout: AnyLayout {
        dynamicTypeSize.isAccessibilitySize ? AnyLayout(VStackLayout(alignment: .leading, spacing: 12)) : AnyLayout(HStackLayout(spacing: 16))
    }
}

/// Observe the scroll view's own pan recognizer; adding another drag gesture can
/// steal scrolling or miss cancellation when the scroll view wins recognition.
private struct CountdownPullObserver: UIViewRepresentable {
    let onPull: (CGFloat) -> Void
    let onRelease: (CGFloat) -> Void
    func makeCoordinator() -> Coordinator { Coordinator(onPull: onPull, onRelease: onRelease) }
    func makeUIView(context: Context) -> Probe {
        let view = Probe()
        view.isUserInteractionEnabled = false
        view.attached = { [weak coordinator = context.coordinator] view in coordinator?.attach(from: view) }
        return view
    }
    func updateUIView(_ view: Probe, context: Context) {
        context.coordinator.onPull = onPull; context.coordinator.onRelease = onRelease
    }
    static func dismantleUIView(_ view: Probe, coordinator: Coordinator) { coordinator.detach() }
    final class Probe: UIView {
        var attached: ((UIView) -> Void)?
        override func didMoveToWindow() {
            super.didMoveToWindow()
            guard window != nil else { return }
            DispatchQueue.main.async { [weak self] in if let self { attached?(self) } }
        }
    }
    final class Coordinator: NSObject {
        var onPull: (CGFloat) -> Void
        var onRelease: (CGFloat) -> Void
        weak var scrollView: UIScrollView?
        init(onPull: @escaping (CGFloat) -> Void, onRelease: @escaping (CGFloat) -> Void) {
            self.onPull = onPull; self.onRelease = onRelease
        }
        func attach(from view: UIView) {
            var ancestor = view.superview
            while let current = ancestor {
                if let scroll = current as? UIScrollView {
                    guard scroll !== scrollView else { return }
                    detach(); scrollView = scroll
                    scroll.panGestureRecognizer.addTarget(self, action: #selector(track(_:)))
                    return
                }
                ancestor = current.superview
            }
        }
        func detach() {
            scrollView?.panGestureRecognizer.removeTarget(self, action: #selector(track(_:)))
            scrollView = nil
        }
        @objc private func track(_ gesture: UIPanGestureRecognizer) {
            guard let scrollView else { return }
            let distance = max(0, -scrollView.contentOffset.y - scrollView.adjustedContentInset.top)
            switch gesture.state {
            case .began, .changed: onPull(distance)
            case .ended: onRelease(distance)
            case .cancelled, .failed: onPull(0)
            default: break
            }
        }
    }
}

private struct CountdownYearProgress: View {
    @Environment(\.scenePhase) private var scenePhase
    @State private var now = Date.now

    var body: some View {
        let progress = YearProgress(now: now, timeZone: .current)
        let percentage = progress.fraction.formatted(.percent.precision(.fractionLength(1)))
        VStack(alignment: .leading, spacing: 8) {
            Text("今年已过 \(progress.elapsedDays) 天 · \(percentage)")
                .font(Notebook.handwriting(17, relativeTo: .subheadline)).monospacedDigit()
                .fixedSize(horizontal: false, vertical: true)
            GeometryReader { geometry in
                Capsule().fill(Notebook.ink.opacity(0.07))
                    .overlay(alignment: .leading) {
                        LinearGradient(colors: [Notebook.accent.opacity(0.75), Notebook.green, Notebook.yellow],
                                       startPoint: .leading, endPoint: .trailing)
                            .frame(width: max(0, geometry.size.width) * progress.fraction)
                            .clipShape(Capsule())
                    }
                    .overlay(YearProgressOutline().stroke(Notebook.ink.opacity(0.22), lineWidth: 0.8))
            }.frame(height: 10).accessibilityHidden(true)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(progress.year) 年，全年 \(progress.totalDays) 天，已过 \(progress.elapsedDays) 天")
        .accessibilityValue(percentage)
        .accessibilityIdentifier("countdownYearProgress")
        .task {
            // SwiftUI cancels this task when the strip leaves the screen.
            now = .now
            while !Task.isCancelled {
                do { try await Task.sleep(for: .seconds(60)) } catch { return }
                if scenePhase == .active { now = .now }
            }
        }
        .onChange(of: scenePhase) { _, phase in if phase == .active { now = .now } }
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.significantTimeChangeNotification)) { _ in now = .now }
        .onReceive(NotificationCenter.default.publisher(for: .NSSystemTimeZoneDidChange)) { _ in now = .now }
        .onReceive(NotificationCenter.default.publisher(for: .NSCalendarDayChanged)) { _ in now = .now }
    }
}

private struct YearProgressOutline: Shape {
    func path(in rect: CGRect) -> Path {
        let w = rect.width, h = rect.height
        var path = Path()
        path.move(to: CGPoint(x: 5, y: 1))
        path.addCurve(to: CGPoint(x: w - 5, y: 1), control1: CGPoint(x: w * 0.35, y: 0), control2: CGPoint(x: w * 0.7, y: 2))
        path.addQuadCurve(to: CGPoint(x: w - 1, y: h / 2), control: CGPoint(x: w, y: 1))
        path.addQuadCurve(to: CGPoint(x: w - 5, y: h - 1), control: CGPoint(x: w, y: h - 1))
        path.addCurve(to: CGPoint(x: 5, y: h - 1), control1: CGPoint(x: w * 0.65, y: h), control2: CGPoint(x: w * 0.3, y: h - 2))
        path.addQuadCurve(to: CGPoint(x: 1, y: h / 2), control: CGPoint(x: 0, y: h - 1))
        path.addQuadCurve(to: CGPoint(x: 5, y: 1), control: CGPoint(x: 0, y: 1))
        path.closeSubpath()
        return path
    }
}

struct CountdownCard: View {
    let entry: Countdown
    let category: String?
    let now: Date
    var layout: CountdownLayout = .single
    var selection: Bool? = nil
    var countUnit: CountdownCountUnit = .days
    var onCountTap: (() -> Void)? = nil
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    private var compact: Bool { layout != .single }
    var body: some View {
        PaperCard {
            if layout == .strip && !dynamicTypeSize.isAccessibilitySize {
                HStack(alignment: .center, spacing: 14) {
                    VStack(alignment: .leading, spacing: 5) { heading; dateLabel }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    countLabel(alignment: .trailing)
                        .frame(width: entry.targetTime == nil ? 112 : 128, alignment: .trailing)
                }
            } else {
                VStack(alignment: .leading, spacing: compact ? 9 : 12) {
                    heading
                    countLabel()
                    dateLabel
                    if let category { Text(category).font(.caption).foregroundStyle(Notebook.secondaryInk) }
                    if entry.includesStartDay == true && entry.targetTime != nil && CountdownDates.elapsedDays(entry, now: now) >= 1 {
                        Text("含起始日 · 第 \(CountdownDates.elapsedDays(entry, now: now)) 天").font(.caption).foregroundStyle(Notebook.secondaryInk)
                    }
                }.frame(maxWidth: .infinity, alignment: .leading)
            }
        }.overlay { if selection == true { PencilBorder().stroke(Notebook.accent, lineWidth: 2) } }
    }
    private var heading: some View {
        HStack(alignment: .top, spacing: 5) {
            if let selection {
                Image(systemName: selection ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 20)).foregroundStyle(Notebook.accent).padding(.top, 3).accessibilityHidden(true)
            }
            Text(entry.title).font(Notebook.handwriting(compact ? 20 : 25, relativeTo: .title2))
                .lineLimit(dynamicTypeSize.isAccessibilitySize ? nil : 2)
                .multilineTextAlignment(.leading).fixedSize(horizontal: false, vertical: true)
            if entry.pinned { Image(systemName: "pin.fill").font(.system(size: compact ? 12 : 14)).foregroundStyle(Notebook.accent).accessibilityLabel("已置顶") }
        }
    }
    @ViewBuilder private func countLabel(alignment: HorizontalAlignment = .leading) -> some View {
        if let onCountTap {
            Button(action: onCountTap) {
                countContent(alignment: alignment).frame(minHeight: 44, alignment: .leading).contentShape(Rectangle())
            }
                .buttonStyle(.plain)
                .accessibilityIdentifier("cycleCountdownUnit")
                .accessibilityHint("切换为\(countUnit.next.title)计数")
        } else { countContent(alignment: alignment) }
    }
    private func countContent(alignment: HorizontalAlignment) -> some View {
        let value = CountdownDisplayValue(entry, now: now, unit: countUnit)
        return VStack(alignment: alignment, spacing: 3) {
            if countUnit != .days && !compact {
                CountdownCountColumns(value: value)
            } else if value.phase == .today && countUnit == .days {
                Text(value.status).font(Notebook.handwriting(compact ? 23 : 30, relativeTo: .title))
                    .lineLimit(1).minimumScaleFactor(0.7)
            } else {
                Text(value.status).font(.caption)
                HStack(alignment: .firstTextBaseline, spacing: 4) {
                    Text("\(value.count)").font(Notebook.handwriting(compact ? 25 : 36, relativeTo: .title)).monospacedDigit()
                    Text(value.unit.title).font(Notebook.handwriting(compact ? 17 : 21, relativeTo: .body))
                }.lineLimit(1).minimumScaleFactor(0.65)
                    .accessibilityIdentifier("countdownDays-\(entry.id)")
                if let remainder = value.remainder {
                    Text(remainder).font(Notebook.handwriting(compact ? 17 : 21, relativeTo: .body))
                        .fixedSize(horizontal: false, vertical: true)
                }
                if let time = value.time {
                    Text(time).font(.system(.caption, design: .monospaced)).lineLimit(1).minimumScaleFactor(0.7)
                }
            }
        }
        .foregroundStyle(Notebook.accent)
        .frame(maxWidth: .infinity, alignment: alignment == .trailing ? .trailing : .leading)
        .accessibilityElement(children: .ignore).accessibilityLabel(value.label)
        .accessibilityIdentifier("countdownValue-\(entry.id)")
    }
    private var dateLabel: some View {
        Text("\(CountdownDates.targetDescription(entry)) · \(entry.calendar.title)\(entry.recurrence == .none ? "" : " · " + entry.recurrence.title)")
            .font(.caption).foregroundStyle(Notebook.secondaryInk).multilineTextAlignment(.leading).fixedSize(horizontal: false, vertical: true)
    }
}

/// Equal-width components keep every unit readable without leaving the right half empty.
private struct CountdownCountColumns: View {
    let value: CountdownDisplayValue
    var numberSize: CGFloat = 36
    var body: some View {
        VStack(spacing: 12) {
            Text(value.status).font(.caption)
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                ForEach(Array(value.components.enumerated()), id: \.offset) { _, component in
                    VStack(spacing: 4) {
                        Text("\(component.value)").font(Notebook.handwriting(numberSize, relativeTo: .title))
                            .monospacedDigit().lineLimit(1).minimumScaleFactor(0.5)
                        Text(component.unit.title).font(Notebook.handwriting(19, relativeTo: .body))
                            .lineLimit(1).minimumScaleFactor(0.7)
                    }.frame(maxWidth: .infinity)
                }
            }
            if let time = value.time { Text(time).font(.system(.body, design: .monospaced)).monospacedDigit() }
        }.frame(maxWidth: .infinity).padding(.vertical, 8).foregroundStyle(Notebook.accent)
            .accessibilityElement(children: .ignore).accessibilityLabel(value.label)
    }
}

struct CountdownDetail: View {
    @ObservedObject var store: CountdownStore
    @ObservedObject var reminders: CountdownReminderService
    let id: UUID
    var onClose: (() -> Void)? = nil
    @Environment(\.dismiss) private var dismiss
    @State private var editing = false
    @State private var deleting = false
    @State private var imageExport: CountdownImageExport?
    @State private var error: String?
    @State private var countUnit: CountdownCountUnit = .days
    private var entry: Countdown? { store.entries.first { $0.id == id } }
    private func closeDetail() { countUnit = .days; if let onClose { onClose() } else { dismiss() } }
    var body: some View {
        NavigationStack {
            ZStack {
                PaperBackground()
                if let entry {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 22) {
                            TimelineView(.periodic(from: .now, by: entry.targetTime == nil ? 60 : 1)) { context in
                                CountdownCard(entry: entry, category: store.categories.first { $0.id == entry.categoryID }?.name,
                                              now: context.date, countUnit: countUnit, onCountTap: { countUnit = countUnit.next })
                            }
                            PaperCard {
                                VStack(alignment: .leading, spacing: 12) {
                                    if entry.calendar == .chinese { Text(lunarDescription(entry)).font(.subheadline) }
                                    if entry.recurrence != .none {
                                        TimelineView(.periodic(from: .now, by: entry.targetTime == nil ? 60 : 1)) { context in
                                            if let next = entry.targetTime == nil ? CountdownDates.next(entry, onOrAfter: context.date) : CountdownDates.nextInstant(entry, onOrAfter: context.date) {
                                                Text("下一次 · \(CivilDate(next, timeZone: entry.timeZone()).description)\(entry.targetTime.map { " " + $0.description } ?? "")")
                                            }
                                        }
                                        let age = CountdownDates.elapsedDays(entry)
                                        Text(age >= 0 ? "从最初那天起，已经 \(age) 天。" : "最初的日子还未到来。")
                                    }
                                    Text(entry.timeZoneIdentifier == nil ? "跟随系统时区" : "时区 · \(TimeZoneOption.offsetTitle(entry.timeZone().secondsFromGMT()))")
                                        .foregroundStyle(Notebook.secondaryInk)
                                    if !entry.notes.isEmpty { Divider(); Text(entry.notes).textSelection(.enabled) }
                                }.font(.subheadline).frame(maxWidth: .infinity, alignment: .leading)
                            }
                            if entry.reminder.isEnabled {
                                PaperCard {
                                    VStack(alignment: .leading, spacing: 10) {
                                        Label("提醒", systemImage: "bell").font(Notebook.handwriting(23))
                                        if entry.reminder.anniversaries == true { Text("每逢周年提醒") }
                                        if let interval = entry.reminder.dayInterval { Text("每 \(interval) 天提醒") }
                                        if !entry.reminder.milestones.isEmpty {
                                            Text("纪念提醒 · " + entry.reminder.milestones.sorted().map { "\($0) 天" }.joined(separator: "、"))
                                        }
                                        if let next = reminders.scheduled.first(where: { $0.countdownID == id }) {
                                            Text("下一次提醒 · \(next.fireAt.formatted(date: .abbreviated, time: .shortened))")
                                        } else { Text(reminders.status) }
                                        Text("通知时间按本设备显示。打开 App 后会滚动更新提醒。").font(.caption).foregroundStyle(Notebook.secondaryInk)
                                    }.font(.subheadline)
                                }
                            }
                            Button(entry.pinned ? "取消置顶" : "置顶这个日子") {
                                var value = entry; value.pinned.toggle()
                                do { try store.save(value) } catch { self.error = error.localizedDescription }
                            }.buttonStyle(InkButtonStyle(prominent: false)).accessibilityIdentifier("pinCountdown")
                            Button {
                                do { imageExport = try CountdownImageExport.make(entry: entry, category: store.categories.first { $0.id == entry.categoryID }?.name, unit: countUnit) }
                                catch { self.error = error.localizedDescription }
                            } label: { Label("导出卡片图片", systemImage: "square.and.arrow.up") }
                                .buttonStyle(InkButtonStyle(prominent: false)).accessibilityIdentifier("exportCountdownImage")
                            Button("删除倒数日", role: .destructive) { deleting = true }.frame(minHeight: 44).accessibilityIdentifier("deleteCountdown")
                            if let error { NoteMessage(text: error, isError: true) }
                        }.padding(22).frame(maxWidth: 680).frame(maxWidth: .infinity)
                    }
                } else { Text("这个日子已被删除。").font(Notebook.handwriting(25)) }
            }.foregroundStyle(Notebook.ink).navigationTitle("记住这一天").navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) { Button("完成") { closeDetail() }.accessibilityIdentifier("closeCountdownDetail") }
                    ToolbarItem(placement: .primaryAction) { if entry != nil { Button("编辑") { editing = true }.accessibilityIdentifier("editCountdown") } }
                }
                .sheet(isPresented: $editing) { if let entry { CountdownEditor(store: store, reminders: reminders, entry: entry).workspaceSheet() } }
                .sheet(item: $imageExport) { CountdownImagePreview(export: $0).workspaceSheet() }
                .alert("删除这个倒数日？", isPresented: $deleting) {
                    Button("删除", role: .destructive) { do { try store.delete(id); closeDetail() } catch { self.error = error.localizedDescription } }
                    Button("取消", role: .cancel) {}
                } message: { Text("开启 iCloud 同步时，其他设备上的这条记录也会删除。") }
        }.tint(Notebook.accent)
            .onChange(of: id) { _, _ in countUnit = .days }

    }
}

struct CountdownEditor: View {
    @ObservedObject var store: CountdownStore
    @ObservedObject var reminders: CountdownReminderService
    @State private var entry: Countdown
    @State private var expectedRevision: UUID?
    @Environment(\.dismiss) private var dismiss
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @State private var error: String?
    @State private var saving = false
    @State private var recognizing = false
    @State private var naturalSaved = false
    @State private var dateConfirmed: Bool
    private let preferences: Preferences?
    private let onSave: ((Countdown) throws -> Void)?
    @State private var milestoneText: String
    @State private var intervalChoice: Int
    @State private var intervalText: String
    private enum Field { case title, notes, milestones, interval }
    @FocusState private var focused: Field?
    init(store: CountdownStore, reminders: CountdownReminderService, entry: Countdown, preferences: Preferences? = nil,
         requiresDate: Bool = false, onSave: ((Countdown) throws -> Void)? = nil) {
        self.store = store; self.reminders = reminders; _entry = State(initialValue: entry)
        self.preferences = preferences; self.onSave = onSave; _dateConfirmed = State(initialValue: !requiresDate)
        _expectedRevision = State(initialValue: store.records.first { $0.id == entry.id }?.revision)
        _milestoneText = State(initialValue: entry.reminder.milestones.sorted().map(String.init).joined(separator: ", "))
        let interval = entry.reminder.dayInterval ?? 100
        _intervalChoice = State(initialValue: [100, 500, 1000].contains(interval) ? interval : 0)
        _intervalText = State(initialValue: String(interval))
    }
    private var date: Binding<Date> {
        Binding(get: { entry.anchorDate.date(in: entry.timeZone()) ?? .now }, set: { entry.anchorDate = CivilDate($0, timeZone: entry.timeZone()); dateConfirmed = true })
    }
    private var reminderTime: Binding<Date> {
        Binding(get: { Calendar.current.date(from: DateComponents(year: 2001, month: 1, day: 1, hour: entry.reminder.hour, minute: entry.reminder.minute))! }, set: {
            entry.reminder.hour = Calendar.current.component(.hour, from: $0); entry.reminder.minute = Calendar.current.component(.minute, from: $0)
        })
    }
    var body: some View {
        NavigationStack {
            ZStack { PaperBackground(); ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    PaperCard {
                        VStack(alignment: .leading, spacing: 16) {
                            TextField("给这一天起个名字", text: $entry.title, axis: .vertical).font(Notebook.handwriting(27)).focused($focused, equals: .title).accessibilityIdentifier(onSave == nil ? "countdownTitle" : "reviewCountdownTitle")
                            Divider()
                            Picker("日期历法", selection: $entry.calendar) { ForEach(CountdownCalendar.allCases, id: \.self) { Text($0.title).tag($0) } }.pickerStyle(.segmented)
                            DatePicker("最初日期", selection: date,
                                       in: CivilDate(year: 1901, month: 1, day: 1).date(in: entry.timeZone())!...CivilDate(year: 2099, month: 12, day: 31).date(in: entry.timeZone())!, displayedComponents: .date)
                                .environment(\.calendar, CountdownDates.calendar(entry)).environment(\.timeZone, entry.timeZone())
                                .dynamicTypeSize(...DynamicTypeSize.xxxLarge).accessibilityIdentifier("countdownDate")
                            if !dateConfirmed {
                                Text("原文没有明确日期，请选择日期，或明确确认当前所选日期。").font(.caption).foregroundStyle(.orange)
                                Button("确认使用这个日期") { dateConfirmed = true }.accessibilityIdentifier("confirmRecognizedDate")
                            }
                            if entry.calendar == .chinese {
                                Text("\(lunarDescription(entry)) · 对应公历 \(entry.anchorDate.description)").font(.caption).foregroundStyle(Notebook.secondaryInk)
                            }
                            Toggle("精确到秒", isOn: Binding(get: { entry.targetTime != nil }, set: { entry.targetTime = $0 ? CountdownTime() : nil }))
                                .accessibilityIdentifier("countdownPreciseTime")
                            if entry.targetTime != nil {
                                timeLayout {
                                    timePicker("时", range: 0..<24, keyPath: \.hour)
                                    timePicker("分", range: 0..<60, keyPath: \.minute)
                                    timePicker("秒", range: 0..<60, keyPath: \.second)
                                }
                                Text("目标时间与倒计时均显示到秒。时长按实际经过时间计算。").font(.caption).foregroundStyle(Notebook.secondaryInk)
                            }
                            Toggle("正数日包含起始日（+1 天）", isOn: Binding(get: { entry.includesStartDay == true }, set: { entry.includesStartDay = $0 }))
                                .accessibilityIdentifier("countdownIncludesStart")
                            Text("开启后，最初日期计为第 1 天，纪念提醒也提前一天；精确时长仍按实际时间显示。").font(.caption).foregroundStyle(Notebook.secondaryInk)
                            Picker("重复", selection: $entry.recurrence) { ForEach(CountdownRepeat.allCases, id: \.self) { Text($0.title).tag($0) } }.accessibilityIdentifier("countdownRepeat")
                            Picker("分类", selection: $entry.categoryID) {
                                Text("未分类").tag(nil as UUID?)
                                ForEach(store.categories) { Text($0.name).tag(Optional($0.id)) }
                            }
                            Toggle("置顶", isOn: $entry.pinned)
                        }
                    }
                    PaperCard {
                        VStack(alignment: .leading, spacing: 14) {
                            Text("备注").font(Notebook.handwriting(23))
                            TextField("写一点想记住的事", text: $entry.notes, axis: .vertical).lineLimit(3...8).focused($focused, equals: .notes).accessibilityIdentifier("countdownNotes")
                            NavigationLink {
                                TimeZoneSelectionView(selection: Binding(get: { entry.timeZone().identifier }, set: { entry.timeZoneIdentifier = $0 }), date: date.wrappedValue)
                            } label: { Label(entry.timeZoneIdentifier == nil ? "时区 · 跟随系统" : "时区 · \(TimeZoneOption.offsetTitle(entry.timeZone().secondsFromGMT(for: date.wrappedValue)))", systemImage: "globe.asia.australia") }
                            if entry.timeZoneIdentifier != nil { Button("跟随系统时区") { entry.timeZoneIdentifier = nil } }
                        }
                    }
                    PaperCard {
                        VStack(alignment: .leading, spacing: 12) {
                            Text("在这一天提醒我").font(Notebook.handwriting(23))
                            ForEach([0, 1, 3, 7], id: \.self) { offset in
                                Toggle(offset == 0 ? "当天" : "提前 \(offset) 天", isOn: Binding(get: { entry.reminder.daysBefore.contains(offset) }, set: { enabled in
                                    entry.reminder.daysBefore.removeAll { $0 == offset }; if enabled { entry.reminder.daysBefore.append(offset) }
                                }))
                            }
                            Divider()
                            Text("正数日纪念提醒").font(Notebook.handwriting(23))
                            Toggle("每逢周年提醒", isOn: Binding(get: { entry.reminder.anniversaries == true }, set: { entry.reminder.anniversaries = $0 }))
                                .accessibilityIdentifier("countdownAnniversaries")
                            Text("按这个日子的公历或农历，每满一周年提醒；不改变日子的重复设置。").font(.caption).foregroundStyle(Notebook.secondaryInk)
                            Toggle("整数日提醒", isOn: Binding(get: { entry.reminder.dayInterval != nil }, set: { enabled in
                                entry.reminder.dayInterval = enabled ? (intervalChoice == 0 ? Int(intervalText) ?? 100 : intervalChoice) : nil
                            })).accessibilityIdentifier("countdownDayIntervalEnabled")
                            if entry.reminder.dayInterval != nil {
                                Picker("提醒间隔", selection: Binding(get: { intervalChoice }, set: { value in
                                    intervalChoice = value
                                    if value != 0 { entry.reminder.dayInterval = value; intervalText = String(value) }
                                })) {
                                    ForEach([100, 500, 1000], id: \.self) { Text("每 \($0) 天").tag($0) }
                                    Text("自定义").tag(0)
                                }.accessibilityIdentifier("countdownDayInterval")
                                if intervalChoice == 0 {
                                    TextField("间隔天数（1–100000）", text: $intervalText).keyboardType(.numberPad)
                                        .focused($focused, equals: .interval).accessibilityIdentifier("countdownCustomInterval")
                                }
                                Text("从最初日期起，达到间隔的每个整数倍时提醒；包含起始日时提前一天。").font(.caption).foregroundStyle(Notebook.secondaryInk)
                            }
                            Text("指定天数").font(.subheadline)
                            TextField("例如 520, 1314", text: $milestoneText, axis: .vertical)
                                .keyboardType(.numbersAndPunctuation).focused($focused, equals: .milestones).accessibilityIdentifier("countdownMilestones")
                            HStack {
                                ForEach([520, 1314], id: \.self) { count in
                                    Button("+ \(count) 天") { appendMilestone(count) }
                                        .font(.subheadline).frame(minHeight: 44).accessibilityIdentifier("milestonePreset-\(count)")
                                }
                            }
                            Text("从最初日期起算，用逗号分隔多个天数，最多 60 个（1–100000）。与每年、每月重复分别计算。").font(.caption).foregroundStyle(Notebook.secondaryInk)
                            if entry.reminder.isEnabled || !milestoneText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                                DatePicker("提醒时间", selection: reminderTime, displayedComponents: .hourAndMinute)
                                Text("按倒数日时区提醒。保存时会请求本设备的通知权限。").font(.caption).foregroundStyle(Notebook.secondaryInk)
                            }
                        }
                    }
                    Text("默认按自然日计数，当天为 0 天。每月缺少该日时用月末；2 月 29 日在平年用 2 月 28 日。农历闰月不存在时用同名普通月，缺少三十时用该月最后一天。最初日期始终保留。")
                        .font(.caption).foregroundStyle(Notebook.secondaryInk)
                    if let error { NoteMessage(text: error, isError: true) }
                    if expectedRevision == nil, onSave == nil, preferences != nil {
                        Button { focused = nil; recognizing = true } label: { Label("自然语言识别", systemImage: "sparkles") }
                            .buttonStyle(InkButtonStyle(prominent: false)).accessibilityIdentifier("openCountdownNaturalLanguage")
                    }
                }.padding(22).frame(maxWidth: 680).frame(maxWidth: .infinity)
            }.scrollDismissesKeyboard(.interactively) }
                .foregroundStyle(Notebook.ink).navigationTitle(onSave != nil ? "核对这个日子" : (expectedRevision == nil ? "记下一个日子" : "编辑倒数日")).navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() }.disabled(saving).accessibilityIdentifier("cancelCountdownEditing") }
                    ToolbarItem(placement: .confirmationAction) { Button("保存") { save() }.disabled(saving || !dateConfirmed || entry.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty).accessibilityIdentifier(onSave == nil ? "saveCountdown" : "reviewSaveCountdown") }
                    ToolbarItemGroup(placement: .keyboard) { Spacer(); Button("收起键盘") { focused = nil } }
                }
                .sheet(isPresented: $recognizing, onDismiss: { if naturalSaved { dismiss() } }) {
                    if let preferences { CountdownNaturalLanguageView(store: store, reminders: reminders, preferences: preferences) { naturalSaved = true } }
                }
        }.tint(Notebook.accent).interactiveDismissDisabled(saving)
    }
    private func timePicker(_ label: String, range: Range<Int>, keyPath: WritableKeyPath<CountdownTime, Int>) -> some View {
        Picker(label, selection: Binding(get: { entry.targetTime?[keyPath: keyPath] ?? 0 }, set: { value in
            var time = entry.targetTime ?? CountdownTime(); time[keyPath: keyPath] = value; entry.targetTime = time
        })) { ForEach(range, id: \.self) { Text(String(format: "%02d", $0) + label).tag($0) } }
            .pickerStyle(.menu).frame(maxWidth: .infinity).accessibilityIdentifier("countdownTime-" + label)
    }
    private var timeLayout: AnyLayout {
        dynamicTypeSize.isAccessibilitySize ? AnyLayout(VStackLayout(alignment: .leading, spacing: 8)) : AnyLayout(HStackLayout(spacing: 0))
    }
    private func appendMilestone(_ count: Int) {
        let existing = milestoneText.components(separatedBy: CharacterSet(charactersIn: ",，、;； \n\t")).compactMap(Int.init)
        guard !existing.contains(count) else { return }
        milestoneText += milestoneText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "\(count)" : ", \(count)"
    }
    private func save() {
        do {
            let parts = milestoneText.components(separatedBy: CharacterSet(charactersIn: ",，、;； \n\t")).filter { !$0.isEmpty }
            let values = parts.compactMap(Int.init)
            guard parts.count == values.count, values.allSatisfy({ (1...100_000).contains($0) }), Set(values).count <= 60 else {
                throw ShikeError.message("纪念提醒请填写 1–100000 的整数，用逗号分隔，最多 60 个。")
            }
            entry.reminder.milestones = Array(Set(values)).sorted()
            if entry.reminder.dayInterval != nil {
                guard let interval = intervalChoice == 0 ? Int(intervalText.trimmingCharacters(in: .whitespacesAndNewlines)) : intervalChoice,
                      (1...100_000).contains(interval) else { throw ShikeError.message("整数日提醒间隔请填写 1–100000 的整数。") }
                entry.reminder.dayInterval = interval
            }
            guard dateConfirmed else { throw ShikeError.message("请先补全日期。") }
            try entry.validate()
            if let onSave { try onSave(entry); dismiss(); return }
            try store.save(entry, expectedRevision: expectedRevision)
        }
        catch { self.error = error.localizedDescription; return }
        saving = true
        Task {
            if entry.reminder.isEnabled { await reminders.requestAccess() }
            await reminders.replan(store.entries)
            dismiss()
        }
    }
}

private struct CountdownCategoriesView: View {
    @ObservedObject var store: CountdownStore
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var editing: UUID?
    @State private var deleting: CountdownCategory?
    @State private var error: String?
    var body: some View {
        NavigationStack {
            ZStack { PaperBackground(); ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    PaperCard {
                        VStack(alignment: .leading, spacing: 12) {
                            Text(editing == nil ? "新增分类" : "修改分类").font(Notebook.handwriting(24))
                            TextField("分类名称", text: $name).accessibilityIdentifier("countdownCategoryName")
                            Button(editing == nil ? "添加分类" : "保存分类") {
                                do { try store.saveCategory(CountdownCategory(id: editing ?? UUID(), name: name)); name = ""; editing = nil; error = nil }
                                catch { self.error = error.localizedDescription }
                            }.buttonStyle(InkButtonStyle()).disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                            if editing != nil { Button("取消修改") { editing = nil; name = "" } }
                        }
                    }
                    if let error { NoteMessage(text: error, isError: true) }
                    ForEach(store.categories) { item in
                        PaperCard { HStack {
                            Text(item.name).font(Notebook.handwriting(24)); Spacer()
                            Button { editing = item.id; name = item.name } label: { Image(systemName: "pencil").frame(width: 44, height: 44) }.accessibilityLabel("修改\(item.name)")
                            Button(role: .destructive) { deleting = item } label: { Image(systemName: "trash").frame(width: 44, height: 44) }.accessibilityLabel("删除\(item.name)")
                        } }
                    }
                    Text("删除分类后，其中的日子会移到「未分类」。").font(.caption).foregroundStyle(Notebook.secondaryInk)
                }.padding(22)
            } }.foregroundStyle(Notebook.ink).navigationTitle("倒数日分类").navigationBarTitleDisplayMode(.inline)
                .toolbar { ToolbarItem(placement: .confirmationAction) { Button("完成") { dismiss() } } }
                .alert("删除这个分类？", isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } })) {
                    Button("删除", role: .destructive) {
                        do { if let deleting { try store.delete(deleting.id) }; editing = nil; name = "" } catch { self.error = error.localizedDescription }
                        deleting = nil
                    }
                    Button("取消", role: .cancel) { deleting = nil }
                } message: { Text("日子仍会保留，移到「未分类」。") }
        }.tint(Notebook.accent)
    }
}

private func lunarDescription(_ entry: Countdown) -> String {
    guard let lunar = CountdownDates.lunarDate(entry) else { return "农历" }
    let months = ["正", "二", "三", "四", "五", "六", "七", "八", "九", "十", "冬", "腊"]
    return "农历\(lunar.isLeapMonth ? "闰" : "")\(months[max(0, min(11, lunar.month - 1))])月\(lunar.day)日"
}

struct CountdownImageExport: Identifiable {
    let id = UUID()
    let title: String
    let image: UIImage
    let data: Data
    let url: URL
    let entry: Countdown
    let category: String?
    let now: Date
    let art: CountdownArtwork
    let value: CountdownDisplayValue
    @MainActor static func make(entry: Countdown, category: String?, now: Date = .now, art: CountdownArtwork = .preferred, unit: CountdownCountUnit = .days) throws -> Self {
        var entry = entry
        // Freeze the system zone together with the date and unit for preview/artwork changes.
        entry.timeZoneIdentifier = entry.timeZone().identifier
        let value = CountdownDisplayValue(entry, now: now, unit: unit)
        let content = CountdownShareCard(entry: entry, category: category, now: now, art: art, value: value)
            .foregroundStyle(Notebook.ink).environment(\.colorScheme, .light).environment(\.dynamicTypeSize, .large)
        let renderer = ImageRenderer(content: content); renderer.scale = 2; renderer.isOpaque = true
        guard let image = renderer.uiImage, let data = image.pngData() else { throw ShikeError.message("图片生成失败，请重试。") }
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("CountdownImages", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        // Retain a shared file long enough for the receiving app to copy it.
        for file in (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.contentModificationDateKey])) ?? [] {
            if let modified = try? file.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate,
               modified < now.addingTimeInterval(-86_400) { try? FileManager.default.removeItem(at: file) }
        }
        let url = folder.appendingPathComponent("Shike_Countdown_\(UUID().uuidString).png")
        try data.write(to: url, options: .atomic)
        return Self(title: entry.title, image: image, data: data, url: url, entry: entry, category: category, now: now, art: art, value: value)
    }
}

/// A dedicated portrait keeps shared keepsakes independent of the list layout.
private struct CountdownShareCard: View {
    let entry: Countdown
    let category: String?
    let now: Date
    let art: CountdownArtwork
    let value: CountdownDisplayValue
    var chooseArtwork: (() -> Void)?
    private var note: String {
        let value = entry.notes.trimmingCharacters(in: .whitespacesAndNewlines)
        return value.count > 240 ? String(value.prefix(240)) + "…" : value
    }
    private func dateText(_ date: Date, format: String) -> String {
        let formatter = DateFormatter(); formatter.locale = Locale(identifier: "zh_CN")
        formatter.calendar = Calendar(identifier: .gregorian); formatter.timeZone = entry.timeZone()
        formatter.dateFormat = format
        return formatter.string(from: date)
    }
    private var nextOccurrence: Date? {
        guard entry.recurrence != .none else { return nil }
        return entry.targetTime == nil ? CountdownDates.next(entry, onOrAfter: now) : CountdownDates.nextInstant(entry, onOrAfter: now)
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            HStack(alignment: .center) {
                Text(category ?? "值得记住的日子")
                    .font(Notebook.handwriting(21)).padding(.horizontal, 14).padding(.vertical, 7)
                    .background(Notebook.green.opacity(0.35), in: RoundedRectangle(cornerRadius: 5))
                    .rotationEffect(.degrees(-2))
                Spacer(minLength: 18)
                CalendarDoodle().scaleEffect(0.7).frame(width: 60, height: 60)
            }
            Text(entry.title).font(Notebook.handwriting(36)).fixedSize(horizontal: false, vertical: true)
            VStack(alignment: .leading, spacing: 12) {
                if value.unit == .days {
                    Text(value.label)
                        .font(Notebook.handwriting(entry.targetTime == nil ? 50 : 38))
                        .monospacedDigit().foregroundStyle(Notebook.blue).fixedSize(horizontal: false, vertical: true)
                } else { CountdownCountColumns(value: value, numberSize: 50) }
                Capsule().fill(Notebook.yellow).frame(width: 96, height: 7).rotationEffect(.degrees(-2))
                if entry.includesStartDay == true {
                    Text(entry.targetTime != nil && CountdownDates.elapsedDays(entry, now: now) >= 1
                         ? "含起始日 · 第 \(CountdownDates.elapsedDays(entry, now: now)) 天" : "包含起始日")
                        .font(Notebook.handwriting(18)).foregroundStyle(Notebook.secondaryInk)
                }
            }.padding(.vertical, 8)
                .accessibilityElement(children: .ignore).accessibilityLabel(value.label).accessibilityIdentifier("exportCountdownCount")
            VStack(alignment: .leading, spacing: 10) {
                Text(entry.recurrence == .none ? "记住这一天" : "最初的日子").font(Notebook.handwriting(18)).foregroundStyle(Notebook.secondaryInk)
                if let anchor = entry.anchorDate.date(in: entry.timeZone()) {
                    Text(dateText(anchor, format: "yyyy 年 M 月 d 日  EEEE")).font(Notebook.handwriting(24))
                }
                if let time = entry.targetTime { Text(time.description).font(Notebook.handwriting(23)).monospacedDigit() }
                if entry.calendar == .chinese { Text(lunarDescription(entry)).font(Notebook.handwriting(20)) }
                if let next = nextOccurrence {
                    Text("\(entry.recurrence.title) · 下一次 " + dateText(next, format: entry.targetTime == nil ? "yyyy-MM-dd" : "yyyy-MM-dd HH:mm:ss"))
                        .font(Notebook.handwriting(20)).fixedSize(horizontal: false, vertical: true)
                }
            }
            if !note.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    Text(entry.notes.trimmingCharacters(in: .whitespacesAndNewlines).count > 240 ? "写给这一天 · 摘录" : "写给这一天")
                        .font(Notebook.handwriting(18)).foregroundStyle(Notebook.secondaryInk)
                    Text(note).font(Notebook.handwriting(21)).lineSpacing(5).lineLimit(8).fixedSize(horizontal: false, vertical: true)
                }.padding(.top, 4)
            }
            Spacer(minLength: 0)
            if let chooseArtwork {
                Button(action: chooseArtwork) {
                    Image(art.asset).resizable().scaledToFit().frame(width: 310, height: 207).contentShape(Rectangle())
                }.buttonStyle(.plain).frame(maxWidth: .infinity)
                    .accessibilityLabel("更换插画，\(art.title)").accessibilityIdentifier("chooseCountdownArtwork")
            } else {
                Image(art.asset).resizable().scaledToFit().frame(width: 310, height: 207)
                    .frame(maxWidth: .infinity).accessibilityHidden(true)
            }
            HStack(alignment: .bottom, spacing: 16) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("拾刻计划").font(Notebook.handwriting(28))
                    Text("把期待，写进日子。").font(Notebook.handwriting(17))
                }
                Spacer(minLength: 0)
                VStack(alignment: .trailing, spacing: 5) {
                    Text("记录于 " + dateText(now, format: "yyyy-MM-dd HH:mm:ss"))
                    Text(TimeZoneOption.offsetTitle(entry.timeZone().secondsFromGMT(for: now)))
                }.font(.system(size: 12)).foregroundStyle(Notebook.secondaryInk)
            }
        }.frame(minHeight: 768).padding(36).frame(width: 560)
            .background { PaperBackground() }
            .overlay { PencilBorder().stroke(Notebook.ink.opacity(0.25), lineWidth: 1.2).padding(14) }
    }
}

private struct CountdownImagePreview: View {
    @State private var export: CountdownImageExport
    @State private var choosingArt = false
    init(export: CountdownImageExport) { _export = State(initialValue: export) }
    @Environment(\.dismiss) private var dismiss
    @State private var message: String?
    @State private var failed = false
    var body: some View {
        NavigationStack {
            ZStack { PaperBackground(); ScrollView {
                VStack(spacing: 22) {
                    GeometryReader { geometry in
                        CountdownShareCard(entry: export.entry, category: export.category, now: export.now,
                                           art: export.art, value: export.value, chooseArtwork: { choosingArt = true })
                            .foregroundStyle(Notebook.ink).environment(\.colorScheme, .light).environment(\.dynamicTypeSize, .large)
                            .fixedSize().scaleEffect(geometry.size.width / 560, anchor: .topLeading)
                            .frame(width: geometry.size.width, height: geometry.size.height, alignment: .topLeading)
                    }.aspectRatio(export.image.size.width / export.image.size.height, contentMode: .fit)
                    ShareLink(item: export.url, preview: SharePreview(export.title, image: Image(uiImage: export.image))) {
                        Label("分享图片", systemImage: "square.and.arrow.up")
                    }.buttonStyle(InkButtonStyle()).accessibilityIdentifier("shareCountdownPNG")
                    if let message { NoteMessage(text: message, isError: failed) }
                }.padding(22).frame(maxWidth: 680).frame(maxWidth: .infinity)
            } }.navigationTitle("卡片图片").navigationBarTitleDisplayMode(.inline)
                .toolbar { ToolbarItem(placement: .confirmationAction) { Button("完成") { dismiss() }.accessibilityIdentifier("closeCountdownExport") } }
                .sheet(isPresented: $choosingArt) {
                    CountdownArtworkPicker(selected: export.art) { art in
                        do {
                            let next = try CountdownImageExport.make(entry: export.entry, category: export.category, now: export.now, art: art, unit: export.value.unit)
                            export = next; art.remember(); message = nil
                        } catch { message = error.localizedDescription; failed = true }
                    }.workspaceSheet()
                }
        }.tint(Notebook.accent)
    }
}
