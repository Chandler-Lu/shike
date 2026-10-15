import XCTest
import UIKit
import AppIntents
import ShikeCore
@testable import Shike

final class ShortcutAndArtworkTests: XCTestCase {
    @MainActor func testShortcutQueueSurvivesRestartAndDoesNotOverwriteRequests() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let inbox = ShortcutInbox(directory: directory)
        XCTAssertThrowsError(try inbox.enqueue(text: "  ", source: "test"))
        try inbox.enqueue(text: "第一个安排", source: "捷径文字")
        let first = try XCTUnwrap(inbox.pending)
        try inbox.enqueue(text: "第二个安排", source: "捷径图片")
        XCTAssertEqual(inbox.pending?.id, first.id)
        let restored = ShortcutInbox(directory: directory)
        XCTAssertEqual(restored.pending?.text, "第一个安排")
        try restored.consume(first.id)
        XCTAssertEqual(restored.pending?.text, "第二个安排")
        let second = try XCTUnwrap(restored.pending)
        try restored.consume(second.id)
        XCTAssertNil(restored.pending)
        XCTAssertThrowsError(try inbox.enqueue(text: String(repeating: "a", count: 120_001), source: "test"))
    }
    @MainActor func testShareInboxRetainsImageOnlyInputAndReadsOlderTextRequests() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let image = try ImageStaging.write(Data([1, 2, 3]))
        defer { ImageStaging.remove(image) }
        let inbox = ShortcutInbox(directory: folder)
        try inbox.enqueue(text: "", source: "分享", images: [image])
        let restored = ShortcutInbox(directory: folder)
        XCTAssertEqual(restored.pending?.images, [image])
        XCTAssertEqual(restored.pending?.text, "")
        XCTAssertThrowsError(try inbox.enqueue(text: "", source: "分享", images: ["../bad.image"]))
        let old = #"{"id":"00000000-0000-0000-0000-000000000001","createdAt":0,"text":"旧输入","source":"捷径文字"}"#
        let decoded = try JSONDecoder().decode(ShortcutInput.self, from: Data(old.utf8))
        XCTAssertNil(decoded.images); XCTAssertEqual(decoded.text, "旧输入")
    }
    @MainActor func testExportFreezesSelectedUnitTimeAndZoneAcrossArtworkChanges() throws {
        var entry = Countdown(title: "一起长大", date: CivilDate(year: 2020, month: 2, day: 29))
        entry.timeZoneIdentifier = "Asia/Shanghai"
        let now = try XCTUnwrap(ISO8601DateFormatter().date(from: "2026-10-15T10:00:00+08:00"))
        var exports: [CountdownImageExport] = []
        defer { for item in exports { try? FileManager.default.removeItem(at: item.url) } }
        for unit in CountdownCountUnit.allCases {
            let export = try CountdownImageExport.make(entry: entry, category: nil, now: now, art: .original, unit: unit)
            exports.append(export)
            XCTAssertEqual(export.value.unit, unit)
            XCTAssertEqual(export.value.label, CountdownDisplayValue(entry, now: now, unit: unit).label)
            XCTAssertEqual(export.entry.timeZoneIdentifier, "Asia/Shanghai")
        }
        XCTAssertEqual(Set(exports.map(\.data)).count, 4)
        let years = try XCTUnwrap(exports.last)
        let changed = try CountdownImageExport.make(entry: years.entry, category: nil, now: years.now,
            art: CountdownArtwork.all.first { $0.kind == .cat }!, unit: years.value.unit)
        exports.append(changed)
        XCTAssertEqual(changed.value, years.value)
        XCTAssertEqual(changed.now, now)
        XCTAssertEqual(changed.value.components.map(\.unit), [.years, .months, .days])
    }
    @MainActor func testScreenshotIntentRecognizesNativeImageAndQueuesOnlyText() async throws {
        let image = UIGraphicsImageRenderer(size: CGSize(width: 1000, height: 300)).image { context in
            UIColor.white.setFill(); context.fill(CGRect(x: 0, y: 0, width: 1000, height: 300))
            ("Tomorrow 14:00 Design Review" as NSString).draw(at: CGPoint(x: 40, y: 100), withAttributes: [.font: UIFont.systemFont(ofSize: 46), .foregroundColor: UIColor.black])
        }
        // Isolate from any pre-existing shortcuts; the action writes through the same durable queue.
        XCTAssertNil(ShortcutInbox.shared.pending)
        let intent = ExtractScheduleImageIntent()
        intent.image = IntentFile(data: try XCTUnwrap(image.pngData()), filename: "screen.png", type: .png)
        _ = try await intent.perform()
        let request = try XCTUnwrap(ShortcutInbox.shared.pending)
        defer { try? ShortcutInbox.shared.consume(request.id) }
        XCTAssertTrue(request.text.contains("14:00"), request.text)
        XCTAssertTrue(request.text.contains("Design"), request.text)
        XCTAssertEqual(request.source, "捷径图片")
    }
    @MainActor func testAll21ArtworkAssetsExistAndSelectionChangesExportedPixels() throws {
        XCTAssertEqual(CountdownArtwork.all.count, 21)
        XCTAssertEqual(CountdownArtwork.all.filter { $0.kind == .rabbit }.count, 5)
        XCTAssertEqual(CountdownArtwork.all.filter { $0.kind == .cat }.count, 5)
        XCTAssertEqual(CountdownArtwork.all.filter { $0.kind == .together }.count, 11)
        XCTAssertEqual(Set(CountdownArtwork.all.map(\.asset)).count, 21)
        for art in CountdownArtwork.all {
            try autoreleasepool {
                let image = try XCTUnwrap(UIImage(named: art.asset), art.asset)
                XCTAssertGreaterThan(image.size.width, 500)
                XCTAssertGreaterThan(image.size.height, 500)
            }
        }
        let entry = Countdown(title: "一起读书", date: CivilDate(year: 2022, month: 11, day: 23))
        let now = Date(timeIntervalSince1970: 1_792_080_000)
        let original = try CountdownImageExport.make(entry: entry, category: "纪念", now: now, art: .original)
        let cat = try XCTUnwrap(CountdownArtwork.all.first { $0.kind == .cat })
        let selected = try CountdownImageExport.make(entry: entry, category: "纪念", now: now, art: cat)
        defer { try? FileManager.default.removeItem(at: original.url); try? FileManager.default.removeItem(at: selected.url) }
        XCTAssertNotEqual(original.data, selected.data)
        XCTAssertEqual(selected.art, cat); XCTAssertEqual(selected.entry.id, entry.id)
        XCTAssertEqual(selected.now, original.now)
        XCTAssertEqual(try Data(contentsOf: selected.url), selected.data)
        XCTAssertGreaterThan(selected.image.size.height, selected.image.size.width)
        let attachment = XCTAttachment(image: selected.image); attachment.name = "countdown-selected-cat-card"; attachment.lifetime = .keepAlways; add(attachment)
    }
}
