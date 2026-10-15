import SwiftUI
import AppIntents
import UniformTypeIdentifiers
import ShikeCore

struct ExtractScheduleImageIntent: AppIntent {
    static var title: LocalizedStringResource = "识别图片并提取日程"
    static var description = IntentDescription("接收「截屏」操作的图片，在设备上识别文字，然后打开拾刻计划提取日程，核对后加入日历。")
    static var openAppWhenRun = true
    @Parameter(title: "图片") var image: IntentFile
    static var parameterSummary: some ParameterSummary { Summary("识别\(\.$image)并提取日程") }
    @MainActor func perform() async throws -> some IntentResult & ProvidesDialog {
        if let url = image.fileURL, let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize, size > 30_000_000 {
            throw ShikeError.message("图片超过 30 MB，请裁剪后重试。")
        }
        let data = image.data
        guard data.count <= 30_000_000 else { throw ShikeError.message("图片超过 30 MB，请裁剪后重试。") }
        let text = try await OCRService.recognize(data)
        try Task.checkCancellation()
        try ShortcutInbox.shared.enqueue(text: text, source: "捷径图片")
        return .result(dialog: "文字已识别，请在拾刻计划核对提取出的日程。")
    }
}

struct ExtractScheduleTextIntent: AppIntent {
    static var title: LocalizedStringResource = "从文字提取日程"
    static var description = IntentDescription("接收文字、剪贴板或「听写文本」的内容，打开拾刻计划提取日程。")
    static var openAppWhenRun = true
    @Parameter(title: "日程内容") var text: String
    static var parameterSummary: some ParameterSummary { Summary("从\(\.$text)提取日程") }
    @MainActor func perform() async throws -> some IntentResult & ProvidesDialog {
        try Task.checkCancellation()
        try ShortcutInbox.shared.enqueue(text: text, source: "捷径文字")
        return .result(dialog: "已导入，请在拾刻计划核对提取出的日程。")
    }
}

struct ShikeShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(intent: ExtractScheduleImageIntent(), phrases: ["用\(.applicationName)识别日程图片"], shortTitle: "图片提取日程", systemImageName: "text.viewfinder")
        AppShortcut(intent: ExtractScheduleTextIntent(), phrases: ["用\(.applicationName)记录安排"], shortTitle: "文字提取日程", systemImageName: "calendar.badge.plus")
    }
    static var shortcutTileColor: ShortcutTileColor { .blue }
}

struct ShortcutGuideView: View {
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        NavigationStack {
            ZStack { PaperBackground(); ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    MarginTitle(title: "把当前页面，变成安排", subtitle: "在系统「快捷指令」中组合两个操作。")
                    PaperCard {
                        VStack(alignment: .leading, spacing: 14) {
                            Label("1. 截屏", systemImage: "camera.viewfinder")
                            Label("2. 拾刻计划 → 识别图片并提取日程", systemImage: "text.viewfinder")
                            Text("将上一步的截屏作为图片传入。运行后会打开拾刻计划，识别文字并提取日程，核对后即可加入日历。")
                                .font(.subheadline).foregroundStyle(Notebook.secondaryInk)
                        }
                    }
                    Text("也可以把「听写文本」或「获取剪贴板」连接到「从文字提取日程」。").font(.subheadline)
                    Text("保存捷径后，可在系统设置中将它绑定到操作按钮或轻点背面。请在需要识别的页面触发；拾刻计划不会持续读取屏幕。").font(.subheadline)
                    Link(destination: URL(string: "shortcuts://")!) { Label("打开快捷指令", systemImage: "arrow.up.forward.app") }.buttonStyle(InkButtonStyle())
                }.padding(22).frame(maxWidth: 680).frame(maxWidth: .infinity)
            } }.foregroundStyle(Notebook.ink).navigationTitle("捷径导入").navigationBarTitleDisplayMode(.inline)
                .toolbar { ToolbarItem(placement: .confirmationAction) { Button("完成") { dismiss() } } }
        }.tint(Notebook.accent)
    }
}
