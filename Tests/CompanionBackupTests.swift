import XCTest
import SwiftUI
import WidgetKit
import ShikeCore
@testable import Shike

final class CompanionBackupTests: XCTestCase {
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
