import Foundation
import Combine
import ShikeCore

/// Separate atomic document; the existing SwiftData session schema is unchanged.
@MainActor final class CountdownStore: ObservableObject {
    struct Document: Codable {
        var version = 1
        var records: [CountdownRecord] = CountdownCategory.defaults.map {
            var r = CountdownRecord($0, now: Date(timeIntervalSince1970: 0)); r.revision = $0.id; return r
        }
        var pending: Set<UUID> = []
        var accountID: String?
        var engineState: Data?
        var serverFields: [String: Data] = [:]
    }
    @Published private(set) var revision = 0
    @Published private(set) var error: String?
    private(set) var document = Document()
    private let url: URL?
    private let inMemory: Bool
    var onChange: (() -> Void)?
    var records: [CountdownRecord] { document.records }
    var categories: [CountdownCategory] { records.filter { !$0.deleted }.compactMap(\.category).sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending } }
    var entries: [Countdown] {
        let ids = Set(categories.map(\.id))
        return records.filter { !$0.deleted }.compactMap(\.countdown).map { value in
            var value = value
            if let id = value.categoryID, !ids.contains(id) { value.categoryID = nil }
            return value
        }
    }
    init(url: URL? = nil, inMemory: Bool = false) {
        self.inMemory = inMemory
        self.url = url ?? (inMemory ? nil : FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: AppIdentity.appGroup)?.appendingPathComponent("Countdowns-v1.json"))
        guard !inMemory else {
            #if DEBUG
            if AppIdentity.isUITesting && ProcessInfo.processInfo.arguments.contains("-countdown-fixture") {
                var c = Calendar(identifier: .gregorian); c.timeZone = .current
                var first = Countdown(title: "下一次，一起去看海", date: CivilDate(c.date(byAdding: .day, value: 12, to: .now)!))
                first.pinned = true; first.categoryID = CountdownCategory.defaults[2].id; first.notes = "带上相机，也带上好心情。"
                var second = Countdown(title: "和你在一起的日子", date: CivilDate(c.date(byAdding: .day, value: -365, to: .now)!))
                second.categoryID = CountdownCategory.defaults[0].id
                var third = Countdown(title: "每年的小小纪念", date: CivilDate(c.date(byAdding: .day, value: 30, to: .now)!))
                third.recurrence = .yearly; third.categoryID = CountdownCategory.defaults[0].id
                document.records += [first, second, third].map { CountdownRecord($0) }
            }
            #endif
            return
        }
        guard let path = self.url else { error = "无法打开倒数日存储，请检查 App Groups 配置。"; return }
        if FileManager.default.fileExists(atPath: path.path) {
            do {
                let loaded = try JSONDecoder().decode(Document.self, from: Data(contentsOf: path))
                guard loaded.version == 1, Set(loaded.records.map(\.id)).count == loaded.records.count else { throw ShikeError.message("倒数日存储版本或记录无效。") }
                for r in loaded.records { try r.validate() }
                document = loaded
            } catch { self.error = "倒数日数据无法读取，已保留原文件。\(error.localizedDescription)" }
        }
    }
    private func commit(_ value: Document, notify: Bool = true) throws {
        guard error == nil else { throw ShikeError.message(error!) }
        if !inMemory {
            guard let url else { throw ShikeError.message("倒数日存储不可用。") }
            let data = try JSONEncoder().encode(value)
            try data.write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        }
        document = value
        if notify { revision += 1; onChange?() }
    }
    func save(_ entry: Countdown, expectedRevision: UUID? = nil) throws {
        try entry.validate()
        if let expectedRevision, let current = records.first(where: { $0.id == entry.id }), current.revision != expectedRevision {
            throw ShikeError.message("这条倒数日已在其他设备修改。请关闭编辑页，查看最新内容后再编辑。")
        }
        try put(CountdownRecord(entry))
    }
    func saveCategory(_ category: CountdownCategory) throws {
        var category = category; category.name = category.name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !categories.contains(where: { $0.id != category.id && $0.name == category.name }) else { throw ShikeError.message("已有同名分类。") }
        let record = CountdownRecord(category); try record.validate(); try put(record)
    }
    /// Inserts a reviewed batch in one atomic commit; a bad item never leaves a partial import.
    func insert(_ entries: [Countdown]) throws {
        guard !entries.isEmpty, entries.count <= 50, Set(entries.map(\.id)).count == entries.count,
              Set(entries.map(\.id)).isDisjoint(with: Set(records.map(\.id))) else {
            throw ShikeError.message("待添加的日子为空、重复或超过 50 条，请重新核对。")
        }
        for entry in entries { try entry.validate() }
        var value = document
        value.records += entries.map { CountdownRecord($0) }
        value.pending.formUnion(entries.map(\.id))
        try commit(value)
    }
    private func put(_ record: CountdownRecord) throws {
        var value = document
        value.records.removeAll { $0.id == record.id }; value.records.append(record); value.pending.insert(record.id)
        try commit(value)
    }
    /// Merge only missing IDs. Same-name categories retain the existing category ID.
    func importBackup(_ backup: AppDataExport, notify: Bool = true) throws -> Int {
        var value = document
        var map: [UUID: UUID] = [:]
        var groups = categories
        let entryIDs = Set(entries.map(\.id))
        let existingGroupIDs = Set(groups.map(\.id))
        guard Set(backup.countdownCategories.map(\.id)).isDisjoint(with: entryIDs),
              Set(backup.countdowns.map(\.id)).isDisjoint(with: existingGroupIDs) else {
            throw ShikeError.message("备份编号与当前数据类型冲突，未导入。")
        }
        for group in backup.countdownCategories {
            if let existing = groups.first(where: { $0.id == group.id }) ?? groups.first(where: { $0.name == group.name }) { map[group.id] = existing.id }
            else {
                try CountdownRecord(group).validate(); groups.append(group); map[group.id] = group.id
                value.records.removeAll { $0.id == group.id }; value.records.append(CountdownRecord(group)); value.pending.insert(group.id)
            }
        }
        var count = 0
        for source in backup.countdowns where !entryIDs.contains(source.id) {
            var entry = source.countdown; entry.categoryID = entry.categoryID.flatMap { map[$0] }
            try entry.validate()
            value.records.removeAll { $0.id == entry.id }; value.records.append(CountdownRecord(entry)); value.pending.insert(entry.id); count += 1
        }
        try commit(value, notify: notify); return count
    }
    func finishImport() { revision += 1; onChange?() }
    func rollbackImport(to previous: Document) throws { try commit(previous, notify: false) }
    func delete(_ id: UUID) throws {
        guard var record = records.first(where: { $0.id == id }) else { return }
        record.updatedAt = .now; record.revision = UUID(); record.deleted = true; record.countdown = nil; record.category = nil
        try put(record)
    }

    /// Apply a batch in one write and one notification, preserving sync tombstones.
    func deleteEntries(_ ids: Set<UUID>) throws {
        try updateEntries(ids) { record in
            record.deleted = true
            record.countdown = nil
        }
    }

    func moveEntries(_ ids: Set<UUID>, to categoryID: UUID?) throws {
        if let categoryID, !categories.contains(where: { $0.id == categoryID }) {
            throw ShikeError.message("这个分组已被删除，请重新选择。")
        }
        try updateEntries(ids) { record in record.countdown?.categoryID = categoryID }
    }

    private func updateEntries(_ ids: Set<UUID>, change: (inout CountdownRecord) -> Void) throws {
        guard !ids.isEmpty else { return }
        guard ids.isSubset(of: Set(entries.map(\.id))) else {
            throw ShikeError.message("所选日子已发生变化，请重新选择。")
        }
        var value = document
        let now = Date.now
        for index in value.records.indices where ids.contains(value.records[index].id) {
            change(&value.records[index])
            value.records[index].updatedAt = now
            value.records[index].revision = UUID()
            try value.records[index].validate()
        }
        value.pending.formUnion(ids)
        try commit(value)
    }
    /// The binding is never silently reassigned, so another Apple account cannot receive old data.
    func bindAccount(_ id: String) throws {
        guard document.accountID == nil || document.accountID == id else {
            throw ShikeError.message("Apple 账户已改变，倒数日同步已暂停。本地数据已保留；登录原账户后可继续同步。")
        }
        if document.accountID == nil {
            var value = document; value.accountID = id
            value.pending.formUnion(value.records.map(\.id)); try commit(value, notify: false)
        }
    }
    func merge(_ incoming: [CountdownRecord], fields: [String: Data] = [:]) throws {
        for record in incoming { try record.validate() }
        var value = document
        value.records = CountdownRecord.merge(value.records, incoming)
        for remote in incoming {
            if let local = value.records.first(where: { $0.id == remote.id }), local == remote { value.pending.remove(remote.id) }
            else { value.pending.insert(remote.id) }
        }
        value.serverFields.merge(fields) { _, new in new }
        try commit(value)
    }
    func acknowledge(_ sent: CountdownRecord, fields: Data) throws {
        var value = document; value.serverFields[sent.id.uuidString] = fields
        if value.records.first(where: { $0.id == sent.id })?.revision == sent.revision { value.pending.remove(sent.id) }
        try commit(value, notify: false)
    }
    func saveEngineState(_ data: Data) throws { var value = document; value.engineState = data; try commit(value, notify: false) }
    func resetCloudZone() throws {
        var value = document; value.engineState = nil; value.serverFields = [:]
        value.pending.formUnion(value.records.map(\.id)); try commit(value, notify: false)
    }
}
