import EventKit
import SwiftUI
import ShikeCore

struct CalendarChoice: Identifiable {
    let id: String
    let title: String
    let account: String
    let color: Color
    var canWrite = true
    var reference: CalendarReference { CalendarReference(title: title, account: account) }
}

enum CalendarDeletionScope { case occurrence, futureOccurrences }

@MainActor final class CalendarService: ObservableObject {
    let store = EKEventStore()
    @Published private(set) var calendars: [CalendarChoice] = []
    @Published private(set) var readableCalendars: [CalendarChoice] = []
    @Published private(set) var revision = UUID()
    @Published private(set) var authorized = false
    private var observer: NSObjectProtocol?
    private var demoEvents: [String: EventDraft] = [:]
    private var movedDemoEvents: [String: CalendarEventSnapshot] = [:]
    private var queriedDemoEvents: [String: CalendarEventSnapshot] = [:]
    private var deletedDemoOccurrences: Set<String> = []
    private var deletedDemoSeries: [CalendarEventSnapshot] = []
    private let useDemo: Bool
    private let reader = CalendarQueryWorker()
    private var fixtureEvents: [CalendarEventSnapshot]

    init(useDemo: Bool = AppIdentity.usesDemoCalendar, fixtureEvents: [CalendarEventSnapshot] = []) {
        self.useDemo = useDemo
        self.fixtureEvents = fixtureEvents
        refresh()
        observer = NotificationCenter.default.addObserver(forName: .EKEventStoreChanged, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
    }
    deinit { if let observer { NotificationCenter.default.removeObserver(observer) } }

    func refresh() {
        revision = UUID()
        if useDemo {
            #if DEBUG
            if AppIdentity.isUITesting && ProcessInfo.processInfo.arguments.contains("-calendar-denied-fixture") {
                authorized = false; calendars = []; readableCalendars = []; return
            }
            #endif
            authorized = true
            var account = "测试日历"
            #if DEBUG
            if AppIdentity.isUITesting && ProcessInfo.processInfo.arguments.contains("-store-screenshots") { account = "我的日历" }
            #endif
            calendars = [CalendarChoice(id: "test-calendar", title: "个人日程", account: account, color: .blue),
                         CalendarChoice(id: "test-work", title: "工作", account: account, color: .green)]
            readableCalendars = calendars + [CalendarChoice(id: "test-readonly", title: "订阅日历", account: account, color: .orange, canWrite: false)]
            return
        }
        authorized = EKEventStore.authorizationStatus(for: .event) == .fullAccess
        guard authorized else { calendars = []; readableCalendars = []; return }
        readableCalendars = store.calendars(for: .event).map {
            CalendarChoice(id: $0.calendarIdentifier, title: $0.title, account: $0.source.title, color: Color(cgColor: $0.cgColor), canWrite: $0.allowsContentModifications)
        }.sorted { ($0.account, $0.title) < ($1.account, $1.title) }
        calendars = readableCalendars.filter(\.canWrite)
    }

    func requestAccess() async throws {
        if useDemo { refresh(); return }
        let status = EKEventStore.authorizationStatus(for: .event)
        guard status != .denied && status != .restricted else {
            throw ShikeError.message("日历访问未开启。请到系统设置 → App → 拾刻计划 → 日历，允许完全访问。")
        }
        if status != .fullAccess {
            guard try await store.requestFullAccessToEvents() else {
                throw ShikeError.message("需要日历完全访问权限，才能选择日历并修改已保存的日程。")
            }
            store.reset()
        }
        refresh()
    }

    func preferredCalendarID(_ configured: String) -> String? {
        if !configured.isEmpty { return calendars.contains { $0.id == configured } ? configured : nil }
        if useDemo { return calendars.first?.id }
        return store.defaultCalendarForNewEvents.flatMap { cal in calendars.contains { $0.id == cal.calendarIdentifier } ? cal.calendarIdentifier : nil }
    }

    func save(_ draft: EventDraft, updatingExisting: Bool = false) throws -> EventDraft {
        guard authorized else { throw ShikeError.message("请先允许日历完全访问。") }
        var checked = draft
        checked.saveAttemptInProgress = false
        let issues = checked.saveValidationMessages(writableCalendarIDs: Set(calendars.map(\.id)))
        guard issues.isEmpty else { throw ShikeError.message(issues.joined(separator: "，")) }
        guard let id = draft.calendarID, calendars.contains(where: { $0.id == id }) else {
            throw ShikeError.message("目标日历已失效或不可写，请重新选择日历。")
        }
        if useDemo {
            var result = checked
            result.eventIdentifier = draft.eventIdentifier ?? UUID().uuidString
            result.calendarItemIdentifier = result.eventIdentifier
            result.saveError = nil
            demoEvents[result.eventIdentifier!] = result
            revision = UUID()
            return result
        }
        guard let calendar = store.calendar(withIdentifier: id), calendar.allowsContentModifications else {
            throw ShikeError.message("目标日历不可写，请重新选择日历。")
        }
        let event: EKEvent
        if updatingExisting {
            event = try existingEvent(draft)
            guard !event.hasRecurrenceRules else { throw ShikeError.message("这个日程已在系统日历中改为重复事件，请在系统日历中修改。") }
        } else { event = EKEvent(eventStore: store) }
        event.title = draft.title.trimmingCharacters(in: .whitespacesAndNewlines)
        // Setting a non-nil time zone after isAllDay clears EventKit's all-day
        // flag. All-day events are floating civil dates in the system zone.
        // Clear the old flag before assigning exclusive end dates as well;
        // otherwise an existing all-day event gains an extra day when updated.
        event.isAllDay = false
        event.timeZone = draft.isAllDay ? nil : draft.timeZone
        if draft.isAllDay {
            var source = Calendar(identifier: .gregorian); source.timeZone = draft.timeZone
            var system = Calendar(identifier: .gregorian); system.timeZone = .current
            event.startDate = draft.start.flatMap { system.date(from: source.dateComponents([.year, .month, .day], from: $0)) }
            event.endDate = draft.end.flatMap { system.date(from: source.dateComponents([.year, .month, .day], from: $0)) }
        } else {
            event.startDate = draft.start
            event.endDate = draft.end
        }
        event.isAllDay = draft.isAllDay
        event.notes = draft.notes
        event.location = draft.location
        event.calendar = calendar
        event.alarms = draft.reminderMinutes.map { [EKAlarm(relativeOffset: -Double($0 * 60))] } ?? []
        try store.save(event, span: .thisEvent, commit: true)
        var result = checked
        result.eventIdentifier = event.eventIdentifier
        result.calendarItemIdentifier = event.calendarItemIdentifier
        result.saveError = nil
        revision = UUID()
        return result
    }

    func latest(_ draft: EventDraft) throws -> EventDraft {
        if useDemo { return demoEvents[draft.eventIdentifier ?? ""] ?? draft }
        let event = try existingEvent(draft)
        guard !event.hasRecurrenceRules else { throw ShikeError.message("这个日程已变为重复事件，请在系统日历中修改。") }
        var current = draft
        current.title = event.title ?? ""
        current.start = event.startDate; current.end = event.endDate
        current.isAllDay = event.isAllDay
        if event.isAllDay {
            let snapshot = CalendarEventSnapshot(eventID: event.eventIdentifier, itemID: event.calendarItemIdentifier,
                calendarID: event.calendar.calendarIdentifier, title: current.title, start: event.startDate, end: event.endDate,
                allDay: true, timeZone: event.timeZone?.identifier ?? TimeZone.current.identifier)
            let civilInterval = snapshot.interval(in: draft.timeZone)
            current.start = civilInterval.start; current.end = civilInterval.end
        } else { current.timeZoneIdentifier = event.timeZone?.identifier ?? draft.timeZoneIdentifier }
        current.location = event.location ?? ""; current.notes = event.notes ?? ""
        current.calendarID = event.calendar.calendarIdentifier
        current.eventIdentifier = event.eventIdentifier
        current.calendarItemIdentifier = event.calendarItemIdentifier
        current.reminderMinutes = event.alarms?.first.map { Int(-$0.relativeOffset / 60) }
        current.needsReview = false
        return current
    }

    private func existingEvent(_ draft: EventDraft) throws -> EKEvent {
        guard authorized else { throw ShikeError.message("日历权限已关闭，请重新授权。") }
        let event = draft.eventIdentifier.flatMap(store.event(withIdentifier:)) ??
            draft.calendarItemIdentifier.flatMap { store.calendarItem(withIdentifier: $0) as? EKEvent }
        guard let event else { throw ShikeError.message("系统日历中找不到这个事件，可能已被删除或移动。原记录已保留，不会自动重建。") }
        guard event.calendar.allowsContentModifications else { throw ShikeError.message("这个事件所在日历目前只读，请在系统日历中处理。") }
        return event
    }

    func calendarIDs(for references: [CalendarReference]?) -> Set<String> {
        guard let references else { return Set(readableCalendars.map(\.id)) }
        let choices = Dictionary(uniqueKeysWithValues: readableCalendars.map { ($0.id, $0.reference) })
        return Set(references.compactMap { $0.matchingID(in: choices) })
    }

    func events(in interval: DateInterval, calendarIDs: Set<String>? = nil) async throws -> [CalendarEventSnapshot] {
        guard authorized else { throw ShikeError.message("需要日历完全访问权限才能查看已有安排。") }
        let ids = calendarIDs ?? Set(readableCalendars.map(\.id))
        guard !ids.isEmpty, interval.duration > 0 else { return [] }
        let events: [CalendarEventSnapshot]
        if useDemo {
            var fixtures = fixtureEvents
            #if DEBUG
            if AppIdentity.isUITesting && ProcessInfo.processInfo.arguments.contains("-calendar-fixture") {
                let day = Calendar.current.startOfDay(for: .now)
                fixtures += (0..<7).map { index in
                    let start = Calendar.current.date(byAdding: .day, value: index, to: day)!.addingTimeInterval(3600 * 10)
                    return CalendarEventSnapshot(eventID: "demo-\(index)", itemID: "demo-\(index)", calendarID: index == 2 ? "test-readonly" : "test-work", title: ["产品设计评审", "读书与笔记", "朋友的展览"][index % 3], start: start, end: start.addingTimeInterval(5400))
                }
                if ProcessInfo.processInfo.arguments.contains("-calendar-all-day-fixture") {
                    fixtures += (0..<4).map { index in
                        let start = Calendar.current.date(byAdding: .day, value: index == 0 ? -1 : 0, to: day)!
                        let end = Calendar.current.date(byAdding: .day, value: index == 0 ? 2 : 1, to: day)!
                        return CalendarEventSnapshot(eventID: "all-day-\(index)", itemID: "all-day-\(index)", calendarID: "test-work",
                                                     title: ["跨天出行", "全天会议", "休假", "第四条全天日程"][index], start: start, end: end, allDay: true)
                    }
                }
                if ProcessInfo.processInfo.arguments.contains("-calendar-recurring-fixture") {
                    fixtures += (-1...1).map { offset in
                        let start = Calendar.current.date(byAdding: .day, value: offset, to: day)!.addingTimeInterval(3600 * 12)
                        return CalendarEventSnapshot(eventID: "repeat-\(offset)", itemID: "repeat-series", calendarID: "test-work",
                            title: "每日读书", start: start, end: start.addingTimeInterval(1800), isRecurring: true)
                    }
                }
            }
            #endif
            events = fixtures + demoEvents.values.compactMap { draft in
                guard let start = draft.start, let end = draft.end else { return nil }
                return CalendarEventSnapshot(eventID: draft.eventIdentifier!, itemID: draft.calendarItemIdentifier!, calendarID: draft.calendarID!, title: draft.title, start: start, end: end, allDay: draft.isAllDay, location: draft.location, notes: draft.notes, timeZone: draft.timeZoneIdentifier)
            }
        } else { events = try await reader.events(in: interval, ids: ids) }
        try Task.checkCancellation()
        guard authorized else { throw ShikeError.message("日历访问已关闭。") }
        let current = useDemo ? events.map { movedDemoEvents[$0.eventID] ?? $0 } : events
        if useDemo { for event in current { queriedDemoEvents[event.eventID] = event } }
        return current.filter { !isDemoDeleted($0) && ids.contains($0.calendarID) && Scheduling.overlaps($0.interval, interval) }
            .sorted { ($0.start, $0.id) < ($1.start, $1.id) }
    }

    /// Only change the selected occurrence's dates. Preserve alarms, attendees, notes and recurrence.
    func reschedule(_ snapshot: CalendarEventSnapshot, to interval: DateInterval) throws {
        guard authorized, calendars.contains(where: { $0.id == snapshot.calendarID }) else {
            throw ShikeError.message("这个日历只支持查看，或日历访问权限已关闭。")
        }
        guard interval.duration > 0 else { throw ShikeError.message("结束时间必须晚于开始时间。") }
        if useDemo {
            guard var current = queriedDemoEvents[snapshot.eventID] ?? fixtureEvents.first(where: { $0.eventID == snapshot.eventID }),
                  current.start == snapshot.start, current.end == snapshot.end else {
                throw ShikeError.message("这个事件已被移动或删除，请刷新日历。")
            }
            current.start = interval.start; current.end = interval.end
            movedDemoEvents[snapshot.eventID] = current; queriedDemoEvents[snapshot.eventID] = current
        } else {
            let event = try editableEvent(snapshot)
            guard event.endDate == snapshot.end, event.isAllDay == snapshot.allDay else {
                throw ShikeError.message("这个事件刚刚被修改，请刷新后再拖动。")
            }
            event.startDate = interval.start; event.endDate = interval.end
            try store.save(event, span: .thisEvent, commit: true)
        }
        revision = UUID()
    }

    /// Resolve this occurrence in the editing store; never use an EKEvent from the background store.
    func editableEvent(_ snapshot: CalendarEventSnapshot) throws -> EKEvent {
        let event = try resolvedEvent(snapshot)
        guard event.calendar.allowsContentModifications else { throw ShikeError.message("这个日历只支持查看。") }
        return event
    }

    private func resolvedEvent(_ snapshot: CalendarEventSnapshot) throws -> EKEvent {
        guard authorized else { throw ShikeError.message("日历权限已关闭。") }
        guard let calendar = store.calendar(withIdentifier: snapshot.calendarID) else { throw ShikeError.message("日历已不可用，请刷新。") }
        let predicate = store.predicateForEvents(withStart: snapshot.start.addingTimeInterval(-1), end: max(snapshot.end, snapshot.start.addingTimeInterval(1)), calendars: [calendar])
        guard let event = store.events(matching: predicate).first(where: {
            ($0.eventIdentifier == snapshot.eventID || $0.calendarItemIdentifier == snapshot.itemID) && $0.startDate == snapshot.start
        }) else { throw ShikeError.message("这个事件已被移动或删除，请刷新日历。") }
        return event
    }

    /// Refresh this occurrence before conversion, including readable subscription calendars.
    func currentSnapshot(_ snapshot: CalendarEventSnapshot) throws -> CalendarEventSnapshot {
        guard authorized else { throw ShikeError.message("日历权限已关闭。") }
        if useDemo {
            let saved = demoEvents[snapshot.eventID].flatMap { draft -> CalendarEventSnapshot? in
                guard let start = draft.start, let end = draft.end else { return nil }
                return CalendarEventSnapshot(eventID: snapshot.eventID, itemID: draft.calendarItemIdentifier ?? snapshot.itemID,
                    calendarID: draft.calendarID ?? snapshot.calendarID, title: draft.title, start: start, end: end,
                    allDay: draft.isAllDay, location: draft.location, notes: draft.notes, timeZone: draft.timeZoneIdentifier)
            }
            guard let current = movedDemoEvents[snapshot.eventID] ?? saved ?? queriedDemoEvents[snapshot.eventID] ?? fixtureEvents.first(where: { $0.id == snapshot.id }),
                  current.start == snapshot.start, !isDemoDeleted(current) else {
                throw ShikeError.message("这个事件已被移动或删除，请刷新日历。")
            }
            return current
        }
        let event = try resolvedEvent(snapshot)
        return CalendarEventSnapshot(eventID: event.eventIdentifier ?? event.calendarItemIdentifier,
            itemID: event.calendarItemIdentifier, calendarID: event.calendar.calendarIdentifier,
            title: event.title ?? "未命名日程", start: event.startDate, end: event.endDate, allDay: event.isAllDay,
            location: event.location ?? "", notes: event.notes ?? "", timeZone: event.timeZone?.identifier ?? TimeZone.current.identifier,
            isRecurring: event.hasRecurrenceRules || event.isDetached)
    }

    /// Existing callers delete one occurrence; a future range requires an explicit choice.
    func deleteOccurrence(_ snapshot: CalendarEventSnapshot, scope: CalendarDeletionScope = .occurrence) throws {
        guard authorized, calendars.contains(where: { $0.id == snapshot.calendarID }) else {
            throw ShikeError.message("这个日历只支持查看，或日历访问权限已关闭。")
        }
        let current = try currentSnapshot(snapshot)
        guard current.title == snapshot.title, current.end == snapshot.end, current.allDay == snapshot.allDay,
              current.location == snapshot.location, current.notes == snapshot.notes, current.timeZone == snapshot.timeZone,
              current.isRecurring == snapshot.isRecurring else {
            throw ShikeError.message("这个日程刚刚被修改，请重新打开详情后再删除。")
        }
        guard scope != .futureOccurrences || current.isRecurring else { throw ShikeError.message("这个日程已不再重复，请重新打开详情。") }
        if useDemo {
            if scope == .futureOccurrences { deletedDemoSeries.append(current) }
            else { deletedDemoOccurrences.insert(current.id) }
        } else {
            try store.remove(editableEvent(snapshot), span: scope == .futureOccurrences ? .futureEvents : .thisEvent, commit: true)
        }
        revision = UUID()
    }

    private func isDemoDeleted(_ event: CalendarEventSnapshot) -> Bool {
        deletedDemoOccurrences.contains(event.id) || deletedDemoSeries.contains {
            $0.calendarID == event.calendarID && $0.itemID == event.itemID && event.start >= $0.start
        }
    }
}

private actor CalendarQueryWorker {
    private let store = EKEventStore()
    func events(in interval: DateInterval, ids: Set<String>) throws -> [CalendarEventSnapshot] {
        guard EKEventStore.authorizationStatus(for: .event) == .fullAccess else { throw ShikeError.message("日历访问未开启。") }
        store.reset()
        let calendars = store.calendars(for: .event).filter { ids.contains($0.calendarIdentifier) }
        guard !calendars.isEmpty else { return [] }
        let predicate = store.predicateForEvents(withStart: interval.start, end: interval.end, calendars: calendars)
        let result = store.events(matching: predicate).filter { $0.status != .canceled }.compactMap { event -> CalendarEventSnapshot? in
            guard let start = event.startDate, let end = event.endDate, end > start else { return nil }
            let declined = event.attendees?.contains { $0.isCurrentUser && $0.participantStatus == .declined } == true
            return CalendarEventSnapshot(eventID: event.eventIdentifier ?? event.calendarItemIdentifier, itemID: event.calendarItemIdentifier,
                calendarID: event.calendar.calendarIdentifier, title: event.title ?? "未命名日程", start: start, end: end,
                allDay: event.isAllDay, location: event.location ?? "", notes: event.notes ?? "", timeZone: event.timeZone?.identifier ?? TimeZone.current.identifier,
                blocksTime: event.availability != .free && !declined, isRecurring: event.hasRecurrenceRules || event.isDetached)
        }
        try Task.checkCancellation()
        return result
    }
}
