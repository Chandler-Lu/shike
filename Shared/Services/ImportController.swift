import Foundation
import Combine
import SwiftUI
import ShikeCore

@MainActor final class AppEnvironment: ObservableObject {
    let preferences: Preferences
    let countdowns: CountdownStore
    let calendars: CalendarService
    let store: SessionStore?
    let startupError: String?
    let consent: ExtractionConsentStore
    let llmClient: LLMClient
    let modelJobs: ModelJobCenter
    #if !SHARE_EXTENSION
    lazy var backups = DataBackupService(environment: self)
    #endif
    init(preferences: Preferences? = nil, calendars: CalendarService? = nil, store: SessionStore? = nil,
         consent: ExtractionConsentStore? = nil, llmClient: LLMClient = LLMClient(), modelJobs: ModelJobCenter? = nil,
         countdowns: CountdownStore? = nil) {
        self.preferences = preferences ?? Preferences()
        self.countdowns = countdowns ?? CountdownStore(inMemory: AppIdentity.isUITesting)
        self.calendars = calendars ?? CalendarService()
        self.consent = consent ?? ExtractionConsentStore()
        self.llmClient = llmClient
        self.modelJobs = modelJobs ?? .shared
        do { self.store = try store ?? SessionStore(inMemory: AppIdentity.isUITesting); startupError = nil }
        catch { self.store = nil; startupError = error.localizedDescription }
        self.preferences.updateCalendars(self.calendars.calendars)
    }
    func refresh() {
        preferences.reload(); calendars.refresh()
        preferences.updateCalendars(calendars.calendars)
        preferences.checkCloudSync()
    }
}

struct DraftReview {
    let sessionID: UUID
    var selectedIDs: [UUID]
    var pendingIDs: [UUID]
    var completedCount = 0
}

@MainActor final class ImportController: ObservableObject {
    @Published var session: ImportSession { didSet { schedulePersistence() } }
    @Published var busyMessage: String?
    @Published var errorMessage: String?
    @Published var information: String?
    @Published private(set) var review: DraftReview?
    @Published private(set) var countdownReview: DraftReview?
    @Published private(set) var consentRequest: ExtractionConsent?
    let environment: AppEnvironment
    @Published var showsPlanning = false
    private var planningIntent = false
    private var conflictAcknowledgements: [UUID: String] = [:]
    private var conflictSnapshot: [CalendarEventSnapshot] = []
    private var operation: Task<Void, Never>?
    private var modelRequestID = UUID()
    private var persistence: Task<Void, Never>?
    private var countdownObservation: AnyCancellable?
    var isBusy: Bool { busyMessage != nil }

    init(environment: AppEnvironment, session: ImportSession = ImportSession()) {
        self.environment = environment; self.session = session
        countdownObservation = environment.countdowns.$revision.dropFirst().sink { [weak self] _ in
            self?.objectWillChange.send()
        }
    }

    func schedulePersistence() {
        persistence?.cancel()
        persistence = Task { [weak self] in
            do { try await Task.sleep(for: .milliseconds(500)); try Task.checkCancellation() }
            catch { return }
            self?.persistReportingError()
        }
    }
    func persist() throws {
        persistence?.cancel()
        guard !session.text.isEmpty || !session.drafts.isEmpty || !session.pendingImages.isEmpty || session.planning != nil else { return }
        guard let store = environment.store else { throw ShikeError.message(environment.startupError ?? "存储不可用") }
        try store.save(session)
    }
    func persistReportingError() {
        do { try persist() } catch { errorMessage = "草稿保存失败：\(error.localizedDescription)" }
    }

    func refreshReferenceDate(now: Date = .now) {
        guard !isBusy, review == nil, countdownReview == nil, consentRequest == nil, session.savedCount == 0 else { return }
        session.referenceDate = now
        persistReportingError()
        information = nil
    }

    func startNew() {
        guard !isBusy, review == nil, countdownReview == nil, consentRequest == nil else { return }
        do { try persist(); session = ImportSession(); information = nil; errorMessage = nil }
        catch { errorMessage = error.localizedDescription }
    }

    func discardDeletedSession(_ ids: Set<UUID>) {
        guard ids.contains(session.id) else { return }
        operation?.cancel(); persistence?.cancel()
        busyMessage = nil; review = nil; countdownReview = nil; consentRequest = nil; showsPlanning = false
        conflictAcknowledgements.removeAll(); conflictSnapshot.removeAll()
        session = ImportSession(); information = nil; errorMessage = nil
    }

    func appendText(_ text: String, source: String) {
        guard !isBusy else { return }
        errorMessage = nil
        if session.hasParsed { startNew() }
        guard errorMessage == nil else { return }
        session.source = source
        session.text += (session.text.isEmpty ? "" : "\n\n") + text
        information = nil
        persistReportingError()
    }

    func importImages(_ images: [Data], source: String, appendedText: String? = nil) {
        var files: [String] = []
        do {
            for image in images { files.append(try ImageStaging.write(image)) }
            importImageFiles(files, source: source, appendedText: appendedText)
        } catch {
            files.forEach(ImageStaging.remove)
            errorMessage = error.localizedDescription
        }
    }

