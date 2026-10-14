import Foundation
import WidgetKit
import ShikeCore

@MainActor final class CountdownCompanionPublisher {
    private let connectivity: CountdownConnectivity?
    private var latest: CountdownSnapshot?
    private var enabled: Bool {
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("-companion-fixture") { return true }
        #endif
        return !AppIdentity.isUITesting
    }
    init() {
        #if DEBUG
        if AppIdentity.isUITesting && !ProcessInfo.processInfo.arguments.contains("-companion-fixture") { connectivity = nil; return }
        #endif
        connectivity = CountdownConnectivity()
        latest = try? CountdownSnapshotStorage.read()
    }
    func refresh(store: CountdownStore) {
        guard enabled, store.error == nil else { return }
        let revision = max((latest?.revision ?? 0) + 1, Int64(Date.now.timeIntervalSince1970 * 1_000_000))
        let snapshot = CountdownSnapshot(entries: store.entries, categories: store.categories, revision: revision)
        if let latest, latest.hasSameContent(as: snapshot) { connectivity?.publish(latest); return }
        do {
            try CountdownSnapshotStorage.write(snapshot); latest = snapshot
            WidgetCenter.shared.reloadTimelines(ofKind: "ShikeCountdowns")
            connectivity?.publish(snapshot)
        } catch { /* The source document remains authoritative; retry on the next refresh. */ }
    }
}
