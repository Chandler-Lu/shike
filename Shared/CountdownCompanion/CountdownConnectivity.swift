#if !targetEnvironment(macCatalyst)
import Foundation
import Combine
import WatchConnectivity
import WidgetKit
import ShikeCore

@MainActor final class CountdownConnectivity: NSObject, ObservableObject, WCSessionDelegate {
    @Published private(set) var snapshot: CountdownSnapshot?
    @Published private(set) var status: String?
    private var lastSentRevision: Int64?
    private var session: WCSession?
    override init() {
        super.init()
        #if DEBUG && os(watchOS)
        if ProcessInfo.processInfo.arguments.contains("-watch-fixture") {
            if ProcessInfo.processInfo.arguments.contains("-watch-reset-group") { UserDefaults.standard.removeObject(forKey: "watchCountdownGroup") }
            var future = Countdown(id: UUID(uuidString: "00000000-1111-4000-8000-000000000001")!, title: "下一次，一起去看海", date: CivilDate(Date.now.addingTimeInterval(12 * 86_400)))
            future.categoryID = CountdownCategory.defaults[2].id
            var past = Countdown(id: UUID(uuidString: "00000000-1111-4000-8000-000000000002")!, title: "和你在一起的日子", date: CivilDate(Date.now.addingTimeInterval(-365 * 86_400)))
            past.categoryID = CountdownCategory.defaults[0].id
            let fixture = CountdownSnapshot(entries: [future, past], categories: CountdownCategory.defaults, revision: Int64(Date.now.timeIntervalSince1970 * 1_000_000))
            snapshot = fixture; try? CountdownSnapshotStorage.write(fixture); return
        }
        #endif
        do { snapshot = try CountdownSnapshotStorage.read() }
        catch { status = "倒数日暂时无法读取，请重新同步。" }
        guard WCSession.isSupported() else { return }
        session = .default; session?.delegate = self; session?.activate()
    }
    func publish(_ value: CountdownSnapshot) {
        snapshot = value; push()
    }
    func refresh() {
        guard let session, session.activationState == .activated else { return }
        #if os(watchOS)
        if session.isReachable {
            session.sendMessage(["requestCountdowns": true], replyHandler: { [weak self] response in
                if let data = response["snapshot"] as? Data { Task { @MainActor in self?.receive(data) } }
            }, errorHandler: { [weak self] _ in Task { @MainActor in self?.status = "暂未连接 iPhone，显示已同步的日子。" } })
        } else { status = snapshot == nil ? "打开配对 iPhone 上的拾刻计划，开始同步。" : "显示已同步的日子" }
        #else
        push()
        #endif
    }
    private func push(force: Bool = false) {
        #if os(iOS)
        guard let session, session.activationState == .activated, session.isPaired, session.isWatchAppInstalled,
              let snapshot, force || lastSentRevision != snapshot.revision else { return }
        do {
            let data = try JSONEncoder().encode(snapshot)
            // The current-state message is intentionally kept below the WCSession message limit.
            if data.count <= 48_000 {
                try session.updateApplicationContext(["snapshot": data])
                for transfer in session.outstandingFileTransfers { transfer.cancel() }
            } else {
                let folder = try CountdownSnapshotStorage.directory().appendingPathComponent("WatchTransfers", isDirectory: true)
                try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                let url = folder.appendingPathComponent("\(snapshot.revision).json")
                try data.write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
                try session.updateApplicationContext(["revision": snapshot.revision])
                for transfer in session.outstandingFileTransfers { transfer.cancel() }
                session.transferFile(url, metadata: ["revision": snapshot.revision])
            }
            lastSentRevision = snapshot.revision; status = nil
        } catch { status = "手表同步暂未完成，将在下次连接时重试。" }
        #endif
    }
    private func receive(_ data: Data) {
        #if os(watchOS)
        do {
            let incoming = try CountdownSnapshotStorage.decode(data)
            guard snapshot == nil || snapshot!.accepts(incoming) else { return }
            try CountdownSnapshotStorage.write(incoming)
            snapshot = incoming; status = nil
            WidgetCenter.shared.reloadTimelines(ofKind: "ShikeCountdowns")
            WidgetCenter.shared.invalidateConfigurationRecommendations()
        } catch { status = "同步内容暂时无法读取，已保留上次的日子。" }
        #endif
    }
    nonisolated func session(_ session: WCSession, activationDidCompleteWith activationState: WCSessionActivationState, error: Error?) {
        let data = session.receivedApplicationContext["snapshot"] as? Data
        Task { @MainActor in
            if let data { receive(data) }
            if error != nil { status = "手表连接尚未就绪，稍后会自动重试。" }
            else { lastSentRevision = nil; refresh() }
        }
    }
    nonisolated func session(_ session: WCSession, didReceiveApplicationContext applicationContext: [String: Any]) {
        guard let data = applicationContext["snapshot"] as? Data else { return }
        Task { @MainActor in receive(data) }
    }
    nonisolated func session(_ session: WCSession, didReceive file: WCSessionFile) {
        // WCSession removes the incoming file after this delegate method returns.
        guard let data = try? Data(contentsOf: file.fileURL) else { return }
        Task { @MainActor in receive(data) }
    }
    nonisolated func session(_ session: WCSession, didFinish fileTransfer: WCSessionFileTransfer, error: Error?) {
        let url = fileTransfer.file.fileURL
        Task { @MainActor in
            if error != nil { lastSentRevision = nil; status = "手表同步暂未完成，将在下次连接时重试。" }
            // A forced resend may still reference this file.
            if session.outstandingFileTransfers.allSatisfy({ $0.file.fileURL != url }) { try? FileManager.default.removeItem(at: url) }
        }
    }
    nonisolated func session(_ session: WCSession, didReceiveMessage message: [String: Any], replyHandler: @escaping ([String: Any]) -> Void) {
        Task { @MainActor in
            #if os(iOS)
            guard message["requestCountdowns"] as? Bool == true, let snapshot,
                  let data = try? JSONEncoder().encode(snapshot) else { replyHandler([:]); return }
            if data.count <= 48_000 { replyHandler(["snapshot": data]) }
            else { push(force: true); replyHandler(["queued": true]) }
            #else
            replyHandler([:])
            #endif
        }
    }
    nonisolated func sessionReachabilityDidChange(_ session: WCSession) { Task { @MainActor in lastSentRevision = nil; refresh() } }
    #if os(iOS)
    nonisolated func sessionDidBecomeInactive(_ session: WCSession) {}
    nonisolated func sessionDidDeactivate(_ session: WCSession) { session.activate() }
    nonisolated func sessionWatchStateDidChange(_ session: WCSession) { Task { @MainActor in lastSentRevision = nil; refresh() } }
    #endif
}

#else
import ShikeCore

/// Mac publishes the same widget snapshot locally; Watch transport belongs to the paired iPhone.
@MainActor final class CountdownConnectivity {
    func publish(_ snapshot: CountdownSnapshot) {}
}
#endif
