import Foundation
import ShikeCore

enum CountdownSnapshotStorage {
    static var group: String { Bundle.main.object(forInfoDictionaryKey: "ShikeAppGroup") as? String ?? "group.com.chandler.shike" }
    static func directory() throws -> URL {
        guard let url = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: group) else {
            throw ShikeError.message("倒数日共享空间尚未就绪。")
        }
        return url
    }
    static func read() throws -> CountdownSnapshot? {
        let url = try directory().appendingPathComponent("CountdownDisplay-v1.json")
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        return try decode(Data(contentsOf: url))
    }
    static func decode(_ data: Data) throws -> CountdownSnapshot {
        let snapshot = try JSONDecoder().decode(CountdownSnapshot.self, from: data)
        try snapshot.validate(); return snapshot
    }
    static func write(_ snapshot: CountdownSnapshot) throws {
        try snapshot.validate()
        try JSONEncoder().encode(snapshot).write(to: directory().appendingPathComponent("CountdownDisplay-v1.json"),
                                               options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
    }
}
