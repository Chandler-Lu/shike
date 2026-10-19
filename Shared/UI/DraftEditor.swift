import SwiftUI
import ShikeCore

struct DraftReviewStep {
    let number: Int
    let total: Int
    let saveCount: Int
    let isLast: Bool
    let skip: (EventDraft) throws -> Void
    let cancel: () -> Void
}

struct DraftEditor: View {
    @Environment(\.dismiss) private var dismiss
    @State var draft: EventDraft
    @ObservedObject var calendars: CalendarService
    var reviewStep: DraftReviewStep? = nil
    var calendarCreation = false
    let onSave: (EventDraft) throws -> Void
    @State private var errorMessage: String?
    @State private var confirmInterrupted = false
    @FocusState private var textFocused: Bool

    private var localCalendar: Calendar {
        var cal = Calendar(identifier: .gregorian); cal.timeZone = draft.timeZone; return cal
    }
    private var displayedEnd: Date {
        let end = draft.end ?? draft.start ?? .now
        return draft.isAllDay ? localCalendar.date(byAdding: .day, value: -1, to: end) ?? end : end
    }

    @ViewBuilder var body: some View {
        if reviewStep != nil {
            editorContent
        } else {
            NavigationStack {
                editorContent
                    .navigationTitle(calendarCreation ? "新增日程" : draft.isSaved ? "修改日程" : "日程草稿")
            }.tint(Notebook.accent)
        }
    }

