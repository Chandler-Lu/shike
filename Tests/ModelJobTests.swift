import XCTest
import ShikeCore
@testable import Shike

final class ModelJobTests: XCTestCase {
    @MainActor func testSummaryFollowUpRestoresSnapshotAndEveryAnswerFromJournal() async throws {
        let folder = try directory()
        let center = ModelJobCenter(directory: folder, platformEnabled: false, isBackground: { false })
        let controller = CalendarSummaryController(jobs: center)
        let request = CalendarSummaryRequest(title: "今天", input: CalendarSummaryInput(events: [], range: DateInterval(start: .now, duration: 86400), timeZone: TimeZone(identifier: "Asia/Shanghai")!))
        let initial = CalendarSummary(overview: "原始总结", agenda: [], attention: [], suggestions: [])
        await controller.run(request) { _ in initial }.value
        let firstRecord = try XCTUnwrap(center.record(try XCTUnwrap(controller.jobID)))
        let reopened = CalendarSummaryController(jobs: center, restored: firstRecord)
        XCTAssertEqual(reopened.summary, initial)
        XCTAssertEqual(reopened.context?.input?.timeZone, "Asia/Shanghai")
        var background = true, deliveries = 0
        center.isBackground = { background }; center.deliver = { _ in deliveries += 1 }
        let followup = CalendarSummary(overview: "追问的答复", agenda: [], attention: [], suggestions: ["休息一下"])
        await reopened.execute(context: try XCTUnwrap(reopened.context), question: "可以休息多久？") { _ in followup }.value
        let id = try XCTUnwrap(reopened.jobID)
        XCTAssertEqual(deliveries, 1)
        XCTAssertTrue(reopened.needsPresentation)
        XCTAssertEqual(reopened.context?.exchanges.count, 2)
        let loadedCenter = ModelJobCenter(directory: folder, platformEnabled: false, isBackground: { false })
        let restored = CalendarSummaryController(jobs: loadedCenter, restored: try XCTUnwrap(loadedCenter.record(id)))
        XCTAssertEqual(restored.summary, followup)
        XCTAssertEqual(restored.context?.exchanges.first?.answer, initial)
        XCTAssertEqual(restored.context?.exchanges.last?.question, "可以休息多久？")
        XCTAssertEqual(restored.context?.input?.rangeStart, request.input.rangeStart)
        background = false; restored.setVisible(true)
        XCTAssertEqual(loadedCenter.record(id)?.seen, true)
        let task = restored.execute(context: try XCTUnwrap(restored.context), question: "再调整一下") { _ in
            try await Task.sleep(for: .seconds(60)); return initial
        }
        restored.cancel(); await task.value
        XCTAssertEqual(restored.summary, followup, "取消追问不能清空已完成的回答")
        XCTAssertEqual(restored.pendingQuestion, "再调整一下")
        let cancelled = CalendarSummaryController(jobs: loadedCenter, restored: try XCTUnwrap(loadedCenter.record(try XCTUnwrap(restored.jobID))))
        XCTAssertEqual(cancelled.summary, followup)
        XCTAssertEqual(cancelled.pendingQuestion, "再调整一下")
    }

    @MainActor func testSummaryWithoutSnapshotStillOpensAndCanBeDiscussed() throws {
        let center = ModelJobCenter(directory: try directory(), platformEnabled: false)
        let old = ModelJobRecord(id: UUID(), kind: .summary, createdAt: .now, status: .completed,
            output: .summary(title: "旧总结", value: CalendarSummary(overview: "旧的回答", agenda: [], attention: [], suggestions: [])))
        let restored = CalendarSummaryController(jobs: center, restored: try JSONDecoder().decode(ModelJobRecord.self, from: JSONEncoder().encode(old)))
        XCTAssertNil(restored.context?.input)
        XCTAssertEqual(restored.context?.title, "旧总结")
        XCTAssertEqual(restored.summary?.overview, "旧的回答")
        XCTAssertTrue(try XCTUnwrap(restored.context).encoded(question: "如何理解？").contains("旧的回答"))
    }

