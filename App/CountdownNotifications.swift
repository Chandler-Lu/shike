import UserNotifications
import Combine
import ShikeCore

@MainActor protocol CountdownNotificationCenter {
    func allowed() async -> Bool
    func requestAccess() async throws -> Bool
    func pendingIDs() async -> [String]
    func remove(_ ids: [String])
    func add(_ notice: CountdownNotice) async throws
}
@MainActor final class AppleCountdownNotifications: CountdownNotificationCenter {
    let center = UNUserNotificationCenter.current()
    func allowed() async -> Bool { let status = await center.notificationSettings().authorizationStatus; return status == .authorized || status == .provisional }
    func requestAccess() async throws -> Bool { try await center.requestAuthorization(options: [.alert, .sound, .badge]) }
    func pendingIDs() async -> [String] { await center.pendingNotificationRequests().map(\.identifier) }
    func remove(_ ids: [String]) { center.removePendingNotificationRequests(withIdentifiers: ids) }
    func add(_ notice: CountdownNotice) async throws {
        let content = UNMutableNotificationContent(); content.title = notice.title
        if let years = notice.anniversaryYear, let milestone = notice.milestoneDay { content.body = "今天是 \(years) 周年，也是你记下的第 \(milestone) 天。" }
        else if let years = notice.anniversaryYear { content.body = "今天是你记下的日子 \(years) 周年。" }
        else if let milestone = notice.milestoneDay { content.body = "今天是你记下的第 \(milestone) 天。" }
        else { content.body = notice.daysBefore == 0 ? "你记下的日子，就是今天。" : "还有 \(notice.daysBefore) 天，记得留一点期待。" }
        content.sound = .default
        var c = Calendar(identifier: .gregorian); c.timeZone = TimeZone(secondsFromGMT: 0)!
        var parts = c.dateComponents([.year, .month, .day, .hour, .minute, .second], from: notice.fireAt)
        parts.calendar = c; parts.timeZone = c.timeZone
        try await center.add(UNNotificationRequest(identifier: notice.id, content: content, trigger: UNCalendarNotificationTrigger(dateMatching: parts, repeats: false)))
    }
}
@MainActor final class CountdownReminderService: ObservableObject {
    @Published private(set) var status = "提醒默认关闭"
    @Published private(set) var scheduled: [CountdownNotice] = []
    private let center: CountdownNotificationCenter
    private var generation = UUID()
    private var operation: Task<Void, Never>?
    init(center: CountdownNotificationCenter? = nil) { self.center = center ?? AppleCountdownNotifications() }
    func requestAccess() async {
        do { status = try await center.requestAccess() ? "已允许通知" : "通知未获允许，请在系统设置中开启" }
        catch { status = "无法开启通知：\(error.localizedDescription)" }
    }
    // Every suspension checks the generation. A stale replan cannot add requests after
    // a newer edit/delete has removed them.
    func replan(_ entries: [Countdown], now: Date = .now) async {
        let token = UUID(); generation = token
        let previous = operation
        let task = Task { [weak self] in
            await previous?.value
            guard let self, generation == token else { return }
            await performReplan(entries, now: now, token: token)
        }
        operation = task
        await task.value
        if generation == token { operation = nil }
    }
    private func performReplan(_ entries: [Countdown], now: Date, token: UUID) async {
        let ids = await center.pendingIDs().filter { $0.hasPrefix("countdown.") }
        guard generation == token else { return }
        center.remove(ids); scheduled = []
        let allowed = await center.allowed()
        guard generation == token else { return }
        guard allowed else {
            status = entries.contains { $0.reminder.isEnabled } ? "通知未获允许，请在系统设置中开启" : "提醒默认关闭"; return
        }
        for notice in CountdownNotifications.plan(entries, now: now) {
            guard generation == token else { return }
            do {
                try await center.add(notice)
                guard generation == token else { center.remove([notice.id]); return }
                scheduled.append(notice)
            } catch { status = "部分提醒未能安排，请稍后重试：\(error.localizedDescription)"; return }
        }
        status = scheduled.isEmpty ? "当前没有待提醒的倒数日" : "已安排 \(scheduled.count) 条提醒（最多 60 条，打开 App 时更新）"
    }
}

@MainActor final class CountdownCoordinator: ObservableObject {
    let sync: CountdownSync
    let reminders: CountdownReminderService
    let store: CountdownStore
    private let companion = CountdownCompanionPublisher()
    private var reminderTask: Task<Void, Never>?
    init(store: CountdownStore, preferences: Preferences) {
        self.store = store; sync = CountdownSync(store: store, preferences: preferences); reminders = CountdownReminderService()
        CountdownBackgroundSync.current = sync
        store.onChange = { [weak self] in self?.refresh() }
    }
    func refresh() {
        companion.refresh(store: store)
        sync.refresh()
        reminderTask?.cancel()
        reminderTask = Task { [weak self] in
            guard let self else { return }
            await reminders.replan(store.entries)
        }
    }
}