    private var editorContent: some View {
            ZStack {
                PaperBackground()
                Form {
                    if reviewStep != nil {
                        Section {
                            Text(draft.title.isEmpty ? "未命名日程" : draft.title).font(Notebook.handwriting(23))
                            ForEach(draft.saveValidationMessages(writableCalendarIDs: Set(calendars.calendars.map(\.id))), id: \.self) {
                                Text($0).font(.subheadline).foregroundStyle(Notebook.red)
                            }
                            ForEach(Array(draft.reviewNotes.enumerated()), id: \.offset) { _, note in Text(note).font(.subheadline) }
                            if !draft.sourceExcerpt.isEmpty {
                                Text("原文：\(draft.sourceExcerpt)").font(.subheadline).foregroundStyle(Notebook.secondaryInk)
                            }
                        } header: { Text("看看这条安排").font(Notebook.handwriting(17)) }
                        .listRowBackground(Notebook.yellow.opacity(0.22))
                    }
                    Section {
                        TextField("日程名称", text: $draft.title, axis: .vertical)
                            .font(Notebook.handwriting(23)).accessibilityIdentifier("eventTitle").focused($textFocused)
                        Toggle("全天", isOn: Binding(get: { draft.isAllDay }, set: { draft.setAllDay($0) }))
                        dateField("开始", value: $draft.start, fallback: .now)
                        if draft.isAllDay {
                            DatePicker("最后一天", selection: Binding(get: { displayedEnd }, set: {
                                draft.end = localCalendar.date(byAdding: .day, value: 1, to: localCalendar.startOfDay(for: $0))
                            }), displayedComponents: .date)
                            .environment(\.timeZone, draft.timeZone)
                        } else { dateField("结束", value: $draft.end, fallback: (draft.start ?? .now).addingTimeInterval(3600)) }
                        NavigationLink {
                            TimeZoneSelectionView(selection: Binding(get: { draft.timeZoneIdentifier }, set: { draft.setTimeZone($0) }), date: draft.start ?? .now)
                        } label: {
                            VStack(alignment: .leading, spacing: 5) {
                                Text("时区")
                                Text("\(draft.timeZoneIdentifier == TimeZone.current.identifier ? "系统时区 · " : "")\(TimeZoneOption.offsetTitle(draft.timeZone.secondsFromGMT(for: draft.start ?? .now)))")
                                    .font(.caption).foregroundStyle(Notebook.secondaryInk)
                            }
                        }.accessibilityIdentifier("eventTimeZone").accessibilityValue(draft.timeZoneIdentifier)
                    } header: { Text("日期与时间").font(Notebook.handwriting(17)) }
                    .listRowBackground(Notebook.paper)

                    if reviewStep == nil && (!draft.reviewNotes.isEmpty || draft.needsReview) {
                        Section {
                            ForEach(draft.reviewNotes, id: \.self) { Text($0).font(.subheadline) }
                            Button {
                                draft.needsReview.toggle()
                            } label: {
                                Label(draft.needsReview ? "确认日期与时间" : "已核对日期与时间", systemImage: draft.needsReview ? "square" : "checkmark.square.fill")
                                    .frame(minHeight: 44)
                            }.buttonStyle(.plain).foregroundStyle(Notebook.accent)
                                .accessibilityIdentifier("confirmTime").accessibilityValue(draft.needsReview ? "未确认" : "已确认")
                        } header: { Text("荧光笔标记 · 请核对").font(Notebook.handwriting(17)) }
                        .listRowBackground(Notebook.yellow.opacity(0.22))
                    }

                    Section {
                        Picker("日程类别", selection: Binding(get: { draft.category ?? .other }, set: { draft.category = $0 })) {
                            ForEach(EventCategory.allCases) { Text($0.title).tag($0) }
                        }
                        TextField("地点（可选）", text: $draft.location).accessibilityIdentifier("eventLocation").focused($textFocused)
                        TextField("备注（可选）", text: $draft.notes, axis: .vertical).lineLimit(3...8).focused($textFocused)
                        Picker("提醒", selection: $draft.reminderMinutes) {
                            Text("无提醒").tag(Int?.none)
                            ForEach([0, 5, 15, 30, 60], id: \.self) { minute in
                                Text(minute == 0 ? "开始时" : "提前 \(minute) 分钟").tag(Optional(minute))
                            }
                            if let minutes = draft.reminderMinutes, ![0, 5, 15, 30, 60].contains(minutes) {
                                Text("已有提醒：提前 \(minutes) 分钟").tag(Optional(minutes))
                            }
                        }
                        if calendars.authorized {
                            Picker("加入日历", selection: Binding(get: { draft.calendarID ?? "" }, set: { draft.calendarID = $0.isEmpty ? nil : $0 })) {
                                Text("请选择").tag("")
                                if let id = draft.calendarID, !id.isEmpty, !calendars.calendars.contains(where: { $0.id == id }) {
                                    Text("原日历不可用，请重新选择").tag(id)
                                }
                                ForEach(calendars.calendars) { calendar in Text("\(calendar.title)（\(calendar.account)）").tag(calendar.id) }
                            }.accessibilityIdentifier("draftCalendar")
                        } else {
                            Text("可先保存草稿，再授权选择日历。 ").font(.subheadline).foregroundStyle(Notebook.secondaryInk)
                        }
                    } header: { Text("安排细节").font(Notebook.handwriting(17)) }
                    .listRowBackground(Notebook.paper)

                    if reviewStep == nil && !draft.sourceExcerpt.isEmpty {
                        Section { Text(draft.sourceExcerpt).font(.subheadline).textSelection(.enabled) }
                        header: { Text("原文依据").font(Notebook.handwriting(17)) }
                        .listRowBackground(Notebook.paper)
                    }
                    if draft.saveAttemptInProgress {
                        Section {
                            Text("上次写入被中断，日程可能已经保存。请先在系统日历检查，再决定是否允许重试。")
                            Button("我已检查，日历中没有此日程") { confirmInterrupted = true }.foregroundStyle(Notebook.red)
                        }.listRowBackground(Notebook.yellow.opacity(0.18))
                    }
                    if reviewStep == nil, let errorMessage { Section { NoteMessage(text: errorMessage, isError: true) }.listRowBackground(Color.clear) }
                }.scrollContentBackground(.hidden).scrollDismissesKeyboard(.interactively)
            }
            .navigationBarTitleDisplayMode(.inline)
            .safeAreaInset(edge: .bottom) {
                if let step = reviewStep {
                    VStack(spacing: 8) {
                        if let errorMessage {
                            Text(errorMessage.components(separatedBy: "\n").first ?? errorMessage)
                                .font(.footnote).foregroundStyle(Notebook.red).accessibilityIdentifier("reviewError")
                        }
                        Button {
                            textFocused = false
                            do { try onSave(draft) } catch { errorMessage = error.localizedDescription }
                        } label: {
                            Text(step.isLast ? "确认并加入 \(step.saveCount) 个日程" : "确认并继续")
                                .multilineTextAlignment(.center).fixedSize(horizontal: false, vertical: true)
                                .padding(.horizontal, 12).padding(.vertical, 10)
                        }.buttonStyle(InkButtonStyle()).accessibilityIdentifier("confirmReview")
                        Button("暂不加入此条") {
                            textFocused = false
                            do { try step.skip(draft) } catch { errorMessage = error.localizedDescription }
                        }.frame(minHeight: 44).accessibilityIdentifier("skipReview")
                    }.padding(.horizontal, 20).padding(.top, 10).background(Notebook.paper)
                }
            }
            .toolbar {
                if reviewStep == nil {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("取消") { dismiss() }.accessibilityIdentifier("cancelEditing")
                    }
                    ToolbarItem(placement: .confirmationAction) {
                        Button(calendarCreation ? "加入日历" : draft.isSaved ? "保存修改" : "完成") {
                            do { try onSave(draft); dismiss() } catch { errorMessage = error.localizedDescription }
                        }.fontWeight(.semibold).accessibilityIdentifier("finishEditing")
                    }
                }
            }
            .confirmationDialog("确认系统日历中没有这个事件？", isPresented: $confirmInterrupted, titleVisibility: .visible) {
                Button("允许重新保存") { draft.saveAttemptInProgress = false; draft.saveError = nil }
                Button("取消", role: .cancel) {}
            } message: { Text("如果事件已经存在，重新保存会创建重复日程。") }
    }


    @ViewBuilder private func dateField(_ label: String, value: Binding<Date?>, fallback: Date) -> some View {
        if let date = value.wrappedValue {
            VStack(alignment: .leading, spacing: 8) {
                Text(label).font(.subheadline)
                DatePicker(label, selection: Binding(get: { value.wrappedValue ?? date }, set: { value.wrappedValue = $0 }),
                           displayedComponents: draft.isAllDay ? [.date] : [.date, .hourAndMinute])
                    .labelsHidden().environment(\.timeZone, draft.timeZone)
            }.padding(.vertical, 4)
        } else {
            Button {
                value.wrappedValue = draft.isAllDay ? localCalendar.startOfDay(for: fallback) : fallback
            } label: {
                HStack { Text(label); Spacer(); Label("请补充", systemImage: "pencil").foregroundStyle(Notebook.red) }
            }.accessibilityIdentifier(label == "开始" ? "fillStartDate" : "fillEndDate")
        }
    }
}

