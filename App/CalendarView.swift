import SwiftUI
import EventKit
import EventKitUI
import ShikeCore

struct CalendarScreen: View {
    @ObservedObject var calendars: CalendarService
    @ObservedObject var preferences: Preferences
    @ObservedObject var countdowns: CountdownStore
    let reminders: CountdownReminderService
    @State private var selectedCountdown: Countdown?
    @State private var listCountdown: Countdown?
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @State private var date = Date.now
    @State private var events: [CalendarEventSnapshot] = []
    @State private var error: String?
    @State private var loading = false
    @State private var filter = false
    @State private var selected: CalendarEventSnapshot?
    @State private var dayList: Date?
    @State private var listSelection: CalendarEventSnapshot?
    private let hourHeight: CGFloat = 58
    private var zone: TimeZone { preferences.calendarPreferences.timeZoneIdentifier.flatMap(TimeZone.init(identifier:)) ?? .current }
    private var calendar: Calendar { var result = Calendar(identifier: .gregorian); result.timeZone = zone; return result }
    private var count: Int { [1, 3, 7].contains(preferences.calendarPreferences.visibleDays) ? preferences.calendarPreferences.visibleDays : 1 }
    private var days: [Date] { Scheduling.days(from: date, count: count, timeZone: zone) }
    private var hasDSTTransition: Bool { days.contains { calendar.date(byAdding: .day, value: 1, to: $0)!.timeIntervalSince($0) != 86400 } }
    private var queryKey: String { "\(days[0])|\(count)|\(zone.identifier)|\(calendars.revision)|\(preferences.calendarPreferences)" }
    var body: some View {
        ZStack {
            PaperBackground()
            VStack(spacing: 12) {
                dateNavigation.padding(.horizontal, 14)
                Picker("显示天数", selection: Binding(get: { count }, set: { value in
                    var settings = preferences.calendarPreferences; settings.visibleDays = value; preferences.setCalendarPreferences(settings)
                })) {
                    Text("当天").tag(1); Text("3 天").tag(3); Text("7 天").tag(7)
                }.pickerStyle(.segmented).padding(.horizontal, 20).accessibilityIdentifier("calendarRange")
                if let error { NoteMessage(text: error, isError: true).padding(.horizontal, 20) }
                if !calendars.authorized {
                    Button("允许访问系统日历") { Task { do { try await calendars.requestAccess() } catch { self.error = error.localizedDescription } } }
                        .font(.subheadline).frame(minHeight: 44).accessibilityIdentifier("calendarGrantAccess")
                }
                if loading { ProgressView().accessibilityLabel("正在读取日历") }
                timeline
            }.padding(.top, 4)
        }.foregroundStyle(Notebook.ink)
            .navigationTitle("日历").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .primaryAction) {
                Button { filter = true } label: { Image(systemName: "line.3.horizontal.decrease") }
                    .accessibilityLabel("日历与时区").accessibilityIdentifier("calendarFilters")
            } }
            .task(id: queryKey) { await load() }
            .onChange(of: scenePhase) { _, phase in if phase == .active { calendars.refresh() } }
            .sheet(isPresented: $filter) {
                NavigationStack {
                    ZStack { PaperBackground(); ScrollView {
                        VStack(alignment: .leading, spacing: 20) {
                            Toggle("显示倒数日", isOn: Binding(get: { preferences.calendarPreferences.showCountdowns ?? true }, set: { value in
                                var settings = preferences.calendarPreferences; settings.showCountdowns = value; preferences.setCalendarPreferences(settings)
                            })).accessibilityIdentifier("showCountdownsInCalendar")
                            CalendarFilterControls(calendars: calendars, preferences: preferences)
                            NavigationLink {
                                TimeZoneSelectionView(selection: Binding(get: { zone.identifier }, set: { id in
                                    var settings = preferences.calendarPreferences; settings.timeZoneIdentifier = id; preferences.setCalendarPreferences(settings)
                                }), date: date)
                            } label: { Label("时区 · \(TimeZoneOption.offsetTitle(zone.secondsFromGMT(for: date)))", systemImage: "globe.asia.australia") }
                            Button("跟随系统时区") {
                                var settings = preferences.calendarPreferences; settings.timeZoneIdentifier = nil; preferences.setCalendarPreferences(settings)
                            }
                        }.padding(22)
                    } }.navigationTitle("显示哪些日历").navigationBarTitleDisplayMode(.inline)
                        .toolbar { ToolbarItem(placement: .confirmationAction) { Button("完成") { filter = false } } }
                }.tint(Notebook.accent)
            }
            .sheet(item: $selectedCountdown) { entry in CountdownDetail(store: countdowns, reminders: reminders, id: entry.id) }
            .sheet(item: $selected) { event in CalendarEventDetail(event: event, calendars: calendars, zone: zone) }
            .sheet(isPresented: Binding(get: { dayList != nil }, set: { if !$0 { dayList = nil } })) {
                NavigationStack {
                    List {
                        ForEach(dayCountdowns(dayList ?? date)) { entry in
                            Button { listCountdown = entry } label: { Label(entry.title, systemImage: "heart") }.buttonStyle(.plain)
                        }
                        ForEach(dayEvents(dayList ?? date)) { event in
                            Button { listSelection = event } label: { eventLabel(event) }.buttonStyle(.plain)
                        }
                    }.navigationTitle((dayList ?? date).formatted(.dateTime.month().day()))
                        .toolbar { ToolbarItem(placement: .confirmationAction) { Button("完成") { dayList = nil } } }
                        .sheet(item: $listCountdown) { entry in CountdownDetail(store: countdowns, reminders: reminders, id: entry.id) }
                        .sheet(item: $listSelection) { event in CalendarEventDetail(event: event, calendars: calendars, zone: zone) }
                }
            }
    }
    @ViewBuilder private var dateNavigation: some View {
        if dynamicTypeSize.isAccessibilitySize {
            VStack(spacing: 4) {
                // Keep the native compact date picker from pushing navigation off screen.
                datePicker.dynamicTypeSize(...DynamicTypeSize.xxxLarge)
                HStack {
                    previousPage
                    Spacer()
                    todayButton
                    Spacer()
                    nextPage
                }
            }
        } else {
            HStack {
                previousPage
                datePicker
                nextPage
                Spacer(minLength: 0)
                todayButton
            }
        }
    }
    private var datePicker: some View {
        DatePicker("选择日期", selection: $date, displayedComponents: .date)
            .labelsHidden().environment(\.timeZone, zone)
    }
    private var previousPage: some View {
        Button { move(-count) } label: { Image(systemName: "chevron.left").frame(width: 44, height: 44) }.accessibilityLabel("上一页")
    }
    private var nextPage: some View {
        Button { move(count) } label: { Image(systemName: "chevron.right").frame(width: 44, height: 44) }.accessibilityLabel("下一页")
    }
    private var todayButton: some View {
        Button("今天") { date = .now }.accessibilityIdentifier("calendarToday")
    }
    private var timeline: some View {
        GeometryReader { geometry in
            let minimum: CGFloat = dynamicTypeSize.isAccessibilitySize ? 150 : 0
            let width = max(geometry.size.width - 42, CGFloat(count) * minimum)
            let hasAllDay = days.contains { dayEvents($0).contains(where: \.allDay) || !dayCountdowns($0).isEmpty }
            ScrollView(.horizontal) {
                VStack(spacing: 0) {
                    HStack(spacing: 0) {
                        Text(hasAllDay ? "全天" : "").font(.caption2).foregroundStyle(Notebook.secondaryInk).frame(width: 42)
                        ForEach(days, id: \.self) { day in
                            VStack(spacing: 6) {
                                Button {
                                    date = day
                                    var settings = preferences.calendarPreferences; settings.visibleDays = 1; preferences.setCalendarPreferences(settings)
                                } label: {
                                    VStack(spacing: 2) {
                                        Text(day.formatted(.dateTime.weekday(.narrow).inTimeZone(zone))).font(.caption2)
                                        Text("\(calendar.component(.day, from: day))").font(Notebook.handwriting(23))
                                    }.frame(maxWidth: .infinity, minHeight: 44)
                                        .foregroundStyle(calendar.isDate(day, inSameDayAs: .now) ? Notebook.accent : Notebook.ink)
                                }.buttonStyle(.plain)
                                let allDay = dayEvents(day).filter(\.allDay)
                                if let event = allDay.first {
                                    Button { selected = event } label: {
                                        Text(event.title).font(.caption2).lineLimit(1).padding(4).frame(maxWidth: .infinity)
                                            .background(color(event).opacity(0.18), in: RoundedRectangle(cornerRadius: 4))
                                    }.buttonStyle(.plain)
                                }
                                let anniversaries = dayCountdowns(day)
                                if let entry = anniversaries.first {
                                    Button { selectedCountdown = entry } label: {
                                        Label(entry.title, systemImage: "heart").font(.caption2).lineLimit(2).padding(5).frame(maxWidth: .infinity)
                                            .background(Notebook.accent.opacity(0.12), in: RoundedRectangle(cornerRadius: 5))
                                    }.buttonStyle(.plain).accessibilityIdentifier("calendarCountdown-\(entry.id)")
                                }
                                let hidden = max(0, allDay.count - 1) + max(0, anniversaries.count - 1)
                                if hidden > 0 { Button("+\(hidden)") { dayList = day }.font(.caption2) }
                            }.frame(width: width / CGFloat(count)).frame(minHeight: hasAllDay ? 100 : 62, alignment: .top)
                        }
                    }.padding(.bottom, 8)
                    Divider().overlay(Notebook.ink.opacity(0.15))
                    ScrollViewReader { scroll in
                        ScrollView(.vertical) {
                            HStack(alignment: .top, spacing: 0) {
                                VStack(spacing: 0) {
                                    ForEach(0..<26, id: \.self) { hour in
                                        Text(hour < 24 && !hasDSTTransition ? String(format: "%02d", hour) : "")
                                            .font(.system(size: 10, design: .rounded)).foregroundStyle(Notebook.secondaryInk)
                                            .frame(width: 42, height: hourHeight, alignment: .top).id(hour)
                                    }
                                }
                                ForEach(days, id: \.self) { day in dayColumn(day, width: width / CGFloat(count)) }
                            }.padding(.top, 6)
                        }.onAppear { scroll.scrollTo(8, anchor: .top) }
                    }
                }.frame(width: width + 42)
            }.accessibilityIdentifier("calendarTimeline")
        }
    }
    private func dayCountdowns(_ day: Date) -> [Countdown] {
        guard preferences.calendarPreferences.showCountdowns ?? true else { return [] }
        // Civil all-day dates stay on their written day, even with a per-item time zone.
        let civil = CivilDate(day, timeZone: zone)
        return countdowns.entries.filter { entry in
            let c = CountdownDates.calendar(entry)
            guard let start = civil.date(in: c.timeZone), let end = c.date(byAdding: .day, value: 1, to: start) else { return false }
            return !CountdownDates.occurrences(entry, in: DateInterval(start: start, end: end), limit: 1).isEmpty
        }.sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
    }
    private func dayColumn(_ day: Date, width: CGFloat) -> some View {
        let end = calendar.date(byAdding: .day, value: 1, to: day)!
        let hours = end.timeIntervalSince(day) / 3600
        let placements = TimelinePlacement.make(events: dayEvents(day).filter { !$0.allDay }, start: day, end: end)
        return ZStack(alignment: .topLeading) {
            ForEach(0..<Int(hours), id: \.self) { hour in
                Rectangle().fill(Notebook.ink.opacity(0.10)).frame(height: 0.5).offset(y: CGFloat(hour) * hourHeight)
                if hasDSTTransition {
                    Text(time(day.addingTimeInterval(Double(hour) * 3600))).font(.system(size: 9)).foregroundStyle(Notebook.secondaryInk)
                        .offset(x: 2, y: CGFloat(hour) * hourHeight + 2)
                }
            }
            Rectangle().fill(Notebook.ink.opacity(0.12)).frame(width: 0.5)
            if hours != 24 {
                Text("夏令时切换").font(.system(size: 9)).foregroundStyle(Notebook.secondaryInk).padding(.top, 2)
            }
            ForEach(placements) { placement in
                let shownLanes = count == 7 ? 1 : min(3, placement.lanes)
                if placement.lane < shownLanes {
                    let laneWidth = (width - 4) / CGFloat(shownLanes)
                    Button { selected = placement.event } label: {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(placement.event.title).font(.system(size: count == 7 ? 10 : 12, weight: .medium)).lineLimit(count == 7 ? 3 : 2)
                            if count < 7 { Text(time(placement.event.start)).font(.system(size: 10)) }
                        }.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading).padding(4)
                            .background(color(placement.event).opacity(0.20), in: RoundedRectangle(cornerRadius: 5))
                            .overlay(alignment: .leading) { RoundedRectangle(cornerRadius: 2).fill(color(placement.event)).frame(width: 2) }
                    }.buttonStyle(.plain)
                        .frame(width: max(12, laneWidth - 2), height: max(24, CGFloat(placement.end.timeIntervalSince(placement.start) / 3600) * hourHeight - 2))
                        .offset(x: 3 + CGFloat(placement.lane) * laneWidth, y: CGFloat(placement.start.timeIntervalSince(day) / 3600) * hourHeight)
                        .accessibilityLabel("\(placement.event.title)，\(time(placement.event.start)) 至 \(time(placement.event.end))")
                        .accessibilityIdentifier("calendarEvent-\(placement.event.eventID)")
                    if placement.id == placements.first(where: { $0.group == placement.group })?.id && placement.lanes > shownLanes {
                        let hidden = placements.filter { $0.group == placement.group && $0.lane >= shownLanes }.count
                        Button("+\(hidden)") { dayList = day }
                            .font(.system(size: 10, weight: .bold)).padding(3).background(Notebook.paper, in: Capsule())
                            .offset(x: max(0, width - 30), y: CGFloat(placement.start.timeIntervalSince(day) / 3600) * hourHeight)
                            .accessibilityLabel("展开这一天的重叠日程")
                    }
                }
            }
            if calendar.isDate(day, inSameDayAs: .now) {
                Rectangle().fill(Notebook.red).frame(height: 1.5)
                    .offset(y: CGFloat(Date.now.timeIntervalSince(day) / 3600) * hourHeight).accessibilityHidden(true)
            }
        }.frame(width: width, height: CGFloat(hours) * hourHeight)
    }
    private func dayEvents(_ day: Date) -> [CalendarEventSnapshot] {
        let start = calendar.startOfDay(for: day), end = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: day))!
        return events.filter { Scheduling.overlaps($0.interval(in: zone), DateInterval(start: start, end: end)) }
    }
    private func color(_ event: CalendarEventSnapshot) -> Color { calendars.readableCalendars.first { $0.id == event.calendarID }?.color ?? Notebook.blue }
    private func time(_ value: Date) -> String { value.formatted(.dateTime.hour().minute().inTimeZone(zone)) }
    private func eventLabel(_ event: CalendarEventSnapshot) -> some View {
        VStack(alignment: .leading, spacing: 6) { Text(event.title); Text(event.allDay ? "全天" : "\(time(event.start)) – \(time(event.end))").font(.caption).foregroundStyle(Notebook.secondaryInk) }
    }
    private func move(_ days: Int) { date = calendar.date(byAdding: .day, value: days, to: date)! }
    private func load() async {
        guard calendars.authorized else { events = []; return }
        loading = true; error = nil
        let key = queryKey
        do {
            let end = calendar.date(byAdding: .day, value: count, to: days[0])!
            let loaded = try await calendars.events(in: DateInterval(start: days[0].addingTimeInterval(-172800), end: end.addingTimeInterval(172800)), calendarIDs: calendars.calendarIDs(for: preferences.calendarPreferences.visibleCalendars))
            try Task.checkCancellation()
            guard queryKey == key else { return }
            events = loaded; loading = false
        } catch is CancellationError { }
        catch { if queryKey == key { events = []; self.error = error.localizedDescription; loading = false } }
    }
}

