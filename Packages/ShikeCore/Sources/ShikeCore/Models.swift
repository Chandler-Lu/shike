import Foundation

public enum APIFormat: String, Codable, CaseIterable, Identifiable, Sendable {
    case openAI, claude, gemini
    public var id: String { rawValue }
    public var title: String {
        switch self { case .openAI: return "OpenAI"; case .claude: return "Claude"; case .gemini: return "Gemini" }
    }
}

public struct APIConfiguration: Codable, Equatable, Sendable {
    public var baseURL: String
    public var model: String
    public var format: APIFormat

    public init(baseURL: String = "", model: String = "", format: APIFormat = .openAI) {
        self.baseURL = baseURL
        self.model = model
        self.format = format
    }
    enum CodingKeys: String, CodingKey { case baseURL, model, format }
    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        baseURL = try values.decode(String.self, forKey: .baseURL)
        model = try values.decode(String.self, forKey: .model)
        format = try values.decodeIfPresent(APIFormat.self, forKey: .format) ?? .openAI
    }

    private func baseComponents() throws -> URLComponents {
        let input = baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard var parts = URLComponents(string: input), parts.scheme == "https",
              let host = parts.host, !host.isEmpty, parts.user == nil,
              parts.password == nil, parts.query == nil, parts.fragment == nil else {
            throw ShikeError.message("请填写有效的 HTTPS 接口地址，不要在地址中包含密钥或查询参数。")
        }
        var path = parts.path
        while path.hasSuffix("/") { path.removeLast() }
        let rootWasEmpty = path.isEmpty
        switch format {
        case .openAI:
            if path.hasSuffix("/chat/completions") { path.removeLast("/chat/completions".count) }
        case .claude:
            if path.hasSuffix("/messages") { path.removeLast("/messages".count) }
        case .gemini:
            if let range = path.range(of: "/models/") { path = String(path[..<range.lowerBound]) }
            else if path.hasSuffix("/models") { path.removeLast("/models".count) }
        }
        if rootWasEmpty { path = format == .gemini ? "/v1beta" : "/v1" }
        parts.path = path
        return parts
    }
    public func endpoint() throws -> URL {
        var parts = try baseComponents()
        switch format {
        case .openAI: parts.path += "/chat/completions"
        case .claude: parts.path += "/messages"
        case .gemini:
            let model = model.trimmingCharacters(in: .whitespacesAndNewlines)
            let id = model.hasPrefix("models/") ? String(model.dropFirst(7)) : model
            guard !id.isEmpty, id.range(of: #"^[A-Za-z0-9._-]+$"#, options: .regularExpression) != nil else {
                throw ShikeError.message("请填写有效的 Gemini 模型 ID，可带 models/ 前缀。")
            }
            parts.path += "/models/\(id):generateContent"
        }
        guard let url = parts.url else { throw ShikeError.message("接口地址无效。") }
        return url
    }

    public func modelsEndpoint() throws -> URL {
        var parts = try baseComponents(); parts.path += "/models"
        guard let url = parts.url else { throw ShikeError.message("接口地址无效。") }
        return url
    }
}

public struct APIProfile: Codable, Equatable, Identifiable, Sendable {
    public var id: String
    public var name: String
    public var configuration: APIConfiguration
    public var credentialID: String?
    public var usesLegacyCredential: Bool?
    public init(id: String = UUID().uuidString, name: String, configuration: APIConfiguration,
                credentialID: String? = nil, usesLegacyCredential: Bool = false) {
        self.id = id; self.name = name; self.configuration = configuration
        self.credentialID = credentialID; self.usesLegacyCredential = usesLegacyCredential
    }
}

public struct APIModel: Codable, Identifiable, Equatable, Sendable {
    public let id: String
    public let ownedBy: String?
    public init(id: String, ownedBy: String? = nil) { self.id = id; self.ownedBy = ownedBy }
    enum CodingKeys: String, CodingKey { case id; case ownedBy = "owned_by" }
}

public enum ShikeError: LocalizedError, Equatable {
    case message(String)
    public var errorDescription: String? {
        switch self { case .message(let message): return message }
    }
}

public enum EventCategory: String, CaseIterable, Codable, Identifiable, Sendable {
    case work, personal, study, travel, health, other
    public var id: String { rawValue }
    public var title: String {
        switch self {
        case .work: return "工作"
        case .personal: return "生活"
        case .study: return "学习"
        case .travel: return "出行"
        case .health: return "健康"
        case .other: return "其他"
        }
    }
}

public enum CalendarRouting {
    public static func preferredID(category: EventCategory?, enabled: Bool, mapping: [String: String],
                                   defaultID: String?, writableIDs: Set<String>, suggestedID: String? = nil) -> String? {
        if enabled {
            if let category, let id = mapping[category.rawValue] {
                return writableIDs.contains(id) ? id : defaultID.flatMap { writableIDs.contains($0) ? $0 : nil }
            }
            if let suggestedID, writableIDs.contains(suggestedID) { return suggestedID }
        }
        return defaultID.flatMap { writableIDs.contains($0) ? $0 : nil }
    }
}

