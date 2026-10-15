import UIKit
import SwiftUI
import ShikeCore

/// Share extensions only stage input. Long model requests run in the containing app.
final class ShareViewController: UIViewController {
    private let state = ShareInputState()
    private var loading: Task<Void, Never>?
    override func viewDidLoad() {
        super.viewDidLoad()
        #if targetEnvironment(macCatalyst)
        preferredContentSize = CGSize(width: 620, height: 540)
        #endif
        let host = UIHostingController(rootView: ShareRootView(state: state) { [weak self] in
            self?.loading?.cancel(); self?.extensionContext?.completeRequest(returningItems: nil)
        })
        addChild(host); view.addSubview(host.view); host.view.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([host.view.leadingAnchor.constraint(equalTo: view.leadingAnchor), host.view.trailingAnchor.constraint(equalTo: view.trailingAnchor), host.view.topAnchor.constraint(equalTo: view.topAnchor), host.view.bottomAnchor.constraint(equalTo: view.bottomAnchor)])
        host.didMove(toParent: self)
        let providers = (extensionContext?.inputItems as? [NSExtensionItem] ?? []).flatMap { $0.attachments ?? [] }
        loading = Task {
            var staged: [String] = []
            do {
                let (text, images) = try await ItemLoader.load(providers)
                staged = images
                try Task.checkCancellation()
                try ShortcutInbox.shared.enqueue(text: text, source: "分享", images: images)
                staged = [] // Ownership is transferred to the durable inbox.
                state.saved = true
            } catch {
                staged.forEach(ImageStaging.remove)
                if !(error is CancellationError) { state.error = error.localizedDescription }
            }
            state.loading = false
        }
    }
}

@MainActor final class ShareInputState: ObservableObject {
    @Published var loading = true
    @Published var saved = false
    @Published var error: String?
}
struct ShareRootView: View {
    @ObservedObject var state: ShareInputState
    let finish: () -> Void
    var body: some View {
        NavigationStack {
            ZStack { PaperBackground(); VStack(alignment: .leading, spacing: 24) {
                CalendarDoodle()
                MarginTitle(title: "把这一刻，记下来", subtitle: state.saved ? "已保存，请打开拾刻计划继续。" : "正在读取分享内容…")
                if state.loading { ProgressView() }
                if state.saved { Text("打开主 App 后会识别图片、提取日程。核对内容后，再加入日历。").foregroundStyle(Notebook.secondaryInk) }
                if let error = state.error { NoteMessage(text: error, isError: true) }
                Button(state.saved ? "完成" : "关闭", action: finish).buttonStyle(InkButtonStyle())
            }.padding(28).frame(maxWidth: 620) }.navigationTitle("拾刻计划").navigationBarTitleDisplayMode(.inline)
        }.tint(Notebook.accent)
    }
}