    @MainActor func testDismissedSummaryCompletesUnreadAndCanBePresentedWithoutNewRequest() async throws {
        let folder = try directory()
        let center = ModelJobCenter(directory: folder, platformEnabled: false, isBackground: { false })
        let controller = CalendarSummaryController(jobs: center)
        let request = CalendarSummaryRequest(title: "今天", input: CalendarSummaryInput(events: [], range: DateInterval(start: .now, duration: 86400), timeZone: .current))
        let value = CalendarSummary(overview: "今天没有安排", agenda: [], attention: [], suggestions: [])
        controller.setVisible(true)
        let task = controller.run(request) { _ in
            await Task.yield()
            return value
        }
        controller.setVisible(false)
        await task.value
        let id = try XCTUnwrap(controller.jobID)
        XCTAssertEqual(controller.summary, value)
        XCTAssertTrue(controller.needsPresentation)
        XCTAssertEqual(center.record(id)?.seen, false)
        let reloaded = ModelJobCenter(directory: folder, platformEnabled: false)
        XCTAssertEqual(reloaded.record(id)?.seen, false)
        XCTAssertTrue(controller.shouldPresentResult)
        center.acknowledge(id) // Reading from the task list must also prevent a duplicate popup.
        XCTAssertFalse(controller.shouldPresentResult)
        controller.setVisible(true)
        XCTAssertFalse(controller.needsPresentation)
        XCTAssertEqual(center.record(id)?.seen, true)
        XCTAssertEqual(center.records.count, 1)
        controller.setVisible(false)
        XCTAssertFalse(controller.needsPresentation, "查看完再关闭，不应重复弹出")
    }

    @MainActor func testVisibleSummaryIsAcknowledgedAndCancellationDoesNotReopen() async throws {
        let center = ModelJobCenter(directory: try directory(), platformEnabled: false, isBackground: { false })
        let controller = CalendarSummaryController(jobs: center)
        let request = CalendarSummaryRequest(title: "今天", input: CalendarSummaryInput(events: [], range: DateInterval(start: .now, duration: 86400), timeZone: .current))
        controller.setVisible(true)
        await controller.run(request) { _ in CalendarSummary(overview: "空闲", agenda: [], attention: [], suggestions: []) }.value
        XCTAssertFalse(controller.needsPresentation)
        XCTAssertEqual(center.record(try XCTUnwrap(controller.jobID))?.seen, true)
        let task = controller.run(request) { _ in
            try await Task.sleep(for: .seconds(60))
            throw CancellationError()
        }
        controller.cancel(); controller.setVisible(false)
        await task.value
        XCTAssertFalse(controller.needsPresentation)
        XCTAssertFalse(controller.running)
        XCTAssertEqual(center.record(try XCTUnwrap(controller.jobID))?.status, .cancelled)
    }

    @MainActor func testBackgroundSummaryWaitsForPresentationAndNotifiesOnce() async throws {
        var background = true, notifications = 0
        let center = ModelJobCenter(directory: try directory(), platformEnabled: false, isBackground: { background }, deliver: { _ in notifications += 1 })
        let controller = CalendarSummaryController(jobs: center)
        let request = CalendarSummaryRequest(title: "今天", input: CalendarSummaryInput(events: [], range: DateInterval(start: .now, duration: 86400), timeZone: .current))
        controller.setVisible(true)
        await controller.run(request) { _ in CalendarSummary(overview: "空闲", agenda: [], attention: [], suggestions: []) }.value
        XCTAssertEqual(notifications, 1)
        XCTAssertTrue(controller.needsPresentation)
        XCTAssertEqual(center.record(try XCTUnwrap(controller.jobID))?.seen, false)
        background = false; controller.setVisible(true)
        XCTAssertFalse(controller.needsPresentation)
        XCTAssertEqual(center.record(try XCTUnwrap(controller.jobID))?.seen, true)
    }

