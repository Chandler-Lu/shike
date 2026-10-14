import Foundation
import ShikeCore

enum ImageStaging {
    static func folder() throws -> URL {
        let root: URL
        if AppIdentity.isUITesting { root = FileManager.default.temporaryDirectory }
        else {
            guard let shared = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: AppIdentity.appGroup) else {
                throw ShikeError.message("无法暂存图片，请检查 App Groups 配置。")
            }
            root = shared
        }
        let folder = root.appendingPathComponent("IncomingImages", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true,
                                              attributes: [.protectionKey: FileProtectionType.complete])
        return folder
    }
    static func write(_ data: Data) throws -> String {
        guard data.count <= 30_000_000 else { throw ShikeError.message("单张图片超过 30 MB，请裁剪后再导入。") }
        let name = UUID().uuidString + ".image"
        var path = try folder().appendingPathComponent(name)
        try data.write(to: path, options: [.atomic, .completeFileProtection])
        var values = URLResourceValues(); values.isExcludedFromBackup = true
        try path.setResourceValues(values)
        return name
    }
    static func url(for name: String) throws -> URL {
        guard name == URL(fileURLWithPath: name).lastPathComponent, name.hasSuffix(".image") else { throw ShikeError.message("图片暂存路径无效。") }
        return try folder().appendingPathComponent(name)
    }
    static func remove(_ name: String) { if let url = try? url(for: name) { try? FileManager.default.removeItem(at: url) } }
}