struct TimeZoneSelectionView: View {
    @Environment(\.dismiss) private var dismiss
    @Binding var selection: String
    let date: Date
    @State private var query = ""
    @State private var options: [TimeZoneOption] = []
    private var filtered: [TimeZoneOption] {
        let words = query.split(whereSeparator: \.isWhitespace).map(String.init)
        return options.filter { option in words.allSatisfy { option.searchText.localizedStandardContains($0) } }
    }
    var body: some View {
        List {
            Section {
                Button {
                    selection = TimeZone.current.identifier; dismiss()
                } label: {
                    VStack(alignment: .leading, spacing: 5) {
                        Label("使用系统时区", systemImage: "iphone")
                        Text("\(TimeZoneOption.offsetTitle(TimeZone.current.secondsFromGMT(for: date))) · \(TimeZoneOption.representativeName(for: .current))").font(.caption).foregroundStyle(Notebook.secondaryInk)
                    }
                }.accessibilityIdentifier("useSystemTimeZone")
            } footer: {
                Text("默认使用系统时区，每个 GMT 偏移显示一个代表地区。偏移按日程日期计算，夏令时遵循该地区规则；切换时区保留实际时刻，全天日程保留日期。")
            }
            Section("按 GMT 偏移选择") {
                ForEach(filtered) { option in
                    Button {
                        selection = option.id; dismiss()
                    } label: {
                        HStack {
                            VStack(alignment: .leading, spacing: 5) {
                                Text(option.offset).foregroundStyle(Notebook.ink)
                                Text(option.title).font(.caption).foregroundStyle(Notebook.secondaryInk)
                            }
                            Spacer()
                            if TimeZone(identifier: selection)?.secondsFromGMT(for: date) == TimeZone(identifier: option.id)?.secondsFromGMT(for: date) {
                                Image(systemName: "checkmark")
                            }
                        }.contentShape(Rectangle())
                    }.accessibilityIdentifier("timeZone-\(option.id)")
                }
                if filtered.isEmpty && !options.isEmpty { Text("没有匹配的时区，试试 GMT+8 或上海。") }
            }.listRowBackground(Notebook.paper)
        }.searchable(text: $query, prompt: "搜索 GMT+8、GMT-5 或代表地区")
            .scrollContentBackground(.hidden).background(PaperBackground())
            .navigationTitle("选择时区").navigationBarTitleDisplayMode(.inline)
            .onAppear {
                guard options.isEmpty else { return }
                let typical = ["Etc/GMT+12", "Pacific/Pago_Pago", "Pacific/Honolulu", "Pacific/Marquesas", "America/Anchorage", "America/Los_Angeles", "America/Phoenix", "America/Denver", "America/Chicago", "America/New_York", "America/Bogota", "America/Halifax", "America/St_Johns", "America/Sao_Paulo", "Atlantic/South_Georgia", "Atlantic/Azores", "Etc/UTC", "Europe/London", "Europe/Paris", "Africa/Johannesburg", "Europe/Moscow", "Asia/Tehran", "Asia/Dubai", "Asia/Kabul", "Asia/Karachi", "Asia/Kolkata", "Asia/Kathmandu", "Asia/Dhaka", "Asia/Yangon", "Asia/Bangkok", "Asia/Shanghai", "Australia/Eucla", "Asia/Tokyo", "Australia/Darwin", "Australia/Adelaide", "Australia/Brisbane", "Australia/Sydney", "Australia/Lord_Howe", "Pacific/Noumea", "Pacific/Auckland", "Pacific/Chatham", "Pacific/Tongatapu", "Pacific/Kiritimati"]
                var grouped: [Int: TimeZoneOption] = [:]
                for id in ["Asia/Shanghai", selection, TimeZone.current.identifier] + typical + TimeZone.knownTimeZoneIdentifiers.sorted() {
                    guard let zone = TimeZone(identifier: id) else { continue }
                    let city = TimeZoneOption.representativeName(for: zone)
                    let name = zone.localizedName(for: .generic, locale: .current) ?? id
                    let seconds = zone.secondsFromGMT(for: date)
                    let sign = seconds >= 0 ? "+" : "-"
                    let hours = abs(seconds) / 3600; let minutes = abs(seconds) % 3600 / 60
                    let offset = TimeZoneOption.offsetTitle(seconds)
                    let entry = TimeZoneOption(id: id, title: city, offset: offset,
                                               searchText: "\(id) \(city) \(name) \(offset) GMT\(sign)\(hours) UTC\(sign)\(hours) \(String(format: "%@%02d:%02d", sign, hours, minutes))")
                    if grouped[seconds] == nil { grouped[seconds] = entry }
                }
                options = grouped.keys.sorted().compactMap { grouped[$0] }
            }
    }
}

