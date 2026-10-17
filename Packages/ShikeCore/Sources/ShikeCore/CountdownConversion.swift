import Foundation

/// Local conversion only: no model, calendar routing or availability checks.
public enum CountdownConversion {
    public static func sourceIdentifier(for draft: EventDraft) -> String { "draft:\(draft.id.uuidString)" }

    public static func from(_ draft: EventDraft) throws -> Countdown {
        guard let start = draft.start else { throw ShikeError.message("请补充开始日期。") }
        return try make(title: draft.title, start: start, end: draft.end, allDay: draft.isAllDay,
                        zone: draft.timeZone, location: draft.location, notes: draft.notes,
                        source: sourceIdentifier(for: draft))
    }

    public static func from(_ event: CalendarEventSnapshot, fallbackZone: TimeZone = .current) throws -> Countdown {
        // JSON string components avoid ambiguous delimiters; the start identifies this occurrence.
        let key = try JSONEncoder().encode([event.calendarID, event.itemID, String(event.start.timeIntervalSinceReferenceDate)])
        return try make(title: event.title, start: event.start, end: event.end, allDay: event.allDay,
                        zone: TimeZone(identifier: event.timeZone) ?? fallbackZone,
                        location: event.location, notes: event.notes,
                        source: "event:" + key.base64EncodedString())
    }

    private static func make(title: String, start: Date, end: Date?, allDay: Bool, zone: TimeZone,
                             location: String, notes: String, source: String) throws -> Countdown {
        var result = Countdown(title: title.trimmingCharacters(in: .whitespacesAndNewlines), date: CivilDate(start, timeZone: zone))
        result.timeZoneIdentifier = zone.identifier
        result.sourceIdentifier = source
        let format = DateFormatter()
        format.locale = Locale(identifier: "zh_CN"); format.calendar = Calendar(identifier: .gregorian)
        format.timeZone = zone; format.dateFormat = allDay ? "yyyy-MM-dd" : "yyyy-MM-dd HH:mm:ss"
        var time = format.string(from: start)
        if let end, end > start {
            // All-day end dates are exclusive; inclusive provider ends are kept as-is.
            var calendar = Calendar(identifier: .gregorian); calendar.timeZone = zone
            let last = allDay && calendar.startOfDay(for: end) == end ? end.addingTimeInterval(-1) : end
            let finish = format.string(from: last)
            if finish != time { time += " — " + finish }
        }
        time += allDay ? " · 全天" : " · \(zone.identifier)"
        var parts = [notes.trimmingCharacters(in: .whitespacesAndNewlines)]
        if !location.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { parts.append("地点：" + location) }
        parts.append("原日程：" + time)
        result.notes = parts.filter { !$0.isEmpty }.joined(separator: "\n\n")
        try result.validate()
        return result
    }
}
