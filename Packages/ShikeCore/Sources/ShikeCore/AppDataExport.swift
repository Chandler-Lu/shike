import Foundation

/// A versioned, explicit allowlist. Never encode Preferences, APIProfile or EventDraft directly.
public struct AppDataExport: Codable, Sendable {
    public let format: String
    public let schemaVersion: Int
    public let exportedAt: Date
    public let app: App
    public let preferences: PreferencesData
    public let apiProfiles: [Profile]
    public let prompts: Prompts
    public let countdowns: [CountdownData]
    public let countdownCategories: [CountdownCategory]
    public let importSessions: [Session]
    public struct App: Codable, Sendable { public var name = "拾刻"; public let version: String; public let build: String }
    public struct PreferencesData: Codable, Sendable {
        public let iCloudEnabled: Bool
        public let categoryRoutingEnabled: Bool
        public let defaultCalendar: CalendarReference?
        public let categoryCalendars: [String: CalendarReference]
        public let activeProfileID: String
        public let calendar: CalendarDisplay
        public init(iCloudEnabled: Bool, categoryRoutingEnabled: Bool, defaultCalendar: CalendarReference?, categoryCalendars: [String: CalendarReference], activeProfileID: String, calendar: CalendarPreferences) {
            self.iCloudEnabled = iCloudEnabled; self.categoryRoutingEnabled = categoryRoutingEnabled
            self.defaultCalendar = defaultCalendar; self.categoryCalendars = categoryCalendars; self.activeProfileID = activeProfileID
            self.calendar = CalendarDisplay(visibleDays: calendar.visibleDays, visibleCalendars: calendar.visibleCalendars, planningCalendars: calendar.planningCalendars, timeZoneIdentifier: calendar.timeZoneIdentifier, showCountdowns: calendar.showCountdowns ?? true, countdownLayout: calendar.countdownLayout ?? .single)
        }
    }
    public struct CalendarDisplay: Codable, Sendable {
        public let visibleDays: Int
        public let visibleCalendars: [CalendarReference]?
        public let planningCalendars: [CalendarReference]?
        public let timeZoneIdentifier: String?
        public let showCountdowns: Bool?
        public let countdownLayout: CountdownLayout?
    }
    public struct Profile: Codable, Sendable {
        public let id: String
        public let name: String
        public let baseURL: String
        public let format: APIFormat
        public let model: String
        init(_ p: APIProfile) {
            id = p.id; name = p.name; format = p.configuration.format; model = p.configuration.model
            // Even unfinished configurations cannot leak credentials embedded in a URL.
            if var url = URLComponents(string: p.configuration.baseURL), url.scheme == "https", url.host != nil {
                url.user = nil; url.password = nil; url.query = nil; url.fragment = nil; baseURL = url.string ?? ""
            } else { baseURL = "" }
        }
    }
    public struct Prompts: Codable, Sendable {
        public struct Value: Codable, Sendable { public let isCustom: Bool; public let text: String }
        public let extraction: Value
        public let planning: Value
        init(_ p: PromptSettings) {
            extraction = Value(isCustom: p.extraction != nil, text: p.text(for: .extraction))
            planning = Value(isCustom: p.planning != nil, text: p.text(for: .planning))
        }
    }
    public struct CountdownData: Codable, Sendable {
        public struct Recurrence: Codable, Sendable { public let frequency: CountdownRepeat; public var missingDatePolicy = "clampToLastDay"; public var missingLeapMonthPolicy = "ordinaryMonth" }
        public let id: UUID
        public let title: String
        public let anchorDate: CivilDate
        public let calendar: CountdownCalendar
        public let lunarDate: LunarDate?
        public let recurrence: Recurrence
        public let timeZoneIdentifier: String?
        public let categoryID: UUID?
        public let notes: String
        public let pinned: Bool
        public let reminder: CountdownReminder
        public let targetTime: CountdownTime?
        public let includesStartDay: Bool?
        init(_ v: Countdown) {
            id = v.id; title = v.title; anchorDate = v.anchorDate; calendar = v.calendar
            lunarDate = v.calendar == .chinese ? CountdownDates.lunarDate(v) : nil
            recurrence = Recurrence(frequency: v.recurrence); timeZoneIdentifier = v.timeZoneIdentifier
            categoryID = v.categoryID; notes = v.notes; pinned = v.pinned; reminder = v.reminder
            targetTime = v.targetTime; includesStartDay = v.includesStartDay ?? false
        }
    }
    public struct Draft: Codable, Sendable {
        public let id: UUID
        public let title: String
        public let category: EventCategory?
        public let start: Date?
        public let end: Date?
        public let isAllDay: Bool
        public let timeZoneIdentifier: String
        public let location: String
        public let notes: String
        public let sourceExcerpt: String
        public let reminderMinutes: Int?
        public let calendar: CalendarReference?
        public let suggestedCalendar: CalendarReference?
        public let selected: Bool
        public let needsReview: Bool
        public let reviewNotes: [String]
        public let saved: Bool
        public let saveInterrupted: Bool
        init(_ v: EventDraft, calendars: [String: CalendarReference]) {
            id = v.id; title = v.title; category = v.category; start = v.start; end = v.end; isAllDay = v.isAllDay
            timeZoneIdentifier = v.timeZoneIdentifier; location = v.location; notes = v.notes; sourceExcerpt = v.sourceExcerpt
            reminderMinutes = v.reminderMinutes; calendar = v.calendarID.flatMap { calendars[$0] }
            suggestedCalendar = v.suggestedCalendarID.flatMap { calendars[$0] }; selected = v.selected
            needsReview = v.needsReview; reviewNotes = v.reviewNotes; saved = v.isSaved || v.restoredFromSavedEvent == true; saveInterrupted = v.saveAttemptInProgress
        }
    }
    public struct Conversation: Codable, Sendable {
        public struct Turn: Codable, Sendable { public let id: UUID; public let role: String; public let text: String; public let options: [String] }
        public let goal: String
        public let turns: [Turn]
        public let start: Date
        public let end: Date
        public let awaitingReply: Bool
        public let hasProposal: Bool
        public let checkedAvailability: Bool
        public let proposalNeedsUpdate: Bool
        init(_ v: PlanningConversation) {
            goal = v.goal; turns = v.turns.map { Turn(id: $0.id, role: $0.role, text: $0.text, options: $0.options) }
            start = v.start; end = v.end; awaitingReply = v.awaitingReply; hasProposal = v.hasProposal
            checkedAvailability = v.checkedAvailability; proposalNeedsUpdate = v.proposalNeedsUpdate ?? false
        }
    }
    public struct Session: Codable, Sendable {
        public let id: UUID
        public let createdAt: Date
        public let referenceDate: Date?
        public let referenceTimeZone: String
        public let source: String
        public let text: String
        public let hasParsed: Bool
        public let forcedCategory: EventCategory?
        public let drafts: [Draft]
        public let planning: Conversation?
        init(_ v: ImportSession, calendars: [String: CalendarReference]) {
            id = v.id; createdAt = v.createdAt; referenceTimeZone = v.referenceTimeZone; source = v.source; text = v.text
            referenceDate = v.referenceDate
            hasParsed = v.hasParsed; forcedCategory = v.forcedCategory
            drafts = v.drafts.map { Draft($0, calendars: calendars) }; planning = v.planning.map(Conversation.init)
        }
    }
    public init(exportedAt: Date = .now, version: String, build: String, preferences: PreferencesData, profiles: [APIProfile], prompts: PromptSettings, countdowns: [Countdown], categories: [CountdownCategory], sessions: [ImportSession], calendarReferences: [String: CalendarReference]) {
        format = "shike-export"; schemaVersion = 1
        self.exportedAt = exportedAt; app = App(version: version, build: build); self.preferences = preferences
        apiProfiles = profiles.map(Profile.init); self.prompts = Prompts(prompts)
        let categoryIDs = Set(categories.map(\.id))
        self.countdowns = countdowns.sorted { $0.id.uuidString < $1.id.uuidString }.map { entry in
            var entry = entry; if let id = entry.categoryID, !categoryIDs.contains(id) { entry.categoryID = nil }
            return CountdownData(entry)
        }
        countdownCategories = categories.sorted { $0.id.uuidString < $1.id.uuidString }
        importSessions = sessions.sorted { $0.id.uuidString < $1.id.uuidString }.map { Session($0, calendars: calendarReferences) }
    }
    public func data() throws -> Data {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        return try encoder.encode(self)
    }
}