struct TimeZoneOption: Identifiable {
    let id: String
    let title: String
    let offset: String
    let searchText: String
    private static let names: [String: String] = [
        "Etc/GMT+12": "贝克岛", "Pacific/Pago_Pago": "帕果帕果", "Pacific/Honolulu": "檀香山",
        "Pacific/Marquesas": "马克萨斯群岛", "America/Anchorage": "安克雷奇", "America/Los_Angeles": "洛杉矶",
        "America/Phoenix": "菲尼克斯", "America/Denver": "丹佛", "America/Chicago": "芝加哥",
        "America/New_York": "纽约", "America/Bogota": "波哥大", "America/Halifax": "哈利法克斯",
        "America/St_Johns": "圣约翰斯", "America/Sao_Paulo": "圣保罗", "Atlantic/South_Georgia": "南乔治亚岛",
        "Atlantic/Azores": "亚速尔群岛", "Etc/UTC": "协调世界时", "Etc/GMT": "格林尼治", "GMT": "格林尼治",
        "Europe/London": "伦敦", "Europe/Paris": "巴黎", "Africa/Johannesburg": "约翰内斯堡",
        "Europe/Moscow": "莫斯科", "Asia/Tehran": "德黑兰", "Asia/Dubai": "迪拜", "Asia/Kabul": "喀布尔",
        "Asia/Karachi": "卡拉奇", "Asia/Kolkata": "加尔各答", "Asia/Kathmandu": "加德满都", "Asia/Dhaka": "达卡",
        "Asia/Yangon": "仰光", "Asia/Bangkok": "曼谷", "Asia/Shanghai": "上海", "Asia/Chongqing": "上海",
        "Australia/Eucla": "尤克拉", "Asia/Tokyo": "东京", "Australia/Darwin": "达尔文", "Australia/Adelaide": "阿德莱德",
        "Australia/Brisbane": "布里斯班", "Australia/Sydney": "悉尼", "Australia/Lord_Howe": "豪勋爵岛",
        "Pacific/Noumea": "努美阿", "Pacific/Auckland": "奥克兰", "Pacific/Chatham": "查塔姆群岛",
        "Pacific/Tongatapu": "努库阿洛法", "Pacific/Kiritimati": "基里蒂马蒂岛"
    ]
    static func representativeName(for zone: TimeZone) -> String {
        if let name = names[zone.identifier] { return name }
        if let name = zone.localizedName(for: .generic, locale: Locale(identifier: "zh_CN")),
           !name.contains("未知"), !name.localizedCaseInsensitiveContains("unknown") { return name }
        return "固定时区"
    }
    static func offsetTitle(_ seconds: Int) -> String {
        if seconds == 0 { return "GMT+0" }
        let hours = abs(seconds) / 3600; let minutes = abs(seconds) % 3600 / 60
        return "GMT\(seconds >= 0 ? "+" : "-")\(hours)" + (minutes == 0 ? "" : String(format: ":%02d", minutes))
    }
}

