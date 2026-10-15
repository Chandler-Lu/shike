import XCTest
import SwiftUI
import WidgetKit
import ShikeCore
@testable import Shike

final class CompanionBackupTests: XCTestCase {
    func testBuiltAppPublishesItsActualCloudDriveContainer() throws {
        let info = try XCTUnwrap(Bundle.main.infoDictionary)
        let id = try XCTUnwrap(info["ShikeCloudContainer"] as? String)
        XCTAssertFalse(id.contains("$("))
        XCTAssertNoThrow(try AppBackupFiles.validateCloudRegistration(info, containerID: id))
        var broken = info
        let containers = try XCTUnwrap(info["NSUbiquitousContainers"] as? [String: [String: Any]])
        broken["NSUbiquitousContainers"] = ["$(SHIKE_CLOUD_CONTAINER)": try XCTUnwrap(containers[id])]
        XCTAssertThrowsError(try AppBackupFiles.validateCloudRegistration(broken, containerID: id))
    }

    func testCloudBackupTracksActualUploadInsteadOfAssumingCompletion() {
        let pending = BackupUploadState(uploaded: nil, uploading: nil, error: nil)
        XCTAssertEqual(pending, .pending)
        let uploading = BackupUploadState(uploaded: false, uploading: true, error: nil)
        XCTAssertEqual(uploading, .uploading)
        let uploaded = BackupUploadState(uploaded: true, uploading: false, error: nil)
        XCTAssertEqual(uploaded, .uploaded)
        XCTAssertTrue(BackupUploadProgress(states: [uploaded, pending]).message.contains("等待系统上传"))
        XCTAssertTrue(BackupUploadProgress(states: [uploaded, pending]).message.contains("1/2"))
        XCTAssertTrue(BackupUploadProgress(states: [uploaded, uploading]).message.contains("正在上传"))
        XCTAssertEqual(BackupUploadProgress(states: [uploaded, uploaded]).message, "iCloud Drive 已上传 2 份备份。")
        let error = NSError(domain: "CloudUploadTest", code: 17, userInfo: [NSLocalizedDescriptionKey: "iCloud 空间不足"])
        let failure = BackupUploadState(uploaded: true, uploading: false, error: error)
        let message = BackupUploadProgress(states: [uploaded, failure]).message
        XCTAssertTrue(message.contains("iCloud 空间不足"))
        XCTAssertTrue(message.contains("CloudUploadTest 17"))
        XCTAssertTrue(message.contains("本地备份已保留"))
        XCTAssertFalse(BackupUploadProgress(states: []).message.contains("已上传"))
    }

