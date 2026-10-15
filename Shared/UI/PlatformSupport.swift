import SwiftUI
import UIKit

enum PlatformSupport {
    static var isMac: Bool {
        #if targetEnvironment(macCatalyst)
        true
        #else
        false
        #endif
    }
    static func lightFeedback() {
        #if !targetEnvironment(macCatalyst)
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        #endif
    }
}

private struct WorkspaceWidthKey: EnvironmentKey { static let defaultValue: CGFloat = 0 }
extension EnvironmentValues {
    var workspaceWidth: CGFloat {
        get { self[WorkspaceWidthKey.self] }
        set { self[WorkspaceWidthKey.self] = newValue }
    }
}

extension View {
    /// UIKit sheets already adapt to iPad. Catalyst needs a usable initial canvas.
    @ViewBuilder func workspaceSheet() -> some View {
        #if targetEnvironment(macCatalyst)
        self.frame(minWidth: 560, idealWidth: 720, minHeight: 540, idealHeight: 740)
        #else
        self
        #endif
    }
}

/// Keep one TabView alive while hiding its native bar beside our wide sidebar.
/// On iPadOS 18+ the bar can live in the title area, outside SwiftUI's tabBar toolbar.
struct WorkspaceTabBarVisibility: UIViewControllerRepresentable {
    let hidden: Bool
    func makeUIViewController(context: Context) -> Probe { Probe() }
    func updateUIViewController(_ controller: Probe, context: Context) {
        controller.hidesBar = hidden
        DispatchQueue.main.async { [weak controller] in controller?.apply() }
    }
    final class Probe: UIViewController {
        var hidesBar = false
        override func viewDidAppear(_ animated: Bool) { super.viewDidAppear(animated); apply() }
        override func viewDidLayoutSubviews() { super.viewDidLayoutSubviews(); apply() }
        func apply() {
            func find(_ controller: UIViewController) -> UITabBarController? {
                if let tabs = controller as? UITabBarController { return tabs }
                for child in controller.children { if let tabs = find(child) { return tabs } }
                return nil
            }
            guard let root = view.window?.rootViewController, let tabs = find(root) else { return }
            if #available(iOS 18.0, *) {
                if tabs.isTabBarHidden != hidesBar { tabs.setTabBarHidden(hidesBar, animated: false) }
                if !PlatformSupport.isMac && UIDevice.current.userInterfaceIdiom == .pad {
                    if hidesBar {
                        if tabs.traitOverrides.contains(UITraitHorizontalSizeClass.self) {
                            tabs.traitOverrides.remove(UITraitHorizontalSizeClass.self)
                        }
                    } else if !tabs.traitOverrides.contains(UITraitHorizontalSizeClass.self) || tabs.traitOverrides.horizontalSizeClass != .compact {
                        tabs.traitOverrides.horizontalSizeClass = .compact
                    }
                }
            } else if tabs.tabBar.isHidden != hidesBar { tabs.tabBar.isHidden = hidesBar }
        }
    }
}