    func importImageFiles(_ files: [String], source: String, appendedText: String? = nil) {
        guard !isBusy else { files.forEach(ImageStaging.remove); return }
        if session.hasParsed {
            errorMessage = nil
            startNew()
            guard errorMessage == nil else { files.forEach(ImageStaging.remove); return }
        }
        guard !files.isEmpty else {
            if let appendedText { appendText(appendedText, source: source) }
            return
        }
        session.source = source
        session.pendingImages.append(contentsOf: files)
        if let appendedText, !appendedText.isEmpty {
            session.text += (session.text.isEmpty ? "" : "\n\n") + appendedText
        }
        errorMessage = nil; information = nil
        resumeImages()
    }

    func resumeImages(parseAfterRecognition: Bool = false) {
        guard !isBusy, !session.pendingImages.isEmpty else { return }
        do { try persist() } catch { errorMessage = error.localizedDescription; return }
        busyMessage = "正在识别图片…"
        let files = session.pendingImages
        operation = Task {
            var startedModel = false
            defer { if !startedModel { busyMessage = nil } }
            var failures: [String] = []
            for (index, file) in files.enumerated() {
                busyMessage = "正在识别第 \(index + 1) / \(files.count) 张图片…"
                do {
                    try Task.checkCancellation()
                    let text = try await OCRService.recognizeFile(ImageStaging.url(for: file))
                    try Task.checkCancellation()
                    session.text += (session.text.isEmpty ? "" : "\n\n") + text
                    session.pendingImages.removeAll { $0 == file }
                    try persist()
                    ImageStaging.remove(file)
                } catch is CancellationError { return }
                catch { failures.append("第 \(index + 1) 张：\(error.localizedDescription)") }
            }
            busyMessage = nil
            if !failures.isEmpty { errorMessage = failures.joined(separator: "\n") }
            else {
                information = "文字已识别，可以核对后提取日程。"
                if parseAfterRecognition { parse(); startedModel = isBusy }
            }
        }
    }

    func parse() {
        planningIntent = false
        guard !isBusy, review == nil, countdownReview == nil, consentRequest == nil else { return }
        guard !session.drafts.contains(where: \.isSaved) else {
            errorMessage = "已有日程保存到日历，请新建一次导入再解析。"; return
        }
        errorMessage = nil; information = nil
        do {
            if let scope = try currentConsentScope(), !environment.consent.allows(scope) {
                consentRequest = scope
                return
            }
        } catch { errorMessage = error.localizedDescription; return }
        let extraction: (@escaping LLMObserver) async throws -> [EventDraft]
        do { extraction = try prepareExtraction() }
        catch { errorMessage = error.localizedDescription; return }
        busyMessage = "正在整理日程…"
        operation = environment.modelJobs.start(kind: .extraction, work: { [self] context in
                try Task.checkCancellation()
                try persist()
                let drafts = try await extraction(context.observer(modelObserver()))
                try Task.checkCancellation()
                // Parsing never overwrites already saved events; the UI starts a fresh import for new material.
                guard !session.drafts.contains(where: \.isSaved) else { throw ShikeError.message("已有日程保存到日历，请新建一次导入再解析。") }
                var replacement = session
                replacement.drafts = drafts.map {
                    var draft = $0
                    if let forced = session.forcedCategory { draft.category = forced }
                    draft.calendarID = environment.preferences.calendarID(for: draft.category, calendars: environment.calendars, suggestedID: draft.suggestedCalendarID)
                    return draft
                }
                replacement.hasParsed = true
                replacement.planning = nil
                #if DEBUG
                if AppIdentity.isUITesting && ProcessInfo.processInfo.arguments.contains("-review-fixture") {
                    replacement.drafts[0].needsReview = true
                    replacement.drafts[0].reviewNotes = ["请确认会议日期"]
                    replacement.drafts[1].title = ""
                    replacement.drafts[1].start = nil; replacement.drafts[1].end = nil
                    replacement.drafts[1].calendarID = nil
                }
                #endif
                return .session(replacement)
        }, completion: { [self] result in
            busyMessage = nil
            switch result {
            case .success(.session(let replacement)):
                session = replacement
                environment.modelJobs.applySessions(to: environment.store)
                if replacement.drafts.isEmpty { information = "没有找到明确的日程。可以补充日期、时间和安排后再试。" }
            case .failure(let error):
                if error is CancellationError { information = "已取消，原文已保留。" }
                else { errorMessage = error.localizedDescription }
            default: break
            }
        })
    }

    private func modelObserver() -> LLMObserver {
        let id = UUID(); modelRequestID = id
        return { [weak self] update in
            guard case .progress(let progress) = update else { return }
            Task { @MainActor [weak self] in
                guard let self, self.modelRequestID == id, self.isBusy else { return }
                self.busyMessage = progress.message
            }
        }
    }

    private func prepareExtraction() throws -> (@escaping LLMObserver) async throws -> [EventDraft] {
        #if DEBUG
        if AppIdentity.usesFixtureModel {
            return { _ in
                try await Task.sleep(for: .milliseconds(300))
                return try ExtractionDecoder.decode(Self.testResponse, timeZone: TimeZone(identifier: "Asia/Shanghai")!)
            }
        }
        #endif
        let preferences = environment.preferences
        let profile = preferences.activeProfile
        let configuration = profile?.configuration ?? preferences.configuration
        // Check the exact configuration snapshot that will be used below. No suspension occurs
        // between the permission check and constructing the request's arguments.
        let scope = try ExtractionConsent(configuration: configuration, includesCalendarNames: preferences.categoryRoutingEnabled)
        guard environment.consent.allows(scope) else {
            consentRequest = scope
            throw ShikeError.message("接口或发送范围已变化，请确认后再提取。")
        }
        let apiKey = try profile.map { try preferences.profileKey($0) } ?? ""
        let calendars = preferences.categoryRoutingEnabled ? environment.calendars.calendars : []
        let candidates = calendars.enumerated().map { CalendarCandidate(id: "calendar-\($0.offset)", name: $0.element.title) }
        let identifiers = Dictionary(uniqueKeysWithValues: zip(candidates.map(\.id), calendars.map(\.id)))
        let session = session, prompts = preferences.promptSettings, client = environment.llmClient
        return { observer in
        let drafts = try await client.extract(text: session.text, referenceDate: session.effectiveReferenceDate,
                                     timeZone: TimeZone(identifier: session.referenceTimeZone) ?? .current,
                                     configuration: configuration, apiKey: apiKey,
                                     calendars: candidates,
                                     forcedCategory: session.forcedCategory, prompts: prompts, observer: observer)
        return drafts.map { draft in
            var draft = draft
            draft.suggestedCalendarID = draft.suggestedCalendarID.flatMap { identifiers[$0] }
            return draft
        }
        }
    }