    func testCloudMirrorRetainsLocalCopiesAndOnlyPrunesThisDevicesBackups() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let local = root.appendingPathComponent("Local"), cloud = root.appendingPathComponent("Cloud")
        let files = AppBackupFiles(directory: local, deviceID: "device-a", containerID: "unused")
        let empty = try await files.mirror(to: cloud)
        XCTAssertTrue(empty.isEmpty)
        let data = try makeBackup(entries: [Countdown(title: "本地和云端都要保留")]).data()
        for i in 0..<32 { _ = try await files.save(data, reason: "Auto", now: Date(timeIntervalSince1970: 1_800_000_000 + Double(i))) }
        let destination = cloud.appendingPathComponent("Documents/Backups/device-a")
        let otherDevice = cloud.appendingPathComponent("Documents/Backups/device-b/keep.json")
        try FileManager.default.createDirectory(at: otherDevice.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: otherDevice)
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        let unrelated = destination.appendingPathComponent("personal-note.txt")
        try Data("keep".utf8).write(to: unrelated)
        let expired = destination.appendingPathComponent("Shike_0000_Auto_old.json")
        try data.write(to: expired)
        let first = try await files.mirror(to: cloud)
        let again = try await files.mirror(to: cloud)
        let locals = try await files.list()
        XCTAssertEqual(first, again); XCTAssertEqual(first.count, 30); XCTAssertEqual(locals.count, 30)
        XCTAssertFalse(FileManager.default.fileExists(atPath: expired.path))
        XCTAssertEqual(try Data(contentsOf: otherDevice), data)
        XCTAssertEqual(try Data(contentsOf: unrelated), Data("keep".utf8))
        for url in first + locals { XCTAssertEqual(try Data(contentsOf: url), data) }
        let missing = try XCTUnwrap(first.first)
        try FileManager.default.removeItem(at: missing)
        _ = try await files.mirror(to: cloud)
        XCTAssertEqual(try Data(contentsOf: missing), data)
        // A failed cloud write must leave all local backups readable.
        let invalidRoot = root.appendingPathComponent("not-a-directory")
        try data.write(to: invalidRoot)
        do { _ = try await files.mirror(to: invalidRoot); XCTFail("Writing below a regular file must fail") }
        catch { for url in locals { XCTAssertEqual(try Data(contentsOf: url), data) } }
    }

    func testWidgetSpecificDayOverridesGroupWithoutFallingBackAfterDeletion() {
        let now = Date.now
        let future = Countdown(title: "期待", date: CivilDate(now.addingTimeInterval(86400 * 5)))
        let past = Countdown(title: "纪念", date: CivilDate(now.addingTimeInterval(-86400 * 520)))
        let snapshot = CountdownSnapshot(entries: [future, past])
        let automatic = CountdownWidgetEntry(date: now, snapshot: snapshot, group: "all")
        XCTAssertEqual(Set(automatic.displayedEntries.map(\.id)), [future.id, past.id])
        for value in [future, past] {
            let fixed = CountdownWidgetEntry(date: now, snapshot: snapshot, group: UUID().uuidString, countdownID: value.id)
            XCTAssertEqual(fixed.displayedEntries.map(\.id), [value.id])
            XCTAssertEqual(fixed.routeGroup, "all")
        }
        let deleted = CountdownWidgetEntry(date: now, snapshot: CountdownSnapshot(entries: [future]), group: "all", countdownID: past.id)
        XCTAssertTrue(deleted.displayedEntries.isEmpty)
        XCTAssertNil(CountdownWidgetIntent().countdown)
        XCTAssertNil(CountdownWidgetIntent().secondCountdown)
    }
    func testTwoSpecifiedDaysDeduplicateAndOnlyKeepSurvivingSelections() {
        let now = Date.now
        let future = Countdown(title: "期待", date: CivilDate(now.addingTimeInterval(86400 * 5)))
        var past = Countdown(title: "纪念", date: CivilDate(now.addingTimeInterval(-86400 * 520))); past.pinned = true
        let unrelated = Countdown(title: "不要替补", date: CivilDate(now))
        var entry = CountdownWidgetEntry(date: now, snapshot: CountdownSnapshot(entries: [future, past, unrelated]), group: "deleted-group", countdownID: past.id, secondCountdownID: future.id)
        XCTAssertEqual(entry.selection().primary?.id, past.id)
        XCTAssertEqual(entry.selection().secondary?.id, future.id)
        XCTAssertEqual(entry.displayedEntries.map(\.id), [past.id, future.id])
        XCTAssertEqual(entry.routeGroup, "all")
        entry.countdownID = future.id
        XCTAssertEqual(entry.displayedEntries.map(\.id), [future.id])
        XCTAssertNil(entry.selection().secondary)
        entry.countdownID = nil
        XCTAssertEqual(entry.selection().primary?.id, future.id)
        entry = CountdownWidgetEntry(date: now, snapshot: CountdownSnapshot(entries: [past, unrelated]), group: "all", countdownID: past.id, secondCountdownID: future.id)
        XCTAssertEqual(entry.displayedEntries.map(\.id), [past.id])
        entry = CountdownWidgetEntry(date: now, snapshot: CountdownSnapshot(entries: [future, unrelated]), group: "all", countdownID: past.id, secondCountdownID: future.id)
        XCTAssertEqual(entry.selection().primary?.id, future.id)
        XCTAssertNil(entry.selection().secondary)
        entry = CountdownWidgetEntry(date: now, snapshot: CountdownSnapshot(entries: [unrelated]), group: "all", countdownID: past.id, secondCountdownID: future.id)
        XCTAssertTrue(entry.displayedEntries.isEmpty)
    }

    func testWidgetDayPickerOffersResolvableEmptyChoiceEvenWhenSearching() async throws {
        let query = CountdownDayQuery()
        let suggestions = try await query.suggestedEntities()
        XCTAssertEqual(suggestions.first?.id, CountdownDayEntity.unselectedID)
        XCTAssertEqual(suggestions.first?.name, "留空")
        let cleared = try await query.entities(for: [CountdownDayEntity.unselectedID])
        XCTAssertEqual(cleared.first?.name, "留空")
        let search = try await query.entities(matching: "不存在的搜索词-\(UUID())")
        XCTAssertEqual(search.map(\.id), [CountdownDayEntity.unselectedID])
        let initial = await query.defaultResult()
        XCTAssertEqual(initial?.id, CountdownDayEntity.unselectedID)
        let deleted = UUID()
        let missing = try await query.entities(for: [deleted])
        XCTAssertEqual(missing.first?.id, deleted)
        XCTAssertEqual(missing.first?.name, "日子已删除")
    }

    func testClearingEitherWidgetSlotKeepsOtherAndClearingBothRestoresGroup() {
        let now = Date.now, unselected = CountdownDayEntity.unselectedID
        let group = CountdownCategory(name: "生活")
        var grouped = Countdown(title: "在一起", date: CivilDate(now.addingTimeInterval(-520 * 86400)))
        grouped.categoryID = group.id
        let other = Countdown(title: "旅行", date: CivilDate(now.addingTimeInterval(12 * 86400)))
        let snapshot = CountdownSnapshot(entries: [grouped, other], categories: [group])
        for (first, second) in [(grouped.id, unselected), (unselected, grouped.id)] {
            let entry = CountdownWidgetEntry(date: now, snapshot: snapshot, group: "all", countdownID: first, secondCountdownID: second)
            XCTAssertTrue(entry.hasSpecifiedDays)
            XCTAssertEqual(entry.displayedEntries.map(\.id), [grouped.id])
            XCTAssertEqual(entry.selection().primary?.id, grouped.id)
            XCTAssertNil(entry.selection().secondary)
        }
        let emptySlots: [(UUID?, UUID?)] = [(unselected, unselected), (nil, unselected), (unselected, nil), (nil, nil)]
        for (first, second) in emptySlots {
            let entry = CountdownWidgetEntry(date: now, snapshot: snapshot, group: group.id.uuidString, countdownID: first, secondCountdownID: second)
            XCTAssertFalse(entry.hasSpecifiedDays)
            XCTAssertEqual(entry.routeGroup, group.id.uuidString)
            XCTAssertEqual(entry.displayedEntries.map(\.id), [grouped.id])
        }
        let missing = CountdownWidgetEntry(date: now, snapshot: snapshot, group: "all", countdownID: UUID(), secondCountdownID: unselected)
        XCTAssertTrue(missing.hasSpecifiedDays)
        XCTAssertTrue(missing.displayedEntries.isEmpty)
    }

    @MainActor func testSpecifiedDaysRenderInChosenOrderWithEqualMediumAndLargeCards() throws {
        CompanionStyle.registerFont()
        let now = Date.now
        let future = Countdown(title: "下一次一起去看海", date: CivilDate(now.addingTimeInterval(12 * 86400)))
        let past = Countdown(title: "和你在一起的日子", date: CivilDate(now.addingTimeInterval(-1314 * 86400)))
        let otherFuture = Countdown(title: "回家的日子", date: CivilDate(now.addingTimeInterval(30 * 86400)))
        let otherPast = Countdown(title: "新的起点", date: CivilDate(now.addingTimeInterval(-520 * 86400)))
        for (name, pair) in [("mixed", [past, future]), ("upcoming", [otherFuture, future]), ("elapsed", [past, otherPast]), ("single", [past])] {
            for (family, size) in [(WidgetFamily.systemSmall, CGSize(width: 158, height: 158)), (.systemMedium, CGSize(width: 338, height: 158)), (.systemLarge, CGSize(width: 338, height: 354)), (.accessoryRectangular, CGSize(width: 180, height: 84))] {
                let entry = CountdownWidgetEntry(date: now, snapshot: CountdownSnapshot(entries: pair), group: "all", countdownID: pair[0].id, secondCountdownID: pair.dropFirst().first?.id)
                XCTAssertEqual(entry.displayedEntries.map(\.id), pair.map(\.id))
                let renderer = ImageRenderer(content: CountdownWidgetContent(entry: entry, family: family)
                    .padding(family == .accessoryRectangular ? 4 : 16).frame(width: size.width, height: size.height).background(CompanionPaper()))
                renderer.scale = 2
                let image = try XCTUnwrap(renderer.uiImage)
                let shot = XCTAttachment(image: image); shot.name = "specified-pair-\(name)-\(family)"; shot.lifetime = .keepAlways; add(shot)
            }
        }
    }
    #if !targetEnvironment(macCatalyst)
    @MainActor func testSpecifiedLockScreenDaysKeepFirstPrimaryAndSecondSecondary() throws {
        let now = Date.now
        let first = Countdown(title: "和你在一起", date: CivilDate(now.addingTimeInterval(-1314 * 86400)))
        let second = Countdown(title: "一起去看海", date: CivilDate(now.addingTimeInterval(12 * 86400)))
        let entry = CountdownWidgetEntry(date: now, snapshot: CountdownSnapshot(entries: [second, first]), group: "all", countdownID: first.id, secondCountdownID: second.id)
        XCTAssertEqual(entry.selection().primary?.id, first.id)
        XCTAssertEqual(entry.selection().secondary?.id, second.id)
        for (family, size) in [(WidgetFamily.accessoryInline, CGSize(width: 260, height: 24)),
                               (.accessoryCircular, CGSize(width: 72, height: 72)),
                               (.accessoryRectangular, CGSize(width: 170, height: 76))] {
            let renderer = ImageRenderer(content: CountdownLockScreenContent(entry: entry, family: family)
                .environment(\.colorScheme, .dark).environment(\.widgetRenderingMode, .vibrant)
                .frame(width: size.width, height: size.height).background(.black))
            renderer.scale = 3
            let shot = XCTAttachment(image: try XCTUnwrap(renderer.uiImage))
            shot.name = "specified-lock-\(family)"; shot.lifetime = .keepAlways; add(shot)
        }
    }
    @MainActor func testLockScreenWidgetsRenderUpcomingElapsedAndMissingGroups() throws {
        let now = Date.now
        let entries = [Countdown(title: "下一次一起去看海", date: CivilDate(now.addingTimeInterval(12 * 86400))),
                       Countdown(title: "和你在一起很久很久的日子", date: CivilDate(now.addingTimeInterval(-1314 * 86400)))]
        for (family, size) in [(WidgetFamily.accessoryInline, CGSize(width: 260, height: 24)),
                               (.accessoryCircular, CGSize(width: 72, height: 72)),
                               (.accessoryRectangular, CGSize(width: 170, height: 76))] {
            for mode in ["upcoming", "elapsed", "mixed", "empty", "deleted-group", "unavailable"] {
                let values = mode == "upcoming" ? [entries[0]] : mode == "elapsed" ? [entries[1]] : mode == "empty" ? [] : entries
                let entry = CountdownWidgetEntry(date: now, snapshot: mode == "unavailable" ? nil : CountdownSnapshot(entries: values),
                                                group: mode == "deleted-group" ? UUID().uuidString : "all", unavailable: mode == "unavailable")
                let view = CountdownLockScreenContent(entry: entry, family: family)
                    .environment(\.colorScheme, .dark).environment(\.widgetRenderingMode, .vibrant)
                    .frame(width: size.width, height: size.height).background(.black)
                let renderer = ImageRenderer(content: view); renderer.scale = 3
                let image = try XCTUnwrap(renderer.uiImage)
                XCTAssertEqual(image.size.width, size.width)
                let shot = XCTAttachment(image: image); shot.name = "lock-\(family)-\(mode)"; shot.lifetime = .keepAlways; add(shot)
            }
        }
    }
    #endif
    @MainActor func testCountdownMergePreservesExistingAndMapsSameNameCategories() throws {
        let store = CountdownStore(inMemory: true)
        let group = CountdownCategory(name: "旅行"); try store.saveCategory(group)
        let other = CountdownCategory(name: "旅行")
        let existing = Countdown(title: "本机内容"); try store.save(existing)
        var changed = existing; changed.title = "备份旧内容"
        var fresh = Countdown(title: "新的日子"); fresh.categoryID = other.id
        let backup = makeBackup(entries: [changed, fresh], categories: [other])
        let previous = store.document
        XCTAssertEqual(try store.importBackup(backup, notify: false), 1)
        XCTAssertEqual(store.entries.first { $0.id == existing.id }?.title, "本机内容")
        XCTAssertEqual(store.entries.first { $0.id == fresh.id }?.categoryID, group.id)
        XCTAssertEqual(try store.importBackup(backup, notify: false), 0)
        try store.rollbackImport(to: previous)
        XCTAssertEqual(store.entries.map(\.id), [existing.id])
        let renamed = CountdownCategory(name: "旅途"); try store.saveCategory(renamed)
        var oldName = renamed; oldName.name = "旅行"
        var sameIdentity = Countdown(title: "跟随原分组"); sameIdentity.categoryID = renamed.id
        _ = try store.importBackup(makeBackup(entries: [sameIdentity], categories: [oldName]))
        XCTAssertEqual(store.entries.first { $0.id == sameIdentity.id }?.categoryID, renamed.id)
    }
    @MainActor func testSessionImportIsIdempotentAndSettingsPreserveExistingCredentials() throws {
        let store = try SessionStore(inMemory: true)
        var session = ImportSession(); session.text = "保留本机"; try store.save(session)
        var changed = session; changed.text = "旧内容"
        XCTAssertEqual(try store.importMissing([changed, ImportSession()]), 1)
        XCTAssertEqual(try store.all().first { $0.id == session.id }?.text, "保留本机")
        let suite = "Shike.BackupTests.\(UUID())", defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let preferences = Preferences(defaults: defaults)
        try preferences.createBlankProfile()
        let existing = try XCTUnwrap(preferences.profiles.first)
        let backup = makeBackup(profiles: [APIProfile(id: existing.id, name: "覆盖尝试", configuration: APIConfiguration(baseURL: "https://other.example", model: "x")), APIProfile(id: "new", name: "新接口", configuration: APIConfiguration())])
        let imported = try AppDataImport(data: backup.data())
        try preferences.validateImport(backup); preferences.importSettings(imported)
        XCTAssertEqual(preferences.profiles.first { $0.id == existing.id }, existing)
        XCTAssertNil(preferences.profiles.first { $0.id == "new" }?.credentialID)
        XCTAssertFalse(preferences.iCloudEnabled)
    }
    func testBackupRetentionAndFilesAreRestorable() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let files = AppBackupFiles(directory: folder, deviceID: "test", containerID: "unused")
        let data = try makeBackup(entries: [Countdown(title: "本地备份")]).data()
        for i in 0..<32 { _ = try await files.save(data, reason: "Auto", now: Date(timeIntervalSince1970: 1_800_000_000 + Double(i))) }
        let backups = try await files.list(); XCTAssertEqual(backups.count, 30)
        XCTAssertTrue(backups.first!.lastPathComponent.contains("1800000031000"))
        for url in backups { XCTAssertEqual(try AppDataImport(data: Data(contentsOf: url)).backup.countdowns.first?.title, "本地备份") }
    }
    @MainActor func testWidgetsRenderEverySizeAndEmptyStates() throws {
        CompanionStyle.registerFont()
        for (family, size) in [(WidgetFamily.systemSmall, CGSize(width: 170, height: 170)), (.systemMedium, CGSize(width: 364, height: 170)), (.systemLarge, CGSize(width: 364, height: 382)), (.accessoryRectangular, CGSize(width: 180, height: 84))] {
            for mode in ["light", "dark", "accessibility", "accented"] {
                let dark = mode == "dark"
                let view = CountdownWidgetContent(entry: .preview, family: family)
                    .environment(\.colorScheme, dark ? .dark : .light)
                    .environment(\.dynamicTypeSize, mode == "accessibility" ? .accessibility5 : .large)
                    .environment(\.widgetRenderingMode, mode == "accented" ? .accented : .fullColor)
                    .padding(16).frame(width: size.width, height: size.height)
                    .background(CompanionPaper().environment(\.colorScheme, dark ? .dark : .light))
                let renderer = ImageRenderer(content: view); renderer.scale = 2
                let image = try XCTUnwrap(renderer.uiImage)
                XCTAssertEqual(image.size.width, size.width)
                let attachment = XCTAttachment(image: image); attachment.name = "widget-\(family)-\(mode)"; attachment.lifetime = .keepAlways; add(attachment)
            }
        }
        let empty = CountdownWidgetEntry(date: .now, snapshot: CountdownSnapshot(), group: UUID().uuidString)
        let renderer = ImageRenderer(content: CountdownWidgetContent(entry: empty, family: .systemSmall).frame(width: 170, height: 170))
        XCTAssertNotNil(renderer.uiImage)
    }

    @MainActor func testLongDayCountsHaveEqualStripHeightAndRenderInEveryLayout() throws {
        CompanionStyle.registerFont()
        let now = CivilDate(year: 2026, month: 10, day: 14).date()!
        let values = [93, -1421, 12930, -32768].map { offset in
            Countdown(title: "值得记住的日子", date: CivilDate(Calendar.current.date(byAdding: .day, value: offset, to: now)!))
        }
        for width in [CGFloat(276), 349] {
            let heights = try values.map { value in
                let renderer = ImageRenderer(content: CountdownCard(entry: value, category: nil, now: now, layout: .strip)
                    .environment(\.dynamicTypeSize, .large).frame(width: width))
                return try XCTUnwrap(renderer.uiImage).size.height
            }
            XCTAssertEqual(try XCTUnwrap(heights.min()), try XCTUnwrap(heights.max()), accuracy: 1,
                           "Changing digit count must not wrap the day unit or change row height")
        }
        var long = values[1]; long.id = UUID(); long.title = "和你一起去很远的地方看一次日出"; long.pinned = true
        var precise = values[2]; precise.id = UUID(); precise.title = "精确到秒的约定"; precise.targetTime = CountdownTime(hour: 13, minute: 14, second: 52)
        for layout in CountdownLayout.allCases {
            for largeText in [false, true] {
                let cards = values + [long, precise]
                let columns = Array(repeating: GridItem(.flexible(), spacing: 12, alignment: .top), count: layout == .double && !largeText ? 2 : 1)
                let view = LazyVGrid(columns: columns, spacing: 10) {
                    ForEach(cards) { CountdownCard(entry: $0, category: "纪念日", now: now, layout: layout) }
                }.padding(22).frame(width: 393)
                    .environment(\.dynamicTypeSize, largeText ? .accessibility5 : .large)
                    .foregroundStyle(Notebook.ink).background(Notebook.paper)
                let renderer = ImageRenderer(content: view); renderer.scale = 2
                let image = try XCTUnwrap(renderer.uiImage)
                let attachment = XCTAttachment(image: image); attachment.name = "cards-\(layout.rawValue)-\(largeText ? "accessibility" : "normal")"
                attachment.lifetime = .keepAlways; add(attachment)
            }
        }
    }

    @MainActor func testWidgetsRenderLongTitlesPreciseAndSingleDirection() throws {
        CompanionStyle.registerFont()
        let now = CivilDate(year: 2026, month: 10, day: 14).date()!
        var precise = Countdown(title: "一段精确到秒的珍贵时光", date: CivilDate(year: 2022, month: 11, day: 23))
        precise.targetTime = CountdownTime(hour: 13, minute: 14, second: 52); precise.pinned = true
        let past = Countdown(title: "和你一起走过的那些很长很长的日子", date: CivilDate(year: 1937, month: 1, day: 1))
        let future = Countdown(title: "很远很远的下一次相遇", date: CivilDate(year: 2062, month: 3, day: 9))
        let today = Countdown(title: "就是今天的约定", date: CivilDate(now))
        let longTitles = (0..<6).map { index in
            var value = index < 3 ? future : past
            value.id = UUID(); value.title = "第\(index + 1)个与你一起记下的很长很长的日子"
            return value
        }
        let groups = ["past": [past, precise], "future": [future, today], "mixed": [future, past, precise, today], "long": longTitles, "empty": []]
        for (name, values) in groups.sorted(by: { $0.key < $1.key }) {
            for (family, size) in [(WidgetFamily.systemSmall, CGSize(width: 158, height: 158)), (.systemMedium, CGSize(width: 338, height: 158)), (.systemLarge, CGSize(width: 338, height: 354))] {
                let entry = CountdownWidgetEntry(date: now, snapshot: CountdownSnapshot(entries: values), group: "all")
                let renderer = ImageRenderer(content: CountdownWidgetContent(entry: entry, family: family)
                    .environment(\.dynamicTypeSize, .large)
                    .padding(16).frame(width: size.width, height: size.height)
                    .background(CompanionPaper()))
                renderer.scale = 2
                let image = try XCTUnwrap(renderer.uiImage)
                let attachment = XCTAttachment(image: image); attachment.name = "widget-\(name)-\(family)"; attachment.lifetime = .keepAlways; add(attachment)
            }
        }
    }
    private func makeBackup(entries: [Countdown] = [], categories: [CountdownCategory] = [], profiles: [APIProfile] = []) -> AppDataExport {
        AppDataExport(version: "1.0", build: "4", preferences: .init(iCloudEnabled: true, categoryRoutingEnabled: true,
            defaultCalendar: nil, categoryCalendars: [:], activeProfileID: profiles.first?.id ?? "", calendar: CalendarPreferences()),
            profiles: profiles, prompts: .init(), countdowns: entries, categories: categories, sessions: [], calendarReferences: [:])
    }
}