    private func directory() throws -> URL {
        let value = FileManager.default.temporaryDirectory.appendingPathComponent("ModelJobTests-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: value, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: value) }
        return value
    }
    @MainActor func testBackgroundCompletionIsDurableBeforeNotificationAndReplaysSessionOnce() async throws {
        let folder = try directory(), store = try SessionStore(inMemory: true)
        var delivered = 0
        let id = UUID()
        var followup: Task<Void, Never>?
        let center = ModelJobCenter(directory: folder, platformEnabled: false, isBackground: { true }, deliver: { record in
            guard record.id == id else { return }
            let stored = try? JSONDecoder().decode(ModelJobRecord.self, from: Data(contentsOf: folder.appendingPathComponent(record.id.uuidString + ".json")))
            XCTAssertEqual(stored?.status, .completed)
            XCTAssertEqual(stored?.notified, true)
            XCTAssertEqual(stored?.sessionApplied, true)
            delivered += 1
        })
        var session = ImportSession(); session.text = "测试输入"; session.hasParsed = true
        let task = center.start(id: id, kind: .extraction, work: { _ in
            await Task.yield()
            return .session(session)
        }, completion: { _ in
            center.applySessions(to: store)
            // A callback may start another task, changing record indices.
            followup = center.start(kind: .connection, work: { _ in .connection("连接成功") }, completion: { _ in })
        })
        await task.value
        await followup?.value
        XCTAssertEqual(center.record(id)?.status, .completed)
        XCTAssertEqual(center.record(id)?.sessionApplied, true)
        XCTAssertGreaterThanOrEqual(delivered, 1)
        var edited = try XCTUnwrap(try store.all().first); edited.text = "用户后来修改的原文"; try store.save(edited)
        let restored = ModelJobCenter(directory: folder, platformEnabled: false, deliver: { _ in XCTFail("Loading must not send again") })
        restored.applySessions(to: store)
        XCTAssertEqual(try store.all().first?.text, "用户后来修改的原文")
        XCTAssertEqual(restored.record(id)?.notified, true)
    }
    @MainActor func testForegroundCompletionNeverNotifiesAndOutlivesCaller() async throws {
        let center = ModelJobCenter(directory: try directory(), platformEnabled: false, isBackground: { false }, deliver: { _ in XCTFail("No foreground completion notice") })
        let completed = expectation(description: "app-owned task completes")
        let id = UUID()
        // Drop the returned handle: the center retains execution independently of a view.
        center.start(id: id, kind: .connection, work: { _ in
            try await Task.sleep(for: .milliseconds(30)); return .connection("完成")
        }, completion: { _ in completed.fulfill() })
        await fulfillment(of: [completed], timeout: 2)
        XCTAssertEqual(center.record(id)?.status, .completed)
        XCTAssertEqual(center.record(id)?.seen, true)
        XCTAssertEqual(center.record(id)?.notified, false)
    }
    @MainActor func testCancellationAndSystemExpiryHaveDifferentPersistedStates() async throws {
        let folder = try directory()
        let center = ModelJobCenter(directory: folder, platformEnabled: false, deliver: { _ in XCTFail("Cancelled jobs must not notify") })
        for interrupted in [false, true] {
            let id = UUID()
            let task = center.start(id: id, kind: .countdowns, inputText: "明天出发", referenceDate: .now, work: { _ in
                do { try await Task.sleep(for: .seconds(60)) }
                catch { throw URLError(.cancelled) }
                return .connection("不应到达")
            }, completion: { result in
                switch result {
                case .success: XCTFail("Expected cancellation")
                case .failure(let error): if !interrupted { XCTAssertTrue(error is CancellationError) }
                }
            })
            await Task.yield()
            if interrupted { center.interrupt(id) } else { center.cancel(id) }
            await task.value
            let value = try XCTUnwrap(center.record(id))
            XCTAssertEqual(value.status, interrupted ? .interrupted : .cancelled)
            XCTAssertEqual(value.inputText, "明天出发")
            XCTAssertFalse(value.error?.contains("网络") == true)
        }
    }
    @MainActor func testRestartRetainsValidResultsAndMarksOnlyRunningJobsInterrupted() throws {
        let folder = try directory()
        let running = ModelJobRecord(id: UUID(), kind: .countdowns, createdAt: .now, inputText: "下个月去旅行")
        let completed = ModelJobRecord(id: UUID(), kind: .summary, createdAt: .now, status: .completed,
            output: .summary(title: "本周", value: CalendarSummary(overview: "安排适中", agenda: ["阅读"], attention: [], suggestions: [])))
        for value in [running, completed] { try JSONEncoder().encode(value).write(to: folder.appendingPathComponent(value.id.uuidString + ".json")) }
        try Data("broken".utf8).write(to: folder.appendingPathComponent("broken.json"))
        let restored = ModelJobCenter(directory: folder, platformEnabled: false)
        XCTAssertEqual(restored.records.count, 2)
        XCTAssertEqual(restored.record(running.id)?.status, .interrupted)
        XCTAssertEqual(restored.record(completed.id)?.status, .completed)
        XCTAssertNotNil(restored.storageError)
        restored.delete(completed.id)
        XCTAssertNil(restored.record(completed.id))
        XCTAssertFalse(FileManager.default.fileExists(atPath: folder.appendingPathComponent(completed.id.uuidString + ".json").path))
    }
    @MainActor func testCannotStartNetworkWorkIfInitialJournalCannotBeSaved() async throws {
        let folder = try directory().appendingPathComponent("not-a-directory")
        try Data().write(to: folder)
        let center = ModelJobCenter(directory: folder, platformEnabled: false)
        let task = center.start(kind: .models, work: { _ in XCTFail("Must not contact model"); return .models([]) }, completion: { result in
            if case .success = result { XCTFail("Expected persistence failure") }
        })
        await task.value
        XCTAssertEqual(center.records.first?.status, .failed)
        XCTAssertNotNil(center.storageError)
    }
}