    private func currentConsentScope() throws -> ExtractionConsent? {
        var configuration = environment.preferences.activeProfile?.configuration ?? environment.preferences.configuration
        #if DEBUG
        if AppIdentity.usesFixtureModel {
            guard AppIdentity.usesConsentFixture else { return nil }
            configuration = APIConfiguration(baseURL: "https://review.example.com/v1", model: "fixture")
        }
        #endif
        return try ExtractionConsent(configuration: configuration, includesCalendarNames: environment.preferences.categoryRoutingEnabled, includesPlanning: planningIntent, includesAvailability: planningIntent && environment.calendars.authorized)
    }

    func allowExtraction() {
        guard let pending = consentRequest else { return }
        do {
            let current = try currentConsentScope()
            guard current == pending else {
                consentRequest = current
                information = "接口或发送范围已变化，请重新确认。"
                return
            }
            environment.consent.grant(pending)
            consentRequest = nil
            if planningIntent { advancePlanning() } else { parse() }
        } catch { consentRequest = nil; errorMessage = error.localizedDescription }
    }

    func declineExtraction() {
        consentRequest = nil
        information = "未发送内容，原文和草稿已保留。"
    }

    func cancel() {
        modelRequestID = UUID()
        operation?.cancel()
        information = "已取消，已识别的文字已保留。"
    }

    func requestCalendarAccess() async {
        do {
            try await environment.calendars.requestAccess()
            environment.preferences.updateCalendars(environment.calendars.calendars)
            for index in session.drafts.indices where session.drafts[index].calendarID == nil {
                session.drafts[index].calendarID = environment.preferences.calendarID(for: session.drafts[index].category,
                                                                                     calendars: environment.calendars, suggestedID: session.drafts[index].suggestedCalendarID)
            }
        } catch { errorMessage = error.localizedDescription }
    }

    func setBatchCalendar(_ id: String) {
        for index in session.drafts.indices where !session.drafts[index].isSaved {
            session.drafts[index].calendarID = id.isEmpty ? nil : id
        }
    }

    func saveSelected() {
        guard !isBusy, review == nil, countdownReview == nil else { return }
        guard session.drafts.contains(where: { $0.selected && !$0.isSaved }) else { return }
        guard session.planning != nil else { beginSaveSelected(); return }
        busyMessage = "正在检查时间冲突…"
        operation = Task {
            do {
                try await refreshPlanningConflicts()
                try Task.checkCancellation()
                busyMessage = nil
                beginSaveSelected()
            } catch { busyMessage = nil; errorMessage = error.localizedDescription }
        }
    }

    private var countdownSourceIdentifiers: Set<String> {
        Set(environment.countdowns.entries.compactMap(\.sourceIdentifier))
    }

    var destinationCompletionMessage: String? {
        let drafts = session.drafts, sources = countdownSourceIdentifiers
        guard !drafts.isEmpty,
              drafts.allSatisfy({ $0.isSaved || sources.contains(CountdownConversion.sourceIdentifier(for: $0)) }) else { return nil }
        let calendarCount = drafts.filter(\.isSaved).count
        let countdownCount = drafts.filter { sources.contains(CountdownConversion.sourceIdentifier(for: $0)) }.count
        if calendarCount == drafts.count && countdownCount == drafts.count { return "全部日程已加入日历和倒数日。" }
        if calendarCount == drafts.count && countdownCount == 0 { return "全部日程已加入日历。" }
        if countdownCount == drafts.count && calendarCount == 0 { return "全部日程已加入倒数日。" }
        return "已加入日历 \(calendarCount) 个，倒数日 \(countdownCount) 个。"
    }

    var pendingCountdownDrafts: [EventDraft] {
        let sources = countdownSourceIdentifiers
        return session.drafts.filter { $0.selected && !sources.contains(CountdownConversion.sourceIdentifier(for: $0)) }
    }

    func addSelectedCountdowns() {
        guard !isBusy, review == nil, countdownReview == nil else { return }
        let selected = pendingCountdownDrafts
        guard !selected.isEmpty else { return }
        errorMessage = nil; information = nil
        // Saved calendar events have already been confirmed. Only unsaved drafts need review.
        let pending = selected.filter { !$0.isSaved && ($0.needsReview || (try? CountdownConversion.from($0)) == nil) }.map(\.id)
        if !pending.isEmpty {
            countdownReview = DraftReview(sessionID: session.id, selectedIDs: selected.map(\.id), pendingIDs: pending)
        } else {
            do { try saveCountdowns(selected.map(\.id)) } catch { errorMessage = error.localizedDescription }
        }
    }

