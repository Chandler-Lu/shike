import SwiftUI
import UIKit

@main struct ShikeApp: App {
    @UIApplicationDelegateAdaptor(QuickActionAppDelegate.self) private var appDelegate
    @StateObject private var environment: AppEnvironment
    init() {
        AppIdentity.configureDebugLaunch()
        #if DEBUG
        if AppIdentity.isUITesting {
            UserDefaults(suiteName: "Shike.UITests")?.removePersistentDomain(forName: "Shike.UITests")
            if ProcessInfo.processInfo.arguments.contains("-paste-fixture") {
                UIPasteboard.general.string = "明天下午两点开会，三楼会议室。"
            }
        }
        #endif
        _environment = StateObject(wrappedValue: AppEnvironment())
        #if DEBUG
        if CloudKitReadOnlyProbe.isRequested { Task { await CloudKitReadOnlyProbe.run() } }
        #endif
    }
    var body: some Scene {
        WindowGroup {
            if let error = environment.startupError {
                ZStack {
                    PaperBackground()
                    VStack(spacing: 24) {
                        CalendarDoodle()
                        MarginTitle(title: "还差一点准备", subtitle: "共享存储尚未就绪")
                        NoteMessage(text: error, isError: true)
                    }.padding(28)
                }
            } else { RootView(environment: environment) }
        }
    }
}