public struct CalendarCandidate: Codable, Equatable, Sendable {
    public let id: String
    public let name: String
    public init(id: String, name: String) { self.id = id; self.name = name }
}

public struct CalendarReference: Codable, Equatable, Sendable {
    public let title: String
    public let account: String
    public init(title: String, account: String) { self.title = title; self.account = account }
    public func matchingID(in calendars: [String: CalendarReference]) -> String? {
        let matches = calendars.filter { $0.value == self }.map(\.key)
        return matches.count == 1 ? matches.first : nil
    }
}

// Credentials live in synchronizable Keychain items, never in the settings payload.
public struct CloudSettingsSnapshot: Codable, Equatable, Sendable {
    public var version = 2
    public var revision = UUID()
    public var updatedAt = Date()
    public var configuration: APIConfiguration
    public var credentialID: String?
    public var defaultCalendar: CalendarReference?
    public var categoryRoutingEnabled: Bool
    public var categoryCalendars: [String: CalendarReference]
    public var profiles: [APIProfile]?
    public var activeProfileID: String?
    public var calendarPreferences: CalendarPreferences?
    public var promptSettings: PromptSettings?
    public init(configuration: APIConfiguration, credentialID: String?, defaultCalendar: CalendarReference?,
                categoryRoutingEnabled: Bool, categoryCalendars: [String: CalendarReference],
                profiles: [APIProfile]? = nil, activeProfileID: String? = nil) {
        self.configuration = configuration; self.credentialID = credentialID
        self.defaultCalendar = defaultCalendar; self.categoryRoutingEnabled = categoryRoutingEnabled
        self.categoryCalendars = categoryCalendars
        self.profiles = profiles; self.activeProfileID = activeProfileID
    }
}

public struct EventDraft: Codable, Identifiable, Equatable, Sendable {
    public var id = UUID()
    public var title = ""
    // Optional preserves decoding of local drafts created before category routing.
    public var category: EventCategory?
    public var start: Date?
    public var end: Date?
    public var isAllDay = false
    public var timeZoneIdentifier = TimeZone.current.identifier
    public var location = ""
    public var notes = ""
    public var sourceExcerpt = ""
    public var reminderMinutes: Int?
    public var calendarID: String?
    public var suggestedCalendarID: String?
    public var selected = true
    public var reviewNotes: [String] = []
    public var needsReview = false
    public var eventIdentifier: String?
    public var calendarItemIdentifier: String?
    public var saveError: String?
    public var saveAttemptInProgress = false
    /// A portable backup has no usable EventKit identifiers. Never treat this as a live calendar event.
    public var restoredFromSavedEvent: Bool?

    public init() {}

    public var timeZone: TimeZone { TimeZone(identifier: timeZoneIdentifier) ?? .current }
    public var isSaved: Bool { eventIdentifier != nil }
    public var validationMessages: [String] {
        var messages: [String] = []
        if title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { messages.append("请填写日程名称") }
        if start == nil { messages.append("请补充开始日期与时间") }
        if end == nil { messages.append("请补充结束日期与时间") }
        if let start, let end, end <= start { messages.append("结束时间必须晚于开始时间") }
        if needsReview { messages.append("请核对时间建议") }
        if saveAttemptInProgress { messages.append("上次保存被中断，请先核对系统日历") }
        return messages
    }

    public func saveValidationMessages(writableCalendarIDs: Set<String>, confirmingSuggestions: Bool = false) -> [String] {
        var checked = self
        if confirmingSuggestions { checked.needsReview = false }
        var messages = checked.validationMessages
        if calendarID == nil || calendarID == "" { messages.append("请选择目标日历") }
        else if !writableCalendarIDs.contains(calendarID!) { messages.append("目标日历已失效或不可写，请重新选择日历") }
        return messages
    }

    public mutating func setAllDay(_ value: Bool) {
        isAllDay = value
        guard let start else { return }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        if value {
            self.start = calendar.startOfDay(for: start)
            let lastDay = calendar.startOfDay(for: end.map { $0.addingTimeInterval(-1) } ?? start)
            end = calendar.date(byAdding: .day, value: 1, to: max(self.start!, lastDay))
        } else {
            self.start = calendar.date(bySettingHour: 9, minute: 0, second: 0, of: start)
            end = self.start?.addingTimeInterval(3600)
        }
    }

    public mutating func setTimeZone(_ identifier: String) {
        guard let newZone = TimeZone(identifier: identifier) else { return }
        if isAllDay {
            var oldCalendar = Calendar(identifier: .gregorian); oldCalendar.timeZone = timeZone
            var newCalendar = Calendar(identifier: .gregorian); newCalendar.timeZone = newZone
            start = start.flatMap { newCalendar.date(from: oldCalendar.dateComponents([.year, .month, .day], from: $0)) }
            end = end.flatMap { newCalendar.date(from: oldCalendar.dateComponents([.year, .month, .day], from: $0)) }
        }
        timeZoneIdentifier = identifier
    }
}