    var countdownReviewDraft: EventDraft? {
        guard let id = countdownReview?.pendingIDs.first else { return nil }
        return session.drafts.first { $0.id == id && $0.selected && !$0.isSaved }
    }
    func cancelCountdownReview() { countdownReview = nil }
    func confirmCountdownReview(_ edited: EventDraft) throws {
        guard !isBusy, var progress = countdownReview, progress.sessionID == session.id,
              countdownReviewDraft?.id == edited.id else { throw ShikeError.message("核对内容已变化，请重新打开。") }
        _ = try CountdownConversion.from(edited)
        // Confirming a countdown date does not approve the calendar's end time or conflict suggestions.
        try persistReviewEdit(edited)
        progress.pendingIDs.removeFirst(); progress.completedCount += 1
        countdownReview = progress
        if progress.pendingIDs.isEmpty { try finishCountdownReview() }
    }
    func finishCountdownReview() throws {
        guard let progress = countdownReview, progress.sessionID == session.id,
              progress.pendingIDs.isEmpty, !isBusy else { return }
        do { try saveCountdowns(progress.selectedIDs) }
        catch { errorMessage = error.localizedDescription; throw error }
        countdownReview = nil
    }
    private func saveCountdowns(_ ids: [UUID]) throws {
        let selected = session.drafts.filter { ids.contains($0.id) && $0.selected }
        guard selected.count == ids.count else { throw ShikeError.message("所选日程已发生变化，请重新选择。") }
        // Recheck after review: another window or cloud sync may have added some days.
        let pending = pendingCountdownDrafts.filter { ids.contains($0.id) }
        guard !pending.isEmpty else { return }
        let entries = try pending.map { try CountdownConversion.from($0) }
        busyMessage = "正在加入倒数日…"
        defer { busyMessage = nil }
        try persist()
        try environment.countdowns.insertConverted(entries)
        var updated = session
        let addedIDs = Set(pending.map(\.id))
        for index in updated.drafts.indices where addedIDs.contains(updated.drafts[index].id) { updated.drafts[index].selected = false }
        do {
            guard let store = environment.store else { throw ShikeError.message("记录存储不可用。") }
            try store.save(updated)
        } catch {
            throw ShikeError.message("倒数日已保存，但勾选状态保存失败。已加入的项目不会重复添加。\(error.localizedDescription)")
        }
        session = updated
        information = "已将 \(entries.count) 个日程加入倒数日。"
    }

    private func beginSaveSelected() {
        guard !isBusy, review == nil else { return }
        environment.calendars.refresh()
        let selected = session.drafts.filter { $0.selected && !$0.isSaved }
        guard !selected.isEmpty else { return }
        guard environment.calendars.authorized else {
            errorMessage = "请先允许日历完全访问。"; return
        }
        errorMessage = nil; information = nil
        let pending = selected.filter { !saveIssues($0).isEmpty }.map(\.id)
        if !pending.isEmpty {
            review = DraftReview(sessionID: session.id, selectedIDs: selected.map(\.id), pendingIDs: pending)
        } else { performSave(selected) }
    }

    func saveIssues(_ draft: EventDraft, confirmingSuggestions: Bool = false) -> [String] {
        var issues = draft.saveValidationMessages(writableCalendarIDs: Set(environment.calendars.calendars.map(\.id)),
                                     confirmingSuggestions: confirmingSuggestions)
        if let plan = session.planning, let start = draft.start, let end = draft.end {
            if start < plan.start || end > plan.end { issues.append("请将时间调整到安排范围内，或先修改安排范围") }
            if start < Date.now { issues.append("开始时间已过去，请调整到未来") }
            if !confirmingSuggestions, conflictAcknowledgements[draft.id] != conflictFingerprint(draft) {
                issues += conflictMessages(draft)
            }
        }
        return issues
    }

    var reviewDraft: EventDraft? {
        guard let id = review?.pendingIDs.first else { return nil }
        guard var draft = session.drafts.first(where: { $0.id == id && $0.selected && !$0.isSaved }) else { return nil }
        if session.planning != nil { draft.reviewNotes += conflictMessages(draft) }
        return draft
    }

    var reviewSaveCount: Int {
        guard let review else { return 0 }
        return session.drafts.filter { review.selectedIDs.contains($0.id) && $0.selected && !$0.isSaved }.count
    }

    func cancelReview() { review = nil }

    func confirmReview(_ edited: EventDraft) throws {
        guard !isBusy, var progress = review, progress.sessionID == session.id,
              reviewDraft?.id == edited.id else { throw ShikeError.message("核对内容已变化，请重新打开。") }
        environment.calendars.refresh()
        guard environment.calendars.authorized else { throw ShikeError.message("日历权限已关闭，请退出核对并重新授权。") }
        let issues = saveIssues(edited, confirmingSuggestions: true)
        guard issues.isEmpty else { throw ShikeError.message(issues.joined(separator: "\n")) }
        var confirmed = edited
        confirmed.needsReview = false
        try persistReviewEdit(confirmed)
        conflictAcknowledgements[confirmed.id] = conflictFingerprint(confirmed)
        progress.pendingIDs.removeFirst(); progress.completedCount += 1
        review = progress
        if progress.pendingIDs.isEmpty { try finishReview() }
    }

