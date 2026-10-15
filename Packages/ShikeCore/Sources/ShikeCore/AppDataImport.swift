import Foundation

/// Validates the complete backup before any local store is changed.
public struct AppDataImport: Sendable {
    public let backup: AppDataExport
    public init(data: Data) throws {
        guard data.count <= 50_000_000 else { throw ShikeError.message("备份超过 50 MB，请选择较小的文件。") }
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        do { backup = try decoder.decode(AppDataExport.self, from: data) }
        catch { throw ShikeError.message("无法读取拾刻 JSON 备份，文件可能不完整或格式不正确。") }
        guard backup.format == "shike-export", backup.schemaVersion == 1 else { throw ShikeError.message("此备份版本暂不支持，请更新拾刻后重试。") }
        guard backup.countdowns.count <= 10_000, backup.countdownCategories.count <= 500, backup.importSessions.count <= 10_000,
              backup.apiProfiles.count <= 100,
              Set(backup.countdowns.map(\.id)).count == backup.countdowns.count,
              Set(backup.countdownCategories.map(\.id)).count == backup.countdownCategories.count,
              Set(backup.importSessions.map(\.id)).count == backup.importSessions.count,
              Set(backup.apiProfiles.map(\.id)).count == backup.apiProfiles.count,
              Set(backup.countdowns.map(\.id)).isDisjoint(with: Set(backup.countdownCategories.map(\.id))),
              [1, 3, 7].contains(backup.preferences.calendar.visibleDays),
              backup.preferences.calendar.timeZoneIdentifier.map({ TimeZone(identifier: $0) != nil }) ?? true else {
            throw ShikeError.message("备份包含重复编号、无效设置或过多记录，未导入任何内容。")
        }
        for category in backup.countdownCategories { try CountdownRecord(category).validate() }
        for entry in backup.countdowns {
            guard entry.recurrence.missingDatePolicy == "clampToLastDay", entry.recurrence.missingLeapMonthPolicy == "ordinaryMonth" else {
                throw ShikeError.message("备份中的日期重复规则暂不支持。")
            }
            try entry.countdown.validate()
        }
        for profile in backup.apiProfiles {
            guard !profile.id.isEmpty, !profile.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  profile.id.count <= 200, profile.name.count <= 200 else { throw ShikeError.message("备份的接口名称或编号无效。") }
            if !profile.baseURL.isEmpty {
                guard let url = URLComponents(string: profile.baseURL), url.scheme == "https", url.host != nil,
                      url.user == nil, url.password == nil, url.query == nil, url.fragment == nil else {
                    throw ShikeError.message("备份的接口地址无效或包含认证信息。")
                }
            }
        }
        try prompts.validate()
        for session in backup.importSessions {
            guard TimeZone(identifier: session.referenceTimeZone) != nil, session.text.count <= 1_000_000,
                  session.drafts.count <= 100, Set(session.drafts.map(\.id)).count == session.drafts.count,
                  session.drafts.allSatisfy({ TimeZone(identifier: $0.timeZoneIdentifier) != nil }) else {
                throw ShikeError.message("备份中的日程记录无效。")
            }
            if let p = session.planning {
                guard p.turns.count <= 10_000, p.end > p.start else { throw ShikeError.message("备份中的问答记录无效。") }
            }
        }
    }
    public var prompts: PromptSettings {
        var result = PromptSettings()
        result.extraction = backup.prompts.extraction.isCustom ? backup.prompts.extraction.text : nil
        result.planning = backup.prompts.planning.isCustom ? backup.prompts.planning.text : nil
        return result
    }
    public func sessions(calendars: [String: CalendarReference]) -> [ImportSession] {
        backup.importSessions.map { value in
            var session = ImportSession(source: value.source)
            session.id = value.id; session.createdAt = value.createdAt; session.referenceTimeZone = value.referenceTimeZone
            session.referenceDate = value.referenceDate
            session.text = value.text; session.hasParsed = value.hasParsed; session.forcedCategory = value.forcedCategory
            session.drafts = value.drafts.map { source in
                var draft = EventDraft()
                draft.id = source.id; draft.title = source.title; draft.category = source.category
                draft.start = source.start; draft.end = source.end; draft.isAllDay = source.isAllDay
                draft.timeZoneIdentifier = source.timeZoneIdentifier; draft.location = source.location
                draft.notes = source.notes; draft.sourceExcerpt = source.sourceExcerpt; draft.reminderMinutes = source.reminderMinutes
                draft.calendarID = source.calendar?.matchingID(in: calendars)
                draft.suggestedCalendarID = source.suggestedCalendar?.matchingID(in: calendars)
                draft.selected = source.saved ? false : source.selected
                draft.needsReview = source.needsReview || source.saved || source.saveInterrupted
                draft.reviewNotes = source.reviewNotes; draft.restoredFromSavedEvent = source.saved
                if source.saved { draft.reviewNotes.append("备份记录显示此日程已加入过日历；导入不会再次写入。请先核对系统日历。") }
                if source.saveInterrupted { draft.reviewNotes.append("备份中的保存曾中断，请先核对系统日历。") }
                return draft
            }
            if let source = value.planning {
                var planning = PlanningConversation(goal: source.goal, now: source.start)
                planning.start = source.start; planning.end = source.end; planning.awaitingReply = source.awaitingReply
                planning.hasProposal = source.hasProposal; planning.checkedAvailability = false
                planning.proposalNeedsUpdate = true
                planning.turns = source.turns.map { source in
                    var turn = PlanningTurn(role: source.role, text: source.text, options: source.options); turn.id = source.id; return turn
                }
                session.planning = planning
            }
            return session
        }
    }
}

extension AppDataExport.CountdownData {
    public var countdown: Countdown {
        var value = Countdown(id: id, title: title, date: anchorDate)
        value.calendar = calendar; value.recurrence = recurrence.frequency; value.timeZoneIdentifier = timeZoneIdentifier
        value.categoryID = categoryID; value.notes = notes; value.pinned = pinned; value.reminder = reminder
        value.targetTime = targetTime; value.includesStartDay = includesStartDay
        return value
    }
}