struct TimelinePlacement: Identifiable {
    var id: String { event.id }
    let event: CalendarEventSnapshot
    let start: Date
    let end: Date
    var lane: Int
    var lanes: Int
    var group: Int
    static func make(events: [CalendarEventSnapshot], start: Date, end: Date) -> [Self] {
        var result: [Self] = [], group: [Self] = [], laneEnds: [Date] = []
        var groupNumber = 0
        func flush() { result += group.map { var item = $0; item.lanes = laneEnds.count; return item }; group = []; laneEnds = []; groupNumber += 1 }
        for event in events.sorted(by: { ($0.start, $0.id) < ($1.start, $1.id) }) {
            let begin = max(start, event.start), finish = min(end, event.end)
            guard finish > begin else { continue }
            if !group.isEmpty && laneEnds.allSatisfy({ $0 <= begin }) { flush() }
            let visualEnd = max(finish, begin.addingTimeInterval(25 * 60))
            let lane = laneEnds.firstIndex { $0 <= begin } ?? laneEnds.count
            if lane == laneEnds.count { laneEnds.append(visualEnd) } else { laneEnds[lane] = visualEnd }
            group.append(Self(event: event, start: begin, end: finish, lane: lane, lanes: 1, group: groupNumber))
        }
        flush(); return result
    }
}