enum EventFormatting {
    static func schedule(_ draft: EventDraft) -> String {
        guard let start = draft.start else { return "日期待补充" }
        let f = DateFormatter(); f.locale = Locale(identifier: "zh_CN"); f.timeZone = draft.timeZone
        if draft.isAllDay {
            f.dateFormat = "M月d日"
            var calendar = Calendar(identifier: .gregorian); calendar.timeZone = draft.timeZone
            let last = draft.end.flatMap { calendar.date(byAdding: .day, value: -1, to: $0) } ?? start
            return calendar.isDate(start, inSameDayAs: last) ? "\(f.string(from: start)) · 全天" : "\(f.string(from: start)) — \(f.string(from: last)) · 全天"
        }
        f.dateFormat = "M月d日 EEE HH:mm"
        var result = f.string(from: start)
        if let end = draft.end {
            var calendar = Calendar(identifier: .gregorian); calendar.timeZone = draft.timeZone
            f.dateFormat = calendar.isDate(start, inSameDayAs: end) ? "HH:mm" : "M月d日 HH:mm"
            result += " — \(f.string(from: end))"
        }
        if draft.timeZoneIdentifier != TimeZone.current.identifier { result += "（\(draft.timeZone.abbreviation(for: start) ?? draft.timeZoneIdentifier)）" }
        return result
    }
}
