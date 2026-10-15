import Foundation
import SwiftUI
import ShikeCore

struct ShortcutInput: Codable, Identifiable {
    var id = UUID()
    var createdAt = Date()
    let text: String
    let source: String
    var images: [String]? = nil
}

/// Each request has its own atomic file so a cold launch or a second shortcut cannot overwrite it.
@MainActor final class ShortcutInbox: ObservableObject {
    static let shared = ShortcutInbox()
    @Published private(set) var pending: ShortcutInput?
    @Published private(set) var error: String?
    private let directory: URL?
    init(directory: URL? = nil) {
        self.directory = directory ?? (AppIdentity.isUITesting ? FileManager.default.temporaryDirectory.appendingPathComponent("ShortcutUITests-" + UUID().uuidString, isDirectory: true) : FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: AppIdentity.appGroup)?.appendingPathComponent("ShortcutInbox", isDirectory: true))
        refresh()
    }
    func enqueue(text: String, source: String, images: [String] = []) throws {
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty || !images.isEmpty else { throw ShikeError.message("没有可导入的文字，请传入截图或日程内容。") }
        guard value.utf8.count <= 120_000 else { throw ShikeError.message("文字过长，请分成几次导入。") }
        guard let directory else { throw ShikeError.message("无法打开捷径共享存储，请先打开拾刻计划。") }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        guard try files().count < 20 else { throw ShikeError.message("还有较多捷径内容待处理，请先打开拾刻计划完成导入。") }
        guard images.count <= 5 else { throw ShikeError.message("一次最多导入 5 张图片。") }
        for file in images { _ = try ImageStaging.url(for: file) }
        let input = ShortcutInput(text: value, source: source, images: images.isEmpty ? nil : images)
        try JSONEncoder().encode(input).write(to: directory.appendingPathComponent(input.id.uuidString + ".json"), options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        refresh()
    }
    func refresh() {
        do {
            pending = try files().map { try JSONDecoder().decode(ShortcutInput.self, from: Data(contentsOf: $0)) }
                .sorted { ($0.createdAt, $0.id.uuidString) < ($1.createdAt, $1.id.uuidString) }.first
            error = nil
        } catch { self.error = "捷径内容读取失败：" + error.localizedDescription }
    }
    func consume(_ id: UUID) throws {
        guard let directory else { throw ShikeError.message("捷径共享存储不可用。") }
        let file = directory.appendingPathComponent(id.uuidString + ".json")
        if FileManager.default.fileExists(atPath: file.path) { try FileManager.default.removeItem(at: file) }
        refresh()
    }
    private func files() throws -> [URL] {
        guard let directory, FileManager.default.fileExists(atPath: directory.path) else { return [] }
        return try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil).filter { $0.pathExtension == "json" }
    }
}