private struct CalendarEventDetail: View {
    let event: CalendarEventSnapshot
    @ObservedObject var calendars: CalendarService
    let zone: TimeZone
    @Environment(\.dismiss) private var dismiss
    @State private var editing: EKEvent?
    @State private var error: String?
    var body: some View {
        NavigationStack {
            ZStack { PaperBackground(); ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    MarginTitle(title: event.title)
                    if event.allDay {
                        let interval = event.interval(in: zone)
                        Text("全天 · " + interval.start.formatted(.dateTime.year().month().day().inTimeZone(zone)))
                        Text("最后一天：" + interval.end.addingTimeInterval(-1).formatted(.dateTime.year().month().day().inTimeZone(zone))).font(.subheadline)
                    } else {
                        Text(event.start.formatted(.dateTime.month().day().hour().minute().inTimeZone(zone)))
                        Text("结束：" + event.end.formatted(.dateTime.month().day().hour().minute().inTimeZone(zone))).font(.subheadline)
                    }
                    if !event.location.isEmpty { Label(event.location, systemImage: "mappin.and.ellipse") }
                    if !event.notes.isEmpty { Text(event.notes).textSelection(.enabled) }
                    if let choice = calendars.readableCalendars.first(where: { $0.id == event.calendarID }) {
                        Label(choice.title + (choice.canWrite ? "" : " · 只读"), systemImage: "calendar").foregroundStyle(choice.color)
                        if choice.canWrite {
                            Button("编辑日程") { do { editing = try calendars.editableEvent(event) } catch { self.error = error.localizedDescription } }
                                .buttonStyle(InkButtonStyle()).accessibilityIdentifier("editCalendarEvent")
                        }
                    }
                    if let error { NoteMessage(text: error, isError: true) }
                }.padding(22)
            } }.navigationTitle("日程详情").navigationBarTitleDisplayMode(.inline)
                .toolbar { ToolbarItem(placement: .confirmationAction) { Button("完成") { dismiss() } } }
                .sheet(isPresented: Binding(get: { editing != nil }, set: { if !$0 { editing = nil } })) {
                    if let editing { SystemEventEditor(event: editing, store: calendars.store) { changed in
                        self.editing = nil
                        if changed { calendars.refresh(); dismiss() }
                    } }
                }
        }.tint(Notebook.accent)
    }
}

private struct SystemEventEditor: UIViewControllerRepresentable {
    let event: EKEvent
    let store: EKEventStore
    let finish: (Bool) -> Void
    func makeCoordinator() -> Coordinator { Coordinator(finish: finish) }
    func makeUIViewController(context: Context) -> EKEventEditViewController {
        let view = EKEventEditViewController(); view.eventStore = store; view.event = event; view.editViewDelegate = context.coordinator; return view
    }
    func updateUIViewController(_ view: EKEventEditViewController, context: Context) {}
    final class Coordinator: NSObject, EKEventEditViewDelegate {
        let finish: (Bool) -> Void
        init(finish: @escaping (Bool) -> Void) { self.finish = finish }
        func eventEditViewController(_ controller: EKEventEditViewController, didCompleteWith action: EKEventEditViewAction) { finish(action != .canceled) }
    }
}
