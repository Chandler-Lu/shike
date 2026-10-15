import XCTest
import UIKit
import UniformTypeIdentifiers
@testable import Shike

final class FileImportTests: XCTestCase {
    private func directory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    func testFilesAndFinderProvidersPreserveUnicodeAndImageBytes() async throws {
        let folder = try directory()
        let text = folder.appendingPathComponent("安排.txt")
        try "明天在上海见面 🐰".data(using: .utf16)!.write(to: text)
        let png = folder.appendingPathComponent("图片.png")
        let image = await MainActor.run {
            UIGraphicsImageRenderer(size: CGSize(width: 30, height: 20)).pngData { context in
                UIColor.blue.setFill(); context.fill(CGRect(x: 0, y: 0, width: 30, height: 20))
            }
        }
        try image.write(to: png)
        let (value, staged) = try await ItemLoader.loadFiles([text, png])
        defer { staged.forEach(ImageStaging.remove) }
        XCTAssertEqual(value, "明天在上海见面 🐰")
        XCTAssertEqual(staged.count, 1)
        let provider = NSItemProvider(item: text as NSURL, typeIdentifier: UTType.fileURL.identifier)
        let (dropped, files) = try await ItemLoader.load([provider])
        XCTAssertEqual(dropped, value); XCTAssertTrue(files.isEmpty)
    }

    func testInvalidAndOversizeFilesAreRejected() async throws {
        let folder = try directory()
        for (name, data) in [("huge.txt", Data(repeating: 65, count: 2_000_001)),
                             ("bad.png", Data("not an image".utf8)), ("plan.pdf", Data("pdf".utf8))] {
            let url = folder.appendingPathComponent(name); try data.write(to: url)
            do { _ = try await ItemLoader.loadFiles([url]); XCTFail("Accepted \(name)") }
            catch { XCTAssertFalse(error.localizedDescription.isEmpty) }
        }
    }

    func testSixImagesAreRejectedAsOneBatch() async throws {
        let folder = try directory()
        let data = await MainActor.run { UIGraphicsImageRenderer(size: CGSize(width: 10, height: 10)).pngData { _ in } }
        let urls = try (0..<6).map { index in
            let url = folder.appendingPathComponent("\(index).png"); try data.write(to: url); return url
        }
        do { _ = try await ItemLoader.loadFiles(urls); XCTFail("Accepted six images") }
        catch { XCTAssertTrue(error.localizedDescription.contains("5")) }
    }
}
