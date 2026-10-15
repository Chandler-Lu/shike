import SwiftUI

enum WorkspaceSection: Int, CaseIterable, Identifiable {
    case home = 0, calendar = 3, countdowns = 4, history = 1, settings = 2
    var id: Int { rawValue }
    var title: String {
        switch self { case .home: "导入"; case .calendar: "日历"; case .countdowns: "倒数日"; case .history: "记录"; case .settings: "设置" }
    }
    var symbol: String {
        switch self { case .home: "square.and.pencil"; case .calendar: "calendar"; case .countdowns: "heart.text.clipboard"; case .history: "book.closed"; case .settings: "slider.horizontal.3" }
    }
}

@MainActor final class Workspace: ObservableObject {
    enum Action { case new, files, paste, search }
    struct Request: Identifiable { let id = UUID(); let action: Action; let section: Int }
    @Published var selection = 0 {
        didSet { if let pending, pending.section != selection { self.pending = nil } }
    }
    @Published var pending: Request?
    @Published var sidebarOverride: Bool?
    func perform(_ action: Action) {
        if action == .files || action == .paste { selection = 0 }
        if action == .new && selection != 4 { selection = 0 }
        if action == .search && selection != 1 && selection != 4 { selection = 4 }
        pending = Request(action: action, section: selection)
    }
    func consume(_ id: UUID) { if pending?.id == id { pending = nil } }
}

struct WorkspaceCommands: Commands {
    @ObservedObject var workspace: Workspace
    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Button("新建") { workspace.perform(.new) }.keyboardShortcut("n")
            Button("导入图片或文字文件…") { workspace.perform(.files) }.keyboardShortcut("o")
            Button("从剪贴板导入") { workspace.perform(.paste) }.keyboardShortcut("v", modifiers: [.command, .shift])
        }
        CommandGroup(replacing: .appSettings) {
            Button("设置…") { workspace.selection = 2 }.keyboardShortcut(",")
        }
        CommandMenu("前往") {
            ForEach(Array(WorkspaceSection.allCases.enumerated()), id: \.element.id) { index, section in
                Button(section.title) { workspace.selection = section.id }
                    .keyboardShortcut(KeyEquivalent(Character(String(index + 1))))
            }
            Divider()
            Button("搜索") { workspace.perform(.search) }.keyboardShortcut("f")
        }
    }
}

struct WorkspaceSidebar: View {
    @ObservedObject var workspace: Workspace
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("拾刻计划").font(Notebook.handwriting(30)).padding(.top, 28)
            Text("把日子，慢慢写好。").font(.caption).foregroundStyle(Notebook.secondaryInk).padding(.bottom, 24)
            ForEach(WorkspaceSection.allCases) { section in
                Button { workspace.selection = section.id } label: {
                    Label(section.title, systemImage: section.symbol)
                        .font(.body.weight(workspace.selection == section.id ? .semibold : .regular))
                        .frame(maxWidth: .infinity, alignment: .leading).padding(14)
                        .foregroundStyle(workspace.selection == section.id ? Notebook.accent : Notebook.ink)
                        .background(workspace.selection == section.id ? Notebook.accent.opacity(0.1) : .clear, in: RoundedRectangle(cornerRadius: 12))
                        .contentShape(Rectangle())
                }.buttonStyle(.plain).accessibilityIdentifier("section-\(section.id)")
                    .accessibilityAddTraits(workspace.selection == section.id ? .isSelected : [])
            }
            Spacer()
            CalendarDoodle().scaleEffect(0.8).frame(maxWidth: .infinity).accessibilityHidden(true)
        }.padding(18).background(Notebook.paper).overlay(alignment: .trailing) { Divider() }
    }
}
