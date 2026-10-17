import XCTest
import CloudKit
import ShikeCore
@testable import Shike

final class CountdownServiceTests: XCTestCase {
    @MainActor func testCardColorIsDurableAndQueuesSync() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("countdowns.json")
        let store = CountdownStore(url: url)
        var entry = Countdown(title: "彩色纪念日"); entry.cardColor = .sage
        try store.save(entry)
        let reopened = CountdownStore(url: url)
        XCTAssertEqual(reopened.entries.first?.cardColor, .sage)
        XCTAssertTrue(reopened.document.pending.contains(entry.id))
        entry.cardColor = nil
        try reopened.save(entry)
        XCTAssertNil(CountdownStore(url: url).entries.first?.cardColor)
    }
    @MainActor func testBatchMoveAndDeleteAreAtomicDurableAndPreserveUnselectedEntries() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("countdowns.json")
        let store = CountdownStore(url: url)
        var first = Countdown(title: "纪念日")
        first.notes = "保留备注"; first.pinned = true; first.reminder.milestones = [520, 1314]
        let second = Countdown(title: "生日"), untouched = Countdown(title: "不改变的日子")
        try store.insert([first, second, untouched])
        let ids: Set<UUID> = [first.id, second.id]
        let group = try XCTUnwrap(store.categories.first?.id)
        var changes = 0; store.onChange = { changes += 1 }
        let before = store.records
        XCTAssertThrowsError(try store.moveEntries(ids, to: UUID()))
        XCTAssertThrowsError(try store.deleteEntries(ids.union([UUID()])))
        XCTAssertEqual(store.records, before); XCTAssertEqual(changes, 0)
        try store.moveEntries(ids, to: group)
        XCTAssertEqual(changes, 1)
        let moved = try XCTUnwrap(store.entries.first { $0.id == first.id })
        first.categoryID = group
        XCTAssertEqual(moved, first)
        XCTAssertEqual(store.entries.first { $0.id == untouched.id }, untouched)
        XCTAssertTrue(ids.isSubset(of: store.document.pending))
        let reopened = CountdownStore(url: url)
        XCTAssertEqual(reopened.entries.filter { $0.categoryID == group }.count, 2)
        try reopened.moveEntries(ids, to: nil)
        XCTAssertTrue(reopened.entries.allSatisfy { $0.categoryID == nil })
        try reopened.deleteEntries(ids)
        let final = CountdownStore(url: url)
        XCTAssertEqual(final.entries, [untouched])
        XCTAssertTrue(final.records.filter { ids.contains($0.id) }.allSatisfy { $0.deleted && $0.countdown == nil })
        XCTAssertTrue(ids.isSubset(of: final.document.pending))
        XCTAssertThrowsError(try final.moveEntries(ids, to: group))
    }
    @MainActor func testCountdownRecognitionRequiresConsentForTheCurrentRecipient() throws {
        let name = "Shike.CountdownConsent.\(UUID())"
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        let preferences = Preferences(defaults: defaults)
        preferences.configuration = APIConfiguration(baseURL: "https://first.example", model: "fixture")
        let consent = ExtractionConsentStore(defaults: defaults)
        let controller = CountdownNaturalLanguageController(preferences: preferences, store: CountdownStore(inMemory: true), consent: consent)
        controller.text = "12 月 1 日去看海"
        controller.recognize()
        XCTAssertEqual(controller.consentRequest?.host, "first.example")
        XCTAssertFalse(controller.busy)
        XCTAssertFalse(controller.canSave)
        preferences.configuration = APIConfiguration(baseURL: "https://changed.example", model: "fixture")
        controller.allow()
        XCTAssertEqual(controller.consentRequest?.host, "changed.example")
        XCTAssertFalse(controller.busy)
        XCTAssertTrue(controller.drafts.isEmpty)
    }
    @MainActor func testNaturalLanguageBatchIsAtomicAndCannotOverwriteExistingRecords() throws {
        let store = CountdownStore(inMemory: true)
        let initial = store.records
        let valid = Countdown(title: "有效")
        XCTAssertThrowsError(try store.insert([valid, Countdown(title: "")]))
        XCTAssertEqual(store.records, initial)
        try store.insert([valid, Countdown(title: "第二个")])
        XCTAssertEqual(store.entries.count, 2)
        XCTAssertThrowsError(try store.insert([valid]))
        XCTAssertEqual(store.entries.count, 2)
    }
    @MainActor func testCardImageExportsARealPNGWithLongTitleAndSeconds() throws {
        var entry = Countdown(title: String(repeating: "一起看书 🐱 ", count: 20), date: CivilDate(year: 2026, month: 10, day: 14))
        entry.targetTime = CountdownTime(hour: 13, minute: 14, second: 52)
        entry.notes = String(repeating: "记住一起度过的日子。", count: 100)
        let output = try CountdownImageExport.make(entry: entry, category: "纪念日")
        defer { try? FileManager.default.removeItem(at: output.url) }
        XCTAssertEqual(Array(output.data.prefix(8)), [137,80,78,71,13,10,26,10])
        XCTAssertEqual(output.image.cgImage?.width, 1120)
        XCTAssertGreaterThanOrEqual(output.image.cgImage?.height ?? 0, 1680)
        XCTAssertLessThan(output.image.cgImage?.height ?? 0, 4000)
        XCTAssertEqual(try Data(contentsOf: output.url), output.data)
        let attachment = XCTAttachment(image: output.image); attachment.name = "portrait-card-long-title"; attachment.lifetime = .keepAlways
        add(attachment)

        // Keep the public sample generated by the same renderer as the exported card.
        var sample = Countdown(title: "下一次，一起去看海", date: CivilDate(year: 2026, month: 10, day: 29))
        sample.notes = "带上相机，也带上好心情。"
        let reference = ISO8601DateFormatter().date(from: "2026-10-17T09:41:00+08:00")!
        let card = try CountdownImageExport.make(entry: sample, category: "生活", now: reference, art: .original)
        defer { try? FileManager.default.removeItem(at: card.url) }
        let sampleImage = XCTAttachment(image: card.image)
        sampleImage.name = "portrait-card-promotion"; sampleImage.lifetime = .keepAlways; add(sampleImage)
    }

    func testCloudRejectionDiagnosticsPreserveStageWithoutPrivatePayload() {
        let error = NSError(domain: CKErrorDomain, code: CKError.serverRejectedRequest.rawValue,
                            userInfo: [NSLocalizedDescriptionKey: "PRIVATE-RECORD-CONTENT",
                                       NSUnderlyingErrorKey: NSError(domain: "CKInternalErrorDomain", code: 2000)])
        let result = CloudSyncFailure(error, operation: "创建倒数日云端空间", container: "iCloud.example.test")
        XCTAssertTrue(result.message.contains("创建倒数日云端空间"))
        XCTAssertTrue(result.message.contains("服务器拒绝"))
        XCTAssertTrue(result.diagnostic.contains("CKInternalErrorDomain(2000)"))
        XCTAssertFalse(result.diagnostic.contains("PRIVATE-RECORD-CONTENT"))
        XCTAssertFalse(result.automaticRetryAllowed)
    }
    func testPartialCloudFailurePreservesRetryPolicyAndDelay() {
        let child = NSError(domain: CKErrorDomain, code: CKError.requestRateLimited.rawValue, userInfo: [CKErrorRetryAfterKey: 120])
        let error = NSError(domain: CKErrorDomain, code: CKError.partialFailure.rawValue,
                            userInfo: [CKPartialErrorsByItemIDKey: ["private-record-id": child]])
        let result = CloudSyncFailure(error, operation: "上传倒数日", container: "iCloud.example.test")
        XCTAssertEqual(result.retryAfter, 120)
        XCTAssertTrue(result.automaticRetryAllowed)
        XCTAssertFalse(result.diagnostic.contains("private-record-id"))
    }
    func testCloudDiagnosticsIncludeNestedServerTraceButNoArbitraryMetadata() {
        let request = "DE40758E-F0C7-4116-8C5F-8FA72F22FEDA"
        let underlying = NSError(domain: "CKInternalErrorDomain", code: 2000, userInfo: [
            "CKHTTPStatus": 500, "RequestUUID": request, "OperationID": "EA7106B65094FB4F",
            "CKDHTTPHeaders": ["Authorization": "PRIVATE-TOKEN"], "ServerErrorDescription": "PRIVATE-CONTENT"
        ])
        let result = CloudSyncFailure(NSError(domain: CKErrorDomain, code: 15, userInfo: [NSUnderlyingErrorKey: underlying]), operation: "检查倒数日云端空间", container: "iCloud.example.test")
        XCTAssertTrue(result.diagnostic.contains("HTTP：500"))
        XCTAssertTrue(result.diagnostic.contains(request))
        XCTAssertTrue(result.diagnostic.contains("EA7106B65094FB4F"))
        XCTAssertTrue(result.diagnostic.contains("CKErrorDomain(15) → CKInternalErrorDomain(2000)"))
        XCTAssertFalse(result.diagnostic.contains("PRIVATE-"))
        XCTAssertFalse(result.message.contains("签名"))
    }
    func testCloudDiagnosticsRejectUnstructuredTraceValues() {
        let result = CloudSyncFailure(NSError(domain: CKErrorDomain, code: 15, userInfo: [
            "CKHTTPStatus": 9999, "RequestUUID": "PRIVATE-ACCOUNT", "OperationID": "PRIVATE RECORD CONTENT"
        ]), operation: "检查倒数日云端空间", container: "iCloud.example.test")
        XCTAssertFalse(result.diagnostic.contains("PRIVATE"))
        XCTAssertFalse(result.diagnostic.contains("9999"))
    }
    @MainActor func testPersistenceCategoryRemovalAndOfflineOutbox() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = folder.appendingPathComponent("countdowns.json"), store = CountdownStore(url: url)
        let category = CountdownCategory(name: "旅行")
        try store.saveCategory(category)
        var entry = Countdown(title: "出发"); entry.categoryID = category.id
        try store.save(entry)
        let revision = store.records.first { $0.id == entry.id }!.revision
        entry.pinned = true; try store.save(entry, expectedRevision: revision)
        XCTAssertThrowsError(try store.save(entry, expectedRevision: revision))
        let reopened = CountdownStore(url: url)
        XCTAssertEqual(reopened.entries.first?.pinned, true)
        XCTAssertTrue(reopened.document.pending.contains(entry.id))
        try reopened.delete(category.id)
        XCTAssertNil(reopened.entries.first?.categoryID)
        try reopened.delete(entry.id)
        let final = CountdownStore(url: url)
        XCTAssertTrue(final.entries.isEmpty)
        XCTAssertTrue(final.records.first { $0.id == entry.id }!.deleted)
        XCTAssertTrue(final.document.pending.contains(entry.id))
    }
    @MainActor func testCorruptStoreIsPreservedAndRejectsWrites() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let original = Data("not a valid document".utf8); try original.write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        let store = CountdownStore(url: url)
        XCTAssertNotNil(store.error)
        XCTAssertThrowsError(try store.save(Countdown(title: "不能覆盖原数据")))
        XCTAssertEqual(try Data(contentsOf: url), original)
    }
    @MainActor func testFirstSyncMergesAndChangedAccountCannotTakeOldData() throws {
        let a = CountdownStore(inMemory: true), b = CountdownStore(inMemory: true)
        let one = Countdown(title: "A"), two = Countdown(title: "B")
        try a.save(one); try b.save(two)
        try a.bindAccount("account-a"); try b.bindAccount("account-a")
        try a.merge(b.records); try b.merge(a.records)
        XCTAssertEqual(Set(a.entries.map(\.id)), Set([one.id, two.id]))
        XCTAssertEqual(Set(b.entries.map(\.id)), Set([one.id, two.id]))
        let before = a.document.pending
        XCTAssertThrowsError(try a.bindAccount("account-b"))
        XCTAssertEqual(a.document.accountID, "account-a")
        XCTAssertEqual(a.document.pending, before)
        XCTAssertNoThrow(try a.bindAccount("account-a"))
    }
    @MainActor func testRemoteDeletionOfflineConflictAndStaleAcknowledgement() throws {
        let a = CountdownStore(inMemory: true), b = CountdownStore(inMemory: true)
        var entry = Countdown(title: "开始")
        try a.save(entry); try b.merge(a.records)
        let sent = a.records.first { $0.id == entry.id }!
        entry.title = "发送时又编辑了"; try a.save(entry)
        try a.acknowledge(sent, fields: Data())
        XCTAssertTrue(a.document.pending.contains(entry.id))
        try b.merge(a.records)
        try b.delete(entry.id)
        try a.merge(b.records)
        XCTAssertTrue(a.entries.isEmpty)
        XCTAssertFalse(a.document.pending.contains(entry.id))
        try a.merge([sent])
        XCTAssertTrue(a.entries.isEmpty)
        XCTAssertTrue(a.document.pending.contains(entry.id), "Re-send the winning tombstone against stale remote content")
    }
    @MainActor func testReminderDenialReplacementAndCancellation() async throws {
        let center = NotificationFake(), service = CountdownReminderService(center: center)
        var entry = Countdown(title: "生日", date: CivilDate(.now.addingTimeInterval(172800)))
        entry.reminder.daysBefore = [0, 1]
        await service.replan([entry]); XCTAssertTrue(center.notices.isEmpty)
        XCTAssertTrue(service.status.contains("未获允许"))
        await service.requestAccess(); await service.replan([entry])
        XCTAssertEqual(center.notices.count, 2)
        entry.reminder.daysBefore = [0]; entry.title = "修改后的生日"
        await service.replan([entry]); XCTAssertEqual(center.notices.count, 1)
        XCTAssertEqual(center.notices.values.first?.title, "修改后的生日")
        await service.replan([]); XCTAssertTrue(center.notices.isEmpty)
        XCTAssertTrue(center.removed.allSatisfy { $0.hasPrefix("countdown.") })
    }
    @MainActor func testOverlappingReminderReplansCannotResurrectDeletedEntry() async {
        let center = NotificationFake(); center.access = true; center.slow = true
        let service = CountdownReminderService(center: center)
        var entry = Countdown(title: "将被删除", date: CivilDate(.now.addingTimeInterval(172800))); entry.reminder.daysBefore = [0]
        let task = Task { await service.replan([entry]) }
        await Task.yield()
        await service.replan([]); await task.value
        XCTAssertTrue(center.notices.isEmpty)
        XCTAssertTrue(service.scheduled.isEmpty)
    }
    @MainActor func testTurningSyncOffKeepsCountdownsAndPendingChanges() async throws {
        let defaults = UserDefaults(suiteName: UUID().uuidString)!
        let preferences = Preferences(defaults: defaults)
        let store = CountdownStore(inMemory: true); try store.save(Countdown(title: "离线日子"))
        let sync = CountdownSync(store: store, preferences: preferences)
        try preferences.setCloudEnabled(false)
        await Task.yield(); await sync.synchronizeNow()
        XCTAssertEqual(store.entries.count, 1)
        XCTAssertEqual(store.document.pending.count, 1)
        XCTAssertNil(store.document.accountID)
    }
}

@MainActor private final class NotificationFake: CountdownNotificationCenter {
    var access = false
    var slow = false
    var notices: [String: CountdownNotice] = [:]
    var removed: [String] = []
    func allowed() async -> Bool { access }
    func requestAccess() async throws -> Bool { access = true; return true }
    func pendingIDs() async -> [String] { Array(notices.keys) + ["another-feature"] }
    func remove(_ ids: [String]) { for id in ids { notices.removeValue(forKey: id) }; removed += ids }
    func add(_ notice: CountdownNotice) async throws {
        if slow { try await Task.sleep(for: .milliseconds(30)) }
        notices[notice.id] = notice
    }
}