    func skipReview(_ edited: EventDraft) throws {
        guard !isBusy, var progress = review, progress.sessionID == session.id,
              reviewDraft?.id == edited.id else { throw ShikeError.message("核对内容已变化，请重新打开。") }
        var skipped = edited; skipped.selected = false
        try persistReviewEdit(skipped)
        progress.pendingIDs.removeFirst(); progress.selectedIDs.removeAll { $0 == edited.id }
        progress.completedCount += 1
        review = progress
        if reviewSaveCount == 0 { review = nil }
        // Skipping is never consent to write the remaining events. Show an explicit final action.
    }

    private func persistReviewEdit(_ draft: EventDraft) throws {
        guard let index = session.drafts.firstIndex(where: { $0.id == draft.id && !$0.isSaved }),
              let store = environment.store else { throw ShikeError.message("无法保存核对进度，请稍后重试。") }
        var updated = session
        updated.drafts[index] = draft
        try store.save(updated)
        session = updated
    }

    func finishReview() throws {
        guard !isBusy, var progress = review, progress.sessionID == session.id else { return }
        environment.calendars.refresh()
        guard environment.calendars.authorized else { throw ShikeError.message("日历权限已关闭，请退出核对并重新授权。") }
        let selected = session.drafts.filter { progress.selectedIDs.contains($0.id) && $0.selected && !$0.isSaved }
        let pending = selected.filter { !saveIssues($0).isEmpty }.map(\.id)
        if !pending.isEmpty {
            progress.pendingIDs = pending; review = progress
            return
        }
        review = nil
        if !selected.isEmpty { performSave(selected) }
    }

    private func performSave(_ selected: [EventDraft]) {
        guard !isBusy else { return }
        errorMessage = nil; information = nil
        busyMessage = "正在加入日历…"
        operation = Task {
            defer { busyMessage = nil }
            if session.planning != nil {
                do {
                    try await refreshPlanningConflicts()
                    let pending = selected.filter { !saveIssues($0).isEmpty }.map(\.id)
                    if !pending.isEmpty {
                        review = DraftReview(sessionID: session.id, selectedIDs: selected.map(\.id), pendingIDs: pending)
                        return
                    }
                } catch { errorMessage = error.localizedDescription; return }
            }
            var successes = 0
            for id in selected.map(\.id) {
                guard let index = session.drafts.firstIndex(where: { $0.id == id }), !session.drafts[index].isSaved else { continue }
                do {
                    // Durable intent prevents an interrupted save from silently creating a duplicate on retry.
                    session.drafts[index].saveAttemptInProgress = true
                    try persist()
                } catch {
                    session.drafts[index].saveAttemptInProgress = false
                    errorMessage = "无法保存导入进度，已停止写入日历：\(error.localizedDescription)"
                    return
                }
                do {
                    session.drafts[index] = try environment.calendars.save(session.drafts[index])
                    session.drafts[index].selected = false
                    successes += 1
                } catch {
                    session.drafts[index].saveAttemptInProgress = false
                    session.drafts[index].saveError = error.localizedDescription
                }
                do { try persist() }
                catch {
                    errorMessage = "日历处理已完成，但导入记录更新失败。请核对系统日历，避免再次导入。"
                    return
                }
                await Task.yield()
            }
            let failures = session.drafts.filter { selected.map(\.id).contains($0.id) && !$0.isSaved }.count
            information = failures == 0 ? "已将 \(successes) 个日程加入日历。" : "已保存 \(successes) 个日程，\(failures) 个未保存，可修改后重试。"
        }
    }

    func prepareEdit(_ draft: EventDraft) -> EventDraft? {
        do { return draft.isSaved ? try environment.calendars.latest(draft) : draft }
        catch { errorMessage = error.localizedDescription; return nil }
    }

    func applyEdit(_ draft: EventDraft, expected: EventDraft? = nil) throws {
        guard let index = session.drafts.firstIndex(where: { $0.id == draft.id }) else { return }
        if draft.isSaved {
            if let expected {
                let latest = try environment.calendars.latest(expected)
                guard latest.title == expected.title, latest.start == expected.start, latest.end == expected.end,
                      latest.location == expected.location, latest.notes == expected.notes,
                      latest.isAllDay == expected.isAllDay, latest.calendarID == expected.calendarID,
                      latest.timeZoneIdentifier == expected.timeZoneIdentifier,
                      latest.reminderMinutes == expected.reminderMinutes else {
                    throw ShikeError.message("这个日程在编辑期间已被其他应用修改。请取消并重新打开，读取最新内容。")
                }
            }
            session.drafts[index] = try environment.calendars.save(draft, updatingExisting: true)
        } else { session.drafts[index] = draft }
        try persist()
        information = draft.isSaved ? "日历中的日程已更新。" : nil
    }

    #if DEBUG
    static let testResponse = #"{"events":[{"title":"产品设计评审","category":"work","start":"2026-10-14T14:00:00+08:00","end":"2026-10-14T15:30:00+08:00","allDay":false,"timeZone":"Asia/Shanghai","location":"三楼会议室","notes":"带上新的交互稿","sourceExcerpt":"明天下午两点到三点半，产品设计评审，三楼会议室。带上新的交互稿。","reminderMinutes":15,"needsReview":false,"reviewNotes":[]},{"title":"和小林喝咖啡","category":"personal","start":"2026-10-15T10:00:00+08:00","end":null,"allDay":false,"timeZone":"Asia/Shanghai","location":"街角咖啡馆","notes":"","sourceExcerpt":"后天上午十点和小林在街角咖啡馆喝咖啡。","reminderMinutes":null,"needsReview":false,"reviewNotes":[]}]}"#
    #endif
}

