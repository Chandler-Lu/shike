import UIKit
import SwiftUI
import ShikeCore

final class ShareViewController: UIViewController {
    private let environment = AppEnvironment()
    private var controller: ImportController!
    private var loading: Task<Void, Never>?

    override func viewDidLoad() {
        super.viewDidLoad()
        #if targetEnvironment(macCatalyst)
        preferredContentSize = CGSize(width: 720, height: 780)
        #endif
        controller = ImportController(environment: environment, session: ImportSession(source: "分享"))
        let root = ShareRootView(controller: controller, finish: { [weak self] in self?.finish() })
        let host = UIHostingController(rootView: root)
        addChild(host); view.addSubview(host.view)
        host.view.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([host.view.leadingAnchor.constraint(equalTo: view.leadingAnchor), host.view.trailingAnchor.constraint(equalTo: view.trailingAnchor), host.view.topAnchor.constraint(equalTo: view.topAnchor), host.view.bottomAnchor.constraint(equalTo: view.bottomAnchor)])
        host.didMove(toParent: self)
        let providers = (extensionContext?.inputItems as? [NSExtensionItem] ?? []).flatMap { $0.attachments ?? [] }
        loading = Task {
            do {
                if let error = environment.startupError { throw ShikeError.message(error) }
                controller.busyMessage = "正在读取分享内容…"
                let (text, images) = try await ItemLoader.load(providers)
                try Task.checkCancellation()
                controller.busyMessage = nil
                if images.isEmpty { controller.appendText(text, source: "分享") }
                else { controller.importImageFiles(images, source: "分享", appendedText: text) }
            } catch { controller.busyMessage = nil; controller.errorMessage = error.localizedDescription }
        }
    }
    private func finish() {
        loading?.cancel()
        controller.cancel()
        do {
            try controller.persist()
            extensionContext?.completeRequest(returningItems: nil)
        } catch { controller.errorMessage = error.localizedDescription }
    }
}

struct ShareRootView: View {
    @ObservedObject var controller: ImportController
    let finish: () -> Void
    var body: some View {
        NavigationStack {
            ZStack {
                PaperBackground()
                ScrollView {
                    VStack(alignment: .leading, spacing: 20) {
                        MarginTitle(title: "把这一刻，记下来", subtitle: "识别、核对，然后放进日历。")
                        if controller.environment.preferences.configuration.model.isEmpty && !AppIdentity.usesFixtureModel {
                            NoteMessage(text: "请先打开拾刻计划，在设置中填写模型接口和 API Key。本次内容可先保存为草稿。", isError: true)
                        }
                        ImportFlowView(controller: controller, calendars: controller.environment.calendars, isExtension: true)
                    }.padding(22).frame(maxWidth: 680).frame(maxWidth: .infinity)
                }.scrollDismissesKeyboard(.interactively)
            }.navigationTitle("拾刻计划").navigationBarTitleDisplayMode(.inline)
                .toolbar { ToolbarItem(placement: .topBarTrailing) {
                    Button(controller.session.savedCount > 0 ? "完成" : "存草稿并关闭", action: finish)
                        .disabled(controller.busyMessage?.contains("加入日历") == true)
                } }
        }.tint(Notebook.accent)
    }
}
