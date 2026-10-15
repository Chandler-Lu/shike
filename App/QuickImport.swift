import UIKit
import Photos
import UserNotifications
import ShikeCore

enum QuickImportAction: String {
    case clipboard = "com.chandler.shike.import.clipboard"
    case latestPhoto = "com.chandler.shike.import.latest-photo"
}

@MainActor final class QuickImportRouter: ObservableObject {
    static let shared = QuickImportRouter()
    struct Request: Identifiable { let id = UUID(); let action: QuickImportAction }
    @Published private(set) var pending: Request?
    func receive(_ item: UIApplicationShortcutItem) -> Bool {
        guard let action = QuickImportAction(rawValue: item.type) else { return false }
        pending = Request(action: action); return true
    }
    func consume(_ id: UUID) { if pending?.id == id { pending = nil } }
}

extension Notification.Name { static let shikeCloudPush = Notification.Name("shikeCloudPush") }

final class QuickActionAppDelegate: NSObject, UIApplicationDelegate {
    func application(_ application: UIApplication, didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        UNUserNotificationCenter.current().delegate = ModelJobNotificationDelegate.shared
        return true
    }
    func application(_ application: UIApplication, didReceiveRemoteNotification userInfo: [AnyHashable: Any],
                     fetchCompletionHandler completionHandler: @escaping (UIBackgroundFetchResult) -> Void) {
        Task { @MainActor in
            guard let sync = CountdownBackgroundSync.current else { completionHandler(.noData); return }
            await sync.synchronizeNow()
            completionHandler(.newData)
        }
    }
    func application(_ application: UIApplication, configurationForConnecting session: UISceneSession,
                     options: UIScene.ConnectionOptions) -> UISceneConfiguration {
        let config = UISceneConfiguration(name: nil, sessionRole: session.role)
        config.delegateClass = QuickActionSceneDelegate.self
        return config
    }
}

final class QuickActionSceneDelegate: NSObject, UIWindowSceneDelegate {
    func scene(_ scene: UIScene, willConnectTo session: UISceneSession, options connectionOptions: UIScene.ConnectionOptions) {
        #if targetEnvironment(macCatalyst)
        if let window = scene as? UIWindowScene {
            window.sizeRestrictions?.minimumSize = CGSize(width: 640, height: 600)
        }
        #endif
        if let item = connectionOptions.shortcutItem { _ = QuickImportRouter.shared.receive(item) }
    }
    func windowScene(_ windowScene: UIWindowScene, performActionFor shortcutItem: UIApplicationShortcutItem,
                     completionHandler: @escaping (Bool) -> Void) {
        completionHandler(QuickImportRouter.shared.receive(shortcutItem))
    }
}

enum LatestPhotoImporter {
    static func load() async throws -> (Data, Bool) {
        var status = PHPhotoLibrary.authorizationStatus(for: .readWrite)
        if status == .notDetermined { status = await PHPhotoLibrary.requestAuthorization(for: .readWrite) }
        guard status == .authorized || status == .limited else {
            throw ShikeError.message("没有照片读取权限。可点击首页相册手动选图，或在系统设置中允许拾刻计划读取照片。")
        }
        let options = PHFetchOptions()
        options.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: false)]
        options.fetchLimit = 1
        guard let asset = PHAsset.fetchAssets(with: .image, options: options).firstObject else {
            throw ShikeError.message(status == .limited ? "已授权的照片中没有可用图片，请通过首页相册选择。" : "相册里还没有图片，请先拍照或保存一张图片。")
        }
        let state = PhotoRequestState()
        let data: Data = try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                state.install(continuation)
                let request = PHImageRequestOptions()
                request.isNetworkAccessAllowed = true
                request.deliveryMode = .highQualityFormat
                let id = PHImageManager.default().requestImageDataAndOrientation(for: asset, options: request) { data, _, _, info in
                    if (info?[PHImageCancelledKey] as? Bool) == true { state.finish(.failure(CancellationError())) }
                    else if info?[PHImageErrorKey] != nil { state.finish(.failure(ShikeError.message("无法读取最近图片，可能还在 iCloud 中。请检查网络后重试，或从相册手动选择。"))) }
                    else if let data, !data.isEmpty {
                        if data.count > 30_000_000 { state.finish(.failure(ShikeError.message("最近图片超过 30 MB，请从相册选择较小图片。"))) }
                        else { state.finish(.success(data)) }
                    } else { state.finish(.failure(ShikeError.message("最近图片暂时无法读取，请重试或从相册手动选择。"))) }
                }
                state.setID(id)
            }
        } onCancel: { state.cancel() }
        try Task.checkCancellation()
        return (data, status == .limited)
    }
}

/// Cancellation can race request creation and callback delivery; resume exactly once.
private final class PhotoRequestState: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Data, Error>?
    private var result: Result<Data, Error>?
    private var id: PHImageRequestID?
    private var cancelled = false
    func install(_ value: CheckedContinuation<Data, Error>) {
        lock.lock()
        if let result { lock.unlock(); value.resume(with: result) }
        else { continuation = value; lock.unlock() }
    }
    func setID(_ value: PHImageRequestID) {
        lock.lock(); id = value; let cancel = cancelled; lock.unlock()
        if cancel { PHImageManager.default().cancelImageRequest(value) }
    }
    func finish(_ value: Result<Data, Error>) {
        lock.lock()
        guard result == nil else { lock.unlock(); return }
        result = value; let pending = continuation; continuation = nil; lock.unlock()
        pending?.resume(with: value)
    }
    func cancel() {
        lock.lock(); cancelled = true; let id = id; lock.unlock()
        finish(.failure(CancellationError()))
        if let id { PHImageManager.default().cancelImageRequest(id) }
    }
}