extension ImportController {
    func restartPlanning() {
        guard !isBusy, review == nil, countdownReview == nil, consentRequest == nil, let previous = session.planning else { return }
        guard !previous.goal.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        do {
            // Keep the old conversation in history; restart from the same goal and range.
            try persist()
            var fresh = session
            fresh.id = UUID(); fresh.createdAt = .now
            fresh.drafts = []; fresh.hasParsed = false
            var plan = PlanningConversation(goal: previous.goal, now: session.effectiveReferenceDate,
                                            timeZone: TimeZone(identifier: session.referenceTimeZone) ?? .current)
            plan.start = previous.start; plan.end = previous.end
            fresh.planning = plan
            guard let store = environment.store else { throw ShikeError.message("存储不可用") }
            try store.save(fresh)
            session = fresh
            conflictAcknowledgements.removeAll(); conflictSnapshot.removeAll()
            advancePlanning()
        } catch { errorMessage = error.localizedDescription }
    }

    func openPlanning() {
        guard !isBusy, review == nil, countdownReview == nil, consentRequest == nil else { return }
        let text = session.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        do {
            if session.savedCount > 0 || (session.planning == nil && session.hasParsed) || (session.planning?.turns.isEmpty == false && session.planning?.goal != text) {
                let category = session.forcedCategory
                try persist()
                session = ImportSession(); session.text = text; session.forcedCategory = category
            }
            if session.planning == nil {
                session.planning = PlanningConversation(goal: text, timeZone: TimeZone(identifier: session.referenceTimeZone) ?? .current)
                session.source = "帮我安排"
            } else if session.planning?.turns.isEmpty == true {
                session.planning?.goal = text
            }
            try persist()
            showsPlanning = true
        } catch { errorMessage = error.localizedDescription }
    }