public struct ImportSession: Codable, Identifiable, Equatable, Sendable {
    public var id = UUID()
    public var createdAt = Date()
    /// Optional for older records; refreshing interpretation must not change creation order.
    public var referenceDate: Date?
    public var effectiveReferenceDate: Date { referenceDate ?? createdAt }
    public var referenceTimeZone = TimeZone.current.identifier
    public var source = "文字"
    public var text = ""
    public var drafts: [EventDraft] = []
    public var pendingImages: [String] = []
    public var hasParsed = false
    public var forcedCategory: EventCategory?
    public var planning: PlanningConversation?
    public init(source: String = "文字") { self.source = source }
    public var savedCount: Int { drafts.filter(\.isSaved).count }
    public var displayTitle: String {
        if drafts.first?.title.isEmpty == false { return drafts[0].title }
        if text.isEmpty, planning != nil { return "未填写的安排" }
        return String(text.prefix(32))
    }
}

public struct ExtractionResponse: Decodable, Sendable {
    public var events: [ExtractedEvent]
}

public struct ExtractedEvent: Decodable, Sendable {
    public var title: String
    public var category: String?
    public var start: String?
    public var end: String?
    public var allDay: Bool?
    public var timeZone: String?
    public var location: String?
    public var notes: String?
    public var sourceExcerpt: String?
    public var reminderMinutes: Int?
    public var needsReview: Bool?
    public var reviewNotes: [String]?
    public var calendarID: String?
}

public enum ExtractionDecoder {
    public static func decode(_ content: String, timeZone: TimeZone) throws -> [EventDraft] {
        let data = try StructuredModelOutput.eventData(content)
        guard let response = try? JSONDecoder().decode(ExtractionResponse.self, from: data) else {
            throw StructuredModelOutput.invalidFields
        }
        guard response.events.count <= 100 else {
            throw ShikeError.message("单次日程过多，请将原文分成几段再解析。")
        }
        return response.events.map { item in
            var draft = EventDraft()
            draft.title = item.title.trimmingCharacters(in: .whitespacesAndNewlines)
            draft.category = item.category.flatMap(EventCategory.init(rawValue:)) ?? .other
            draft.suggestedCalendarID = item.calendarID
            let suppliedZone = item.timeZone.flatMap(TimeZone.init(identifier:))
            let zone = suppliedZone ?? timeZone
            draft.timeZoneIdentifier = zone.identifier
            draft.isAllDay = item.allDay ?? false
            draft.location = item.location ?? ""
            draft.notes = item.notes ?? ""
            draft.sourceExcerpt = item.sourceExcerpt ?? ""
            draft.reviewNotes = item.reviewNotes ?? []
            draft.needsReview = item.needsReview ?? false
            if let name = item.timeZone, !name.isEmpty, suppliedZone == nil {
                draft.reviewNotes.append("原文时区无法识别，暂按设备时区处理")
                draft.needsReview = true
            }
            draft.start = parseDate(item.start, allDay: draft.isAllDay, timeZone: zone)
            draft.end = parseDate(item.end, allDay: draft.isAllDay, timeZone: zone)
            if let start = draft.start, draft.end == nil, item.end == nil || item.end?.isEmpty == true {
                if draft.isAllDay {
                    var calendar = Calendar(identifier: .gregorian); calendar.timeZone = zone
                    draft.end = calendar.date(byAdding: .day, value: 1, to: start)
                } else {
                    draft.end = start.addingTimeInterval(3600)
                    draft.reviewNotes.append("未提供结束时间，建议持续 1 小时")
                    draft.needsReview = true
                }
            }
            if let minutes = item.reminderMinutes, [0, 5, 15, 30, 60].contains(minutes) {
                draft.reminderMinutes = minutes
            } else if item.reminderMinutes != nil {
                draft.reviewNotes.append("原文提醒时间不在可选范围内，请手动选择")
                draft.needsReview = true
            }
            if !draft.reviewNotes.isEmpty { draft.needsReview = true }
            return draft
        }
    }

    public static func parseDate(_ input: String?, allDay: Bool, timeZone: TimeZone) -> Date? {
        guard let input, !input.isEmpty else { return nil }
        if allDay {
            let formatter = DateFormatter()
            formatter.calendar = Calendar(identifier: .gregorian)
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.timeZone = timeZone
            formatter.dateFormat = "yyyy-MM-dd"
            formatter.isLenient = false
            guard input.count == 10, let date = formatter.date(from: input),
                  formatter.string(from: date) == input else { return nil }
            return date
        }
        // Timed events must include an explicit UTC offset to avoid device-time-zone drift.
        guard input.range(of: #"(Z|[+-]\d{2}:\d{2})$"#, options: .regularExpression) != nil else { return nil }
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = iso.date(from: input) { return date }
        iso.formatOptions = [.withInternetDateTime]
        return iso.date(from: input)
    }
}