    func advancePlanning(answer: String? = nil) {
        guard !isBusy, review == nil, countdownReview == nil, consentRequest == nil, session.savedCount == 0, var conversation = session.planning else { return }
        planningIntent = true
        errorMessage = nil; information = nil
        if let answer {
            let clean = answer.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !clean.isEmpty else { return }
            // A failed turn is retried without adding a duplicate answer.
            if conversation.awaitingReply && conversation.turns.last?.role == "user" { conversation.turns.removeLast() }
            conversation.turns.append(PlanningTurn(role: "user", text: clean))
            if !session.drafts.isEmpty { conversation.proposalNeedsUpdate = true }
        }
        conversation.awaitingReply = true
        session.planning = conversation
        do {
            try conversation.validate(timeZone: TimeZone(identifier: session.referenceTimeZone) ?? .current)
            try persist()
            if let scope = try currentConsentScope(), !environment.consent.allows(scope) { consentRequest = scope; return }
        } catch { errorMessage = error.localizedDescription; return }
        let preferences = environment.preferences
        let profile = preferences.activeProfile
        let configuration = profile?.configuration ?? preferences.configuration
        let key: String
        do { key = AppIdentity.usesFixtureModel ? "" : try profile.map { try preferences.profileKey($0) } ?? "" }
        catch { errorMessage = error.localizedDescription; return }
        let inputSession = session, prompts = preferences.promptSettings
        let planningConsent: ExtractionConsent?
        do { planningConsent = try currentConsentScope() }
        catch { errorMessage = error.localizedDescription; return }
        let searchConfiguration = preferences.searchReady ? preferences.searchSettings.selected : nil
        let searchKey: String
        do { searchKey = try searchConfiguration.map { try preferences.searchKey(for: $0) } ?? "" }
        catch { searchKey = ""; information = "搜索 Key 暂不可读取，本次先使用模型已有知识安排。" }
        let calendars = preferences.categoryRoutingEnabled ? environment.calendars.calendars : []
        let candidates = calendars.enumerated().map { CalendarCandidate(id: "calendar-\($0.offset)", name: $0.element.title) }
        let identifiers = Dictionary(uniqueKeysWithValues: zip(candidates.map(\.id), calendars.map(\.id)))
        busyMessage = "正在帮你安排…"
        operation = environment.modelJobs.start(kind: .planning, work: { [self] context in
                let zone = TimeZone(identifier: session.referenceTimeZone) ?? .current
                let now = Date.now
                guard conversation.end > now else { throw ShikeError.message("安排范围已经过去，请调整日期后再试。") }
                let range = DateInterval(start: max(conversation.start, now), end: conversation.end)
                let events: [CalendarEventSnapshot]?
                if environment.calendars.authorized {
                    let references = environment.preferences.calendarPreferences.planningCalendars
                    let ids = environment.calendars.calendarIDs(for: references)
                    if let references, ids.count < references.count {
                        throw ShikeError.message("部分参考日历已不可用，请重新选择参考日历。")
                    }
                    events = try await environment.calendars.events(in: DateInterval(start: range.start.addingTimeInterval(-172800), end: range.end.addingTimeInterval(172800)), calendarIDs: ids)
                } else { events = nil }
                let free = events.map { Scheduling.freeIntervals(in: range, busy: $0.filter(\.blocksPlanningTime).map { $0.interval(in: zone) }) }
                guard (preferences.activeProfile?.configuration ?? preferences.configuration) == configuration else {
                    throw ShikeError.message("接口已变化，请重新发起安排。")
                }
                // Recheck after calendar IO so revocation/configuration changes cannot race a request.
                if let scope = try currentConsentScope(), !environment.consent.allows(scope) {
                    consentRequest = scope
                    throw ShikeError.message("发送范围有变化，请确认后继续。")
                }
                let reply: PlanningReply
                let research: PlanningResearchRuntime?
                if let searchConfiguration {
                    let allowed: @Sendable () async -> Bool = { @MainActor in
                        preferences.searchReady && preferences.searchSettings.selected == searchConfiguration
                    }
                    if searchKey.isEmpty {
                        research = nil
                        information = "搜索 API Key 尚未同步到本机，本次先使用模型已有知识安排。"
                    } else {
                        research = PlanningResearchRuntime(tools: SearchAPIClient(configuration: searchConfiguration, apiKey: searchKey, isAllowed: allowed),
                            isAllowed: allowed, checkpoint: { @MainActor [weak self] value in
                                try Task.checkCancellation()
                                guard let self, self.session.id == inputSession.id, self.isBusy else { throw CancellationError() }
                                self.session.planning?.research = value
                                try self.persist()
                            }, beforeModel: { @MainActor [weak self] in
                                guard let self, self.session.id == inputSession.id, self.isBusy else { throw CancellationError() }
                                guard (preferences.activeProfile?.configuration ?? preferences.configuration) == configuration else {
                                    throw ShikeError.message("模型接口已变化，请重新发起安排。")
                                }
                                if let scope = planningConsent, !self.environment.consent.allows(scope) {
                                    throw ShikeError.message("模型发送授权已撤销，已有问答和资料已保留。")
                                }
                            })
                    }
                } else {
                    research = nil
                    if preferences.searchSettings.enabled { information = "联网搜索待配置或待本机授权，本次先使用模型已有知识安排。" }
                }
                #if DEBUG
                if AppIdentity.usesFixtureModel {
                    try await Task.sleep(for: .milliseconds(300))
                    reply = fixturePlanningReply(conversation, zone: zone)
                } else {
                    reply = try await environment.llmClient.plan(conversation: conversation, drafts: inputSession.drafts, timeZone: zone,
                        referenceDate: now, available: free, configuration: configuration, apiKey: key,
                        calendars: candidates, forcedCategory: inputSession.forcedCategory, prompts: prompts, observer: context.observer(modelObserver()), research: research)
                }
                #else
                reply = try await environment.llmClient.plan(conversation: conversation, drafts: inputSession.drafts, timeZone: zone,
                    referenceDate: now, available: free, configuration: configuration, apiKey: key,
                    calendars: candidates, forcedCategory: inputSession.forcedCategory, prompts: prompts, observer: context.observer(modelObserver()), research: research)
                #endif
                try Task.checkCancellation()
                var updated = session
                conversation.turns.append(PlanningTurn(role: "assistant", text: reply.message, options: reply.options))
                conversation.awaitingReply = false
                conversation.checkedAvailability = events != nil
                conversation.research = reply.research ?? session.planning?.research
                conversation.sourceIDs = reply.sourceIDs
                if reply.kind == .proposal {
                    conversation.hasProposal = true
                    conversation.proposalNeedsUpdate = false
                    updated.drafts = reply.drafts.map { value in
                        var draft = value
                        draft.suggestedCalendarID = draft.suggestedCalendarID.flatMap { identifiers[$0] }
                        if let forced = session.forcedCategory { draft.category = forced }
                        draft.calendarID = preferences.calendarID(for: draft.category, calendars: environment.calendars, suggestedID: draft.suggestedCalendarID)
                        if let start = draft.start, let end = draft.end {
                            if start < max(conversation.start, now) || end > conversation.end {
                                draft.needsReview = true; draft.reviewNotes.append("建议时间已过去或超出安排范围，请修改")
                            }
                        }
                        if events == nil { draft.needsReview = true; draft.reviewNotes.append("尚未读取日历，保存前需要检查已有安排") }
                        return draft
                    }
                    for index in updated.drafts.indices {
                        guard !updated.drafts[index].isAllDay,
                              let start = updated.drafts[index].start, let end = updated.drafts[index].end, end > start else { continue }
                        let interval = DateInterval(start: start, end: end)
                        let existingConflict = events?.contains { $0.blocksPlanningTime && Scheduling.overlaps($0.interval(in: zone), interval) } == true
                        let proposalConflict = updated.drafts.enumerated().contains { otherIndex, other in
                            guard index != otherIndex, !other.isAllDay,
                                  let otherStart = other.start, let otherEnd = other.end, otherEnd > otherStart else { return false }
                            return Scheduling.overlaps(DateInterval(start: otherStart, end: otherEnd), interval)
                        }
                        if existingConflict || proposalConflict {
                            updated.drafts[index].needsReview = true
                            updated.drafts[index].reviewNotes.append("建议与其他安排重叠，请在保存前核对")
                        }
                    }
                    updated.hasParsed = true
                    conflictAcknowledgements.removeAll()
                }
                updated.planning = conversation
                conflictSnapshot = events ?? []
                if events == nil { information = "尚未检查已有安排；允许日历访问后会在保存前补查。" }
                return .session(updated)
        }, completion: { [self] result in
            busyMessage = nil
            switch result {
            case .success(.session(let updated)):
                session = updated
                environment.modelJobs.applySessions(to: environment.store)
            case .failure(let error):
                if error is CancellationError { information = "已取消，问答和原方案已保留。" }
                else { errorMessage = error.localizedDescription }
            default: break
            }
        })
    }

    #if DEBUG
    private func fixturePlanningReply(_ conversation: PlanningConversation, zone: TimeZone) -> PlanningReply {
        if ProcessInfo.processInfo.arguments.contains("-promotion-search-fixture") {
            var calendar = Calendar(identifier: .gregorian); calendar.timeZone = zone
            let day = calendar.date(byAdding: .day, value: 1, to: max(conversation.start, .now))!
            let stops = [("故宫慢游", 9, 12, "午门", "提前实名预约门票，从午门进入。"),
                         ("午餐与休息", 12, 13, "故宫周边", "给午餐和步行留出时间。交通耗时为估算。"),
                         ("景山散步", 14, 16, "景山公园", "放慢脚步，看看北京的秋天；出发前再核对开放情况。")]
            let drafts = stops.map { title, start, end, location, notes in
                var draft = EventDraft(); draft.title = title; draft.category = .travel
                draft.start = calendar.date(bySettingHour: start, minute: 0, second: 0, of: day)
                draft.end = calendar.date(bySettingHour: end, minute: 0, second: 0, of: day)
                draft.timeZoneIdentifier = zone.identifier; draft.location = location
                draft.notes = notes; draft.sourceExcerpt = conversation.goal
                return draft
            }
            var reply = PlanningReply(kind: .proposal, message: "上午留给故宫，午后慢慢散步。已参考开放时间与预约说明，门票请提前预约。交通时间为估算，安排可以继续调整。", drafts: drafts)
            var research = PlanningResearch()
            research.sources = [
                PlanningSource(id: "palace-hours", title: "故宫博物院 · 开放时间", url: URL(string: "https://www.dpm.org.cn/Visit.html")!, content: "旺季 8:30 开放，17:00 闭馆；从午门进入。", kind: .page),
                PlanningSource(id: "palace-booking", title: "故宫博物院 · 参观预约", url: URL(string: "https://ticket.dpm.org.cn/")!, content: "提前实名预约，通过官方渠道购买门票。", kind: .page)
            ]
            reply.research = research; reply.sourceIDs = research.sources.map(\.id)
            return reply
        }
        if !conversation.turns.contains(where: { $0.role == "user" }) {
            return PlanningReply(kind: .question, message: "你希望每次留多少时间？", options: ["每次 30 分钟，晚上安排", "每次 1 小时，下午安排", "你来决定"])
        }
        var calendar = Calendar(identifier: .gregorian); calendar.timeZone = zone
        let day = calendar.date(byAdding: .day, value: 1, to: max(conversation.start, .now))!
        var draft = EventDraft(); draft.title = "读书与笔记"; draft.category = .study
        draft.start = calendar.date(bySettingHour: 19, minute: 0, second: 0, of: day)
        draft.end = draft.start!.addingTimeInterval(1800); draft.timeZoneIdentifier = zone.identifier
        draft.notes = "读一小节，写下三个收获。"; draft.sourceExcerpt = conversation.goal
        return PlanningReply(kind: .proposal, message: "先从半小时开始，给阅读留一点安静的时间。时间和内容都可以继续调整。", drafts: [draft])
    }
    #endif
}


extension ImportController {
    private func refreshPlanningConflicts() async throws {
        guard let plan = session.planning else { return }
        guard plan.proposalNeedsUpdate != true else { throw ShikeError.message("新的要求尚未生成方案，请继续问答或在安排页选择使用上一版方案。") }
        try plan.validate(timeZone: TimeZone(identifier: session.referenceTimeZone) ?? .current)
        environment.calendars.refresh()
        let references = environment.preferences.calendarPreferences.planningCalendars
        let ids = environment.calendars.calendarIDs(for: references)
        if let references, ids.count < references.count { throw ShikeError.message("参考日历已变化，请重新选择。") }
        conflictSnapshot = try await environment.calendars.events(in: DateInterval(start: plan.start.addingTimeInterval(-172800), end: plan.end.addingTimeInterval(172800)), calendarIDs: ids)
    }
    private func overlaps(for draft: EventDraft) -> [(String, String)] {
        guard !draft.isAllDay, let start = draft.start, let end = draft.end, end > start else { return [] }
        let interval = DateInterval(start: start, end: end)
        var result = conflictSnapshot.filter { $0.blocksPlanningTime && Scheduling.overlaps($0.interval(in: TimeZone(identifier: session.referenceTimeZone) ?? .current), interval) && $0.eventID != draft.eventIdentifier }
            .map { ("event:\($0.id):\($0.end.timeIntervalSinceReferenceDate)", "与已有安排「\($0.title)」时间重叠。确认此重叠后仍可加入。") }
        result += session.drafts.filter {
            $0.id != draft.id && !$0.isAllDay && $0.selected && !$0.isSaved && $0.start != nil && $0.end != nil && $0.end! > $0.start!
                && Scheduling.overlaps(DateInterval(start: $0.start!, end: $0.end!), interval)
        }.map { ("draft:\($0.id):\($0.start!.timeIntervalSinceReferenceDate):\($0.end!.timeIntervalSinceReferenceDate)", "与本次安排「\($0.title)」时间重叠。确认此重叠后仍可加入。") }
        return result.sorted { $0.0 < $1.0 }
    }
    private func conflictMessages(_ draft: EventDraft) -> [String] { overlaps(for: draft).map(\.1) }
    private func conflictFingerprint(_ draft: EventDraft) -> String {
        "\(draft.start?.timeIntervalSinceReferenceDate ?? 0)|\(draft.end?.timeIntervalSinceReferenceDate ?? 0)|" + overlaps(for: draft).map(\.0).joined(separator: "|")
    }
}
