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
    @State private var queryCache: CalendarWindowCache?
    @State private var dayCache = CalendarDayCache()
    @State private var pageOffset: CGFloat = 0
    @State private var settlingPage = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var filter = false
    @State private var selected: CalendarEventSnapshot?
    @State private var dayList: Date?
    @State private var listSelection: CalendarEventSnapshot?
    @State private var newEvent: EventDraft?
    @State private var drag: CalendarDragSelection?
    @State private var ignoreEventTapsUntil = Date.distantPast
    @StateObject private var summaryController = CalendarSummaryController()
    @State private var showsSummary = false
    @State private var screenVisible = false
    @State private var allDayExpanded = false
    private let hourHeight: CGFloat = 58
    @ScaledMetric(relativeTo: .caption) private var allDayRowHeight: CGFloat = 24
    private var zone: TimeZone { preferences.calendarPreferences.timeZoneIdentifier.flatMap(TimeZone.init(identifier:)) ?? .current }
    private var calendar: Calendar { var result = Calendar(identifier: .gregorian); result.timeZone = zone; return result }
    private var count: Int { [1, 3, 7].contains(preferences.calendarPreferences.visibleDays) ? preferences.calendarPreferences.visibleDays : 1 }
    private var days: [Date] { Scheduling.days(from: date, count: count, timeZone: zone) }
    private var hasDSTTransition: Bool { days.contains { calendar.date(byAdding: .day, value: 1, to: $0)!.timeIntervalSince($0) != 86400 } }
    private var dataKey: String { "\(zone.identifier)|\(calendars.revision)|\(calendars.authorized)|\(calendars.calendarIDs(for: preferences.calendarPreferences.visibleCalendars).sorted())" }
    private var queryKey: String { "\(days[0])|\(count)|\(dataKey)" }
    var body: some View {
        let _ = dayCache.update(events: events, countdowns: preferences.calendarPreferences.showCountdowns ?? true ? countdowns.entries : [], timeZone: zone)
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
                timeline.overlay(alignment: .topTrailing) {
                    if loading { ProgressView().padding(8).accessibilityLabel("正在读取日历").allowsHitTesting(false) }
                }
            }.padding(.top, 4)
        }.foregroundStyle(Notebook.ink)
            .navigationTitle("日历").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItemGroup(placement: .primaryAction) {
                Button { createEvent(at: calendar.date(bySettingHour: 9, minute: 0, second: 0, of: date)!) } label: { Image(systemName: "plus") }
                    .accessibilityLabel("新增日程").accessibilityIdentifier("addCalendarEvent")
                Button("总结") { summarizeVisibleEvents() }.disabled(loading || !calendars.authorized).accessibilityIdentifier("summarizeCalendar")
                Button { filter = true } label: { Image(systemName: "line.3.horizontal.decrease") }
                    .accessibilityLabel("日历与时区").accessibilityIdentifier("calendarFilters")
            } }
            .task(id: queryKey) { await load() }
            .onAppear { screenVisible = true; presentFinishedSummary() }
            .onDisappear { screenVisible = false; drag = nil; pageOffset = 0; settlingPage = false; ignoreEventTapsUntil = .distantPast }
            .onChange(of: scenePhase) { _, phase in if phase == .active { calendars.refresh(); presentFinishedSummary() } }
            .onChange(of: summaryController.needsPresentation) { _, _ in presentFinishedSummary() }
            .onChange(of: summaryPresentationBlocked) { _, blocked in if !blocked { presentFinishedSummary() } }
            .sheet(isPresented: $showsSummary, onDismiss: presentFinishedSummary) {
                CalendarSummaryView(controller: summaryController, preferences: preferences)
                    .workspaceSheet()
            }
            .sheet(item: $newEvent) { draft in
                DraftEditor(draft: draft, calendars: calendars, calendarCreation: true) { value in
                    _ = try calendars.save(value)
                    if let id = value.calendarID, let choice = calendars.calendars.first(where: { $0.id == id }),
                       var visible = preferences.calendarPreferences.visibleCalendars, !visible.contains(choice.reference) {
                        visible.append(choice.reference)
                        var settings = preferences.calendarPreferences; settings.visibleCalendars = visible
                        preferences.setCalendarPreferences(settings)
                    }
                }.workspaceSheet()
            }
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
            .sheet(item: $selected) { event in CalendarEventDetail(event: event, calendars: calendars, zone: zone).workspaceSheet() }
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
            let paging = width + 42 <= geometry.size.width + 1
            let allDayRows = days.map { dayCache.content(for: $0).allDay.count + dayCountdowns($0).count }.max() ?? 0
            let visibleRows = min(allDayExpanded ? 5 : 2, allDayRows)
            let allDayHeight = max(allDayRowHeight, CGFloat(visibleRows) * (allDayRowHeight + 4) - 4)
            ScrollView(.horizontal) {
                VStack(spacing: 0) {
                    pageStrip(width: width + 42, paging: paging) { pageDays, _ in
                        HStack(spacing: 0) {
                            Color.clear.frame(width: 42, height: 50)
                            ForEach(pageDays, id: \.self) { day in
                                Button {
                                    date = day
                                    var settings = preferences.calendarPreferences; settings.visibleDays = 1; preferences.setCalendarPreferences(settings)
                                } label: {
                                    VStack(spacing: 2) {
                                        Text(day.formatted(.dateTime.weekday(.narrow).inTimeZone(zone))).font(.caption2)
                                        Text("\(calendar.component(.day, from: day))").font(Notebook.handwriting(23))
                                    }.frame(width: width / CGFloat(count), height: 50)
                                        .foregroundStyle(calendar.isDate(day, inSameDayAs: .now) ? Notebook.accent : Notebook.ink)
                                }.buttonStyle(.plain)
                            }
                        }
                    }.fixedSize(horizontal: false, vertical: true)
                    pageStrip(width: width + 42, paging: paging) { pageDays, page in
                        HStack(alignment: .top, spacing: 0) {
                            if allDayRows > 2 {
                                Button { allDayExpanded.toggle() } label: {
                                    VStack(spacing: 4) {
                                        Text("全天").font(.caption2)
                                        Image(systemName: allDayExpanded ? "chevron.up" : "chevron.down").font(.system(size: 10, weight: .semibold))
                                    }.frame(width: 42, height: max(44, allDayRowHeight)).contentShape(Rectangle())
                                }.buttonStyle(.plain).foregroundStyle(Notebook.accent)
                                    .accessibilityLabel(allDayExpanded ? "收起全天日程" : "展开全天日程")
                                    .accessibilityValue("最多 \(allDayRows) 项").accessibilityIdentifier("expandAllDayEvents")
                            } else {
                                Text("全天").font(.caption2).foregroundStyle(Notebook.secondaryInk).frame(width: 42, height: allDayRowHeight)
                            }
                            ScrollView(.vertical) {
                                HStack(alignment: .top, spacing: 0) {
                                    let rows = pageDays.map { dayCache.content(for: $0).allDay.count + dayCountdowns($0).count }.max() ?? 0
                                    ForEach(Array(pageDays.enumerated()), id: \.element) { index, day in
                                        allDayColumn(day, index: index, width: width / CGFloat(count),
                                                     height: max(allDayRowHeight, CGFloat(rows) * (allDayRowHeight + 4) - 4), interactive: page == 0)
                                    }
                                }
                            }.frame(height: allDayHeight).accessibilityIdentifier("calendarAllDayEvents")
                        }
                    }.overlay(alignment: .bottom) {
                        if let drag, drag.allDay {
                            Text("\(drag.event?.title ?? "新日程") · \(drag.interval.start.formatted(.dateTime.month().day().inTimeZone(zone)))")
                                .font(.caption).padding(5).background(Notebook.accent.opacity(0.15), in: Capsule()).allowsHitTesting(false)
                        }
                    }.padding(.bottom, 4)
                    Divider().overlay(Notebook.ink.opacity(0.15))
                    ScrollViewReader { scroll in
                        ScrollView(.vertical) {
                            pageStrip(width: width + 42, paging: paging) { pageDays, page in
                                HStack(alignment: .top, spacing: 0) {
                                    VStack(spacing: 0) {
                                        ForEach(0..<26, id: \.self) { hour in
                                            Text(hour < 24 && !hasDSTTransition ? String(format: "%02d", hour) : "")
                                                .font(.system(size: 10, design: .rounded)).foregroundStyle(Notebook.secondaryInk)
                                                .frame(width: 42, height: hourHeight, alignment: .top).id(hour + page * 26)
                                        }
                                    }
                                    HStack(alignment: .top, spacing: 0) {
                                        ForEach(pageDays, id: \.self) { day in dayColumn(day, width: width / CGFloat(count)) }
                                    }.background {
                                        if page == 0 {
                                            CalendarHoldInteraction { state, point in
                                                handleHold(state, at: point,
                                                           geometry: CalendarTimelineGeometry(days: days, columnWidth: width / CGFloat(count), hourHeight: hourHeight, timeZone: zone), allDay: false)
                                            }
                                        }
                                    }
                                }
                            }.padding(.top, 6)
                        }.onAppear { scroll.scrollTo(8, anchor: .top) }
                    }
                }.frame(width: width + 42)
            }.accessibilityIdentifier("calendarTimeline")
                .accessibilityValue(CivilDate(days[0], timeZone: zone).description)
                .background(CalendarPageInteraction(enabled: paging && !settlingPage, onChange: { distance in
                    guard drag == nil, Date.now >= ignoreEventTapsUntil, !showsSummary else { return }
                    pageOffset = max(-geometry.size.width, min(geometry.size.width, distance))
                }, onEnd: { distance, velocity in
                    guard drag == nil, Date.now >= ignoreEventTapsUntil, !showsSummary else { pageOffset = 0; return }
                    finishPaging(distance: distance, velocity: velocity, width: width + 42)
                }))
        }
    }
    private func pageStrip<Content: View>(width: CGFloat, paging: Bool, @ViewBuilder content: @escaping ([Date], Int) -> Content) -> some View {
        HStack(alignment: .top, spacing: 0) {
            ForEach(paging ? [-1, 0, 1] : [0], id: \.self) { page in
                let pageDays = Scheduling.days(from: calendar.date(byAdding: .day, value: page * count, to: date)!, count: count, timeZone: zone)
                content(pageDays, page).frame(width: width)
                    .allowsHitTesting(page == 0).accessibilityHidden(page != 0)
            }
        }.offset(x: paging ? -width + pageOffset : 0).frame(width: width, alignment: .leading).clipped()
    }
    private func finishPaging(distance: CGFloat, velocity: CGFloat, width: CGFloat) {
        let direction = CalendarPaging.direction(distance: distance, velocity: velocity, width: width)
        guard direction != 0 else {
            withAnimation(reduceMotion ? nil : .snappy(duration: 0.2)) { pageOffset = 0 }; return
        }
        settlingPage = true
        withAnimation(reduceMotion ? nil : .easeOut(duration: 0.18), completionCriteria: .logicallyComplete) {
            pageOffset = -CGFloat(direction) * width
        } completion: {
            var transaction = Transaction(); transaction.disablesAnimations = true
            withTransaction(transaction) { move(direction * count); pageOffset = 0; settlingPage = false }
        }
    }
    private func allDayColumn(_ day: Date, index: Int, width: CGFloat, height: CGFloat, interactive: Bool) -> some View {
        VStack(spacing: 4) {
            ForEach(dayEvents(day).filter(\.allDay)) { event in
                Button { if Date.now >= ignoreEventTapsUntil { selected = event } } label: {
                    Text(event.title).font(count == 7 ? .caption2 : .caption).lineLimit(1)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading).padding(.horizontal, 5)
                        .background(color(event).opacity(0.18), in: RoundedRectangle(cornerRadius: 4))
                }.buttonStyle(.plain).frame(height: allDayRowHeight)
                    .opacity(drag?.event?.id == event.id ? 0.3 : 1)
                    .accessibilityLabel("\(event.title)，全天")
                    .accessibilityIdentifier("calendarAllDay-\(event.eventID)-\(index)")
                    .accessibilityHint("长按并横向拖动，可调整日期")
            }
            ForEach(dayCountdowns(day)) { entry in
                Button { if Date.now >= ignoreEventTapsUntil { selectedCountdown = entry } } label: {
                    Label(entry.title, systemImage: "heart").font(.caption2).lineLimit(1)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading).padding(.horizontal, 5)
                        .background(Notebook.accent.opacity(0.12), in: RoundedRectangle(cornerRadius: 4))
                }.buttonStyle(.plain).frame(height: allDayRowHeight).accessibilityIdentifier("calendarCountdown-\(entry.id)")
            }
        }.padding(.horizontal, 2).frame(width: width, height: height, alignment: .top)
            .background {
                if interactive {
                    CalendarHoldInteraction { state, point in
                        handleHold(state, at: CGPoint(x: point.x + CGFloat(index) * width, y: point.y),
                                   geometry: CalendarTimelineGeometry(days: days, columnWidth: width, hourHeight: hourHeight, timeZone: zone), allDay: true)
                    }
                }
            }
    }
    private func dayCountdowns(_ day: Date) -> [Countdown] { dayCache.content(for: day).countdowns }
    private func dayColumn(_ day: Date, width: CGFloat) -> some View {
        let end = calendar.date(byAdding: .day, value: 1, to: day)!
        let hours = end.timeIntervalSince(day) / 3600
        let placements = dayCache.content(for: day).placements
        return ZStack(alignment: .topLeading) {
            Canvas { context, size in
                var lines = Path()
                for hour in 0..<Int(hours) {
                    let y = CGFloat(hour) * hourHeight
                    lines.move(to: CGPoint(x: 0, y: y)); lines.addLine(to: CGPoint(x: size.width, y: y))
                }
                lines.move(to: .zero); lines.addLine(to: CGPoint(x: 0, y: size.height))
                context.stroke(lines, with: .color(Notebook.ink.opacity(0.10)), lineWidth: 0.5)
            }.allowsHitTesting(false).accessibilityHidden(true)
            if hasDSTTransition || hours != 24 {
                ForEach(0..<Int(hours), id: \.self) { hour in
                    Text(time(day.addingTimeInterval(Double(hour) * 3600))).font(.system(size: 9)).foregroundStyle(Notebook.secondaryInk)
                        .offset(x: 2, y: CGFloat(hour) * hourHeight + 2)
                }
            }
            if hours != 24 {
                Text("夏令时切换").font(.system(size: 9)).foregroundStyle(Notebook.secondaryInk).padding(.top, 2)
            }
            ForEach(placements) { placement in
                let shownLanes = count == 7 ? 1 : min(3, placement.lanes)
                if placement.lane < shownLanes {
                    let laneWidth = (width - 4) / CGFloat(shownLanes)
                    Button { if Date.now >= ignoreEventTapsUntil { selected = placement.event } } label: {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(placement.event.title).font(.system(size: count == 7 ? 10 : 12, weight: .medium)).lineLimit(count == 7 ? 3 : 2)
                            if count < 7 { Text(time(placement.event.start)).font(.system(size: 10)) }
                        }.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading).padding(4)
                            .background(color(placement.event).opacity(0.20), in: RoundedRectangle(cornerRadius: 5))
                            .overlay(alignment: .leading) { RoundedRectangle(cornerRadius: 2).fill(color(placement.event)).frame(width: 2) }
                    }.buttonStyle(.plain)
                        .opacity(drag?.event?.id == placement.event.id ? 0.3 : 1)
                        .frame(width: max(12, laneWidth - 2), height: max(24, CGFloat(placement.end.timeIntervalSince(placement.start) / 3600) * hourHeight - 2))
                        .offset(x: 3 + CGFloat(placement.lane) * laneWidth, y: CGFloat(placement.start.timeIntervalSince(day) / 3600) * hourHeight)
                        .accessibilityLabel("\(placement.event.title)，\(time(placement.event.start)) 至 \(time(placement.event.end))")
                        .accessibilityIdentifier("calendarEvent-\(placement.event.eventID)")
                        .accessibilityHint("长按并拖动，可调整日程时间")
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
            if let drag, !drag.allDay {
                let start = max(day, drag.interval.start), finish = min(end, drag.interval.end)
                if finish > start {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(drag.event?.title ?? "新日程").font(.caption.bold()).lineLimit(2)
                        Text("\(time(drag.interval.start)) – \(time(drag.interval.end))").font(.caption2).lineLimit(1)
                    }.padding(5).frame(width: max(12, width - 6), height: max(28, CGFloat(finish.timeIntervalSince(start) / 3600) * hourHeight), alignment: .topLeading)
                        .background(Notebook.accent.opacity(0.25), in: RoundedRectangle(cornerRadius: 5))
                        .overlay(RoundedRectangle(cornerRadius: 5).stroke(Notebook.accent, lineWidth: 2))
                        .offset(x: 3, y: CGFloat(start.timeIntervalSince(day) / 3600) * hourHeight)
                        .allowsHitTesting(false).accessibilityIdentifier("calendarDragPreview")
                }
            }
        }.frame(width: width, height: CGFloat(hours) * hourHeight)
    }
    private func createEvent(at start: Date, end: Date? = nil, allDay: Bool = false) {
        guard calendars.authorized else { error = "请先允许访问系统日历，再新增日程。"; return }
        var draft = EventDraft()
        draft.start = start; draft.end = end ?? start.addingTimeInterval(3600)
        draft.isAllDay = allDay; draft.timeZoneIdentifier = zone.identifier
        let visible = calendars.calendarIDs(for: preferences.calendarPreferences.visibleCalendars)
        let preferred = calendars.preferredCalendarID(preferences.defaultCalendarID)
        draft.calendarID = preferred.flatMap { visible.contains($0) ? $0 : nil } ?? calendars.calendars.first(where: { visible.contains($0.id) })?.id ?? preferred
        newEvent = draft; error = nil
    }
    private func summarizeVisibleEvents() {
        if summaryController.running { showsSummary = true; return }
        let range = DateInterval(start: days[0], end: calendar.date(byAdding: .day, value: count, to: days[0])!)
        let title = days[0].formatted(.dateTime.month().day().inTimeZone(zone)) + (count == 1 ? "的安排" : " – " + days.last!.formatted(.dateTime.month().day().inTimeZone(zone)) + "的安排")
        summaryController.generate(CalendarSummaryRequest(title: title, input: CalendarSummaryInput(events: events.filter { Scheduling.overlaps($0.interval(in: zone), range) }, range: range, timeZone: zone)), preferences: preferences)
        showsSummary = true
    }
    private var summaryPresentationBlocked: Bool {
        filter || selected != nil || newEvent != nil || dayList != nil || selectedCountdown != nil
    }
    private func presentFinishedSummary() {
        guard summaryController.shouldPresentResult, screenVisible, scenePhase == .active,
              !showsSummary, !summaryPresentationBlocked else { return }
        showsSummary = true
    }
    private func timedEvent(at point: CGPoint, geometry: CalendarTimelineGeometry) -> CalendarEventSnapshot? {
        let index = geometry.dayIndex(at: point), day = geometry.days[index]
        let local = CGPoint(x: point.x - CGFloat(index) * geometry.columnWidth, y: point.y)
        for item in dayCache.content(for: day).placements {
            let lanes = count == 7 ? 1 : min(3, item.lanes)
            guard item.lane < lanes else { continue }
            let laneWidth = (geometry.columnWidth - 4) / CGFloat(lanes)
            let rect = CGRect(x: 3 + CGFloat(item.lane) * laneWidth, y: CGFloat(item.start.timeIntervalSince(day) / 3600) * hourHeight,
                              width: max(12, laneWidth - 2), height: max(24, CGFloat(item.end.timeIntervalSince(item.start) / 3600) * hourHeight - 2))
            if rect.contains(local) { return item.event }
        }
        return nil
    }
    private func handleHold(_ state: UIGestureRecognizer.State, at point: CGPoint, geometry: CalendarTimelineGeometry, allDay: Bool) {
        switch state {
        case .began:
            guard point.x >= 0, point.y >= 0 else { return }
            ignoreEventTapsUntil = .distantFuture
            guard calendars.authorized else { error = "请先允许访问系统日历。"; return }
            let day = geometry.days[geometry.dayIndex(at: point)]
            let row = Int(point.y / (allDayRowHeight + 4))
            let allDayEvents = dayEvents(day).filter(\.allDay)
            if allDay && row >= allDayEvents.count && row < allDayEvents.count + dayCountdowns(day).count { return }
            let event = allDay ? (row < allDayEvents.count ? allDayEvents[row] : nil) : timedEvent(at: point, geometry: geometry)
            if let event, !calendars.calendars.contains(where: { $0.id == event.calendarID }) {
                error = "这个日历只支持查看，无法拖动日程。"; return
            }
            let start = event?.start ?? (allDay ? day : geometry.date(at: point))
            let end = event?.end ?? (allDay ? calendar.date(byAdding: .day, value: 1, to: day)! : start.addingTimeInterval(3600))
            let interval = DateInterval(start: start, end: end)
            drag = CalendarDragSelection(origin: point, event: event, allDay: allDay, initial: interval, interval: interval)
            error = nil; PlatformSupport.lightFeedback()
        case .changed, .ended:
            if state == .ended { ignoreEventTapsUntil = .now.addingTimeInterval(0.35) }
            guard var current = drag, current.allDay == allDay else { return }
            if let event = current.event { current.interval = geometry.moving(event, from: current.origin, to: point) }
            else if allDay {
                let day = geometry.days[geometry.dayIndex(at: point)]
                current.interval = DateInterval(start: min(current.initial.start, day), end: calendar.date(byAdding: .day, value: 1, to: max(current.initial.start, day))!)
            } else if abs(point.y - current.origin.y) > 8 || geometry.dayIndex(at: point) != geometry.dayIndex(at: current.origin) {
                let target = geometry.date(at: point)
                current.interval = DateInterval(start: min(current.initial.start, target), end: max(current.initial.start.addingTimeInterval(900), target))
            }
            if current.interval != drag?.interval { drag = current }
            if state == .ended {
                drag = nil
                if let event = current.event {
                    guard current.interval.start != event.start || current.interval.end != event.end else { return }
                    do {
                        try calendars.reschedule(event, to: current.interval)
                        // Keep the drop position visible while the background query catches up.
                        if let index = events.firstIndex(where: { $0.id == event.id }) {
                            events[index].start = current.interval.start; events[index].end = current.interval.end
                        }
                        PlatformSupport.lightFeedback()
                    } catch { self.error = error.localizedDescription }
                } else { createEvent(at: current.interval.start, end: current.interval.end, allDay: allDay) }
            }
        case .cancelled, .failed: drag = nil; ignoreEventTapsUntil = .now.addingTimeInterval(0.35)
        default: break
        }
    }
    private func dayEvents(_ day: Date) -> [CalendarEventSnapshot] { dayCache.content(for: day).events }
    private func color(_ event: CalendarEventSnapshot) -> Color { calendars.readableCalendars.first { $0.id == event.calendarID }?.color ?? Notebook.blue }
    private func time(_ value: Date) -> String { value.formatted(.dateTime.hour().minute().inTimeZone(zone)) }
    private func eventLabel(_ event: CalendarEventSnapshot) -> some View {
        VStack(alignment: .leading, spacing: 6) { Text(event.title); Text(event.allDay ? "全天" : "\(time(event.start)) – \(time(event.end))").font(.caption).foregroundStyle(Notebook.secondaryInk) }
    }
    private func move(_ days: Int) { date = calendar.date(byAdding: .day, value: days, to: date)! }
    private func load() async {
        guard calendars.authorized else { events = []; queryCache = nil; loading = false; return }
        let key = queryKey, scope = dataKey
        let visible = DateInterval(start: days[0], end: calendar.date(byAdding: .day, value: count, to: days[0])!)
        if let queryCache, queryCache.covers(visible, key: scope) { loading = false; return }
        // Keep neighboring pages ready. The extra two days preserve floating all-day dates across zones.
        let margin = max(7, count * 2)
        let range = DateInterval(start: calendar.date(byAdding: .day, value: -margin, to: visible.start)!,
                                 end: calendar.date(byAdding: .day, value: margin, to: visible.end)!)
        loading = true; error = nil
        if queryCache?.key != scope { events = events.filter { calendars.calendarIDs(for: preferences.calendarPreferences.visibleCalendars).contains($0.calendarID) } }
        do {
            let loaded = try await calendars.events(in: DateInterval(start: range.start.addingTimeInterval(-172800), end: range.end.addingTimeInterval(172800)), calendarIDs: calendars.calendarIDs(for: preferences.calendarPreferences.visibleCalendars))
            try Task.checkCancellation()
            guard queryKey == key else { return }
            events = loaded; queryCache = CalendarWindowCache(range: range, key: scope); loading = false
        } catch is CancellationError { }
        catch { if queryKey == key { events = []; queryCache = nil; self.error = error.localizedDescription; loading = false } }
    }

}

/// Query scope includes permissions, calendar filters, time zone and EventKit revision.
struct CalendarWindowCache {
    let range: DateInterval
    let key: String
    func covers(_ interval: DateInterval, key: String) -> Bool {
        self.key == key && range.start <= interval.start && range.end >= interval.end
    }
}

/// Memoize civil dates, recurring countdowns and overlap lanes, independent of drag frames.
final class CalendarDayCache {
    struct Content {
        let events: [CalendarEventSnapshot]
        let allDay: [CalendarEventSnapshot]
        let placements: [TimelinePlacement]
        let countdowns: [Countdown]
    }
    private var events: [CalendarEventSnapshot] = []
    private var countdowns: [Countdown] = []
    private var zone = TimeZone.current
    private var prepared: [Date: Content] = [:]
    private var calendar: Calendar { var value = Calendar(identifier: .gregorian); value.timeZone = zone; return value }
    func update(events: [CalendarEventSnapshot], countdowns: [Countdown], timeZone: TimeZone) {
        guard self.events != events || self.countdowns != countdowns || zone != timeZone else { return }
        self.events = events; self.countdowns = countdowns; zone = timeZone; prepared.removeAll(keepingCapacity: true)
    }
    func content(for day: Date) -> Content {
        let start = calendar.startOfDay(for: day)
        if let cached = prepared[start] { return cached }
        let end = calendar.date(byAdding: .day, value: 1, to: start)!
        let range = DateInterval(start: start, end: end), civil = CivilDate(start, timeZone: zone)
        let visible = events.filter { Scheduling.overlaps($0.interval(in: zone), range) }
        let dates = countdowns.filter { entry in
            let c = CountdownDates.calendar(entry)
            guard let start = civil.date(in: c.timeZone), let end = c.date(byAdding: .day, value: 1, to: start) else { return false }
            return !CountdownDates.occurrences(entry, in: DateInterval(start: start, end: end), limit: 1).isEmpty
        }.sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
        let value = Content(events: visible, allDay: visible.filter(\.allDay),
                            placements: TimelinePlacement.make(events: visible.filter { !$0.allDay }, start: start, end: end), countdowns: dates)
        prepared[start] = value
        return value
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
    @State private var editorChangedEvent = false
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
                            Button("编辑日程") { do { editorChangedEvent = false; editing = try calendars.editableEvent(event) } catch { self.error = error.localizedDescription } }
                                .buttonStyle(InkButtonStyle()).accessibilityIdentifier("editCalendarEvent")
                        }
                    }
                    if let error { NoteMessage(text: error, isError: true) }
                }.padding(22)
            } }.navigationTitle("日程详情").navigationBarTitleDisplayMode(.inline)
                .toolbar { ToolbarItem(placement: .confirmationAction) { Button("完成") { dismiss() } } }
                .sheet(isPresented: Binding(get: { editing != nil }, set: { if !$0 { editing = nil } }), onDismiss: {
                    // Dismiss the detail only after the native editor finishes
                    // closing. Closing both sheets in its delegate callback leaves
                    // EventKit's delete confirmation / presentation stuck on screen.
                    guard editorChangedEvent else { return }
                    editorChangedEvent = false
                    calendars.refresh()
                    dismiss()
                }) {
                    if let editing { SystemEventEditor(event: editing, store: calendars.store) { changed in
                        editorChangedEvent = changed
                        self.editing = nil
                    } }
                }
        }.tint(Notebook.accent)
    }
}

private struct SystemEventEditor: UIViewControllerRepresentable {
    let event: EKEvent
    let store: EKEventStore
    let finish: (Bool) -> Void
    func makeCoordinator() -> Coordinator { Coordinator(event: event, finish: finish) }
    func makeUIViewController(context: Context) -> EKEventEditViewController {
        let view = EKEventEditViewController(); view.eventStore = store; view.event = event; view.editViewDelegate = context.coordinator; return view
    }
    func updateUIViewController(_ view: EKEventEditViewController, context: Context) {}
    static func dismantleUIViewController(_ view: EKEventEditViewController, coordinator: Coordinator) {
        view.editViewDelegate = nil
        coordinator.invalidate()
    }
    final class Coordinator: NSObject, EKEventEditViewDelegate {
        let finish: (Bool) -> Void
        private var completed = false
        private let original: CalendarEventSnapshot
        private var observer: NSObjectProtocol?
        init(event: EKEvent, finish: @escaping (Bool) -> Void) {
            self.finish = finish
            original = CalendarEventSnapshot(eventID: event.eventIdentifier, itemID: event.calendarItemIdentifier,
                calendarID: event.calendar.calendarIdentifier, title: "", start: event.startDate, end: event.endDate)
            super.init()
            observer = NotificationCenter.default.addObserver(forName: .EKEventStoreChanged, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in self?.checkOccurrence() }
            }
        }
        deinit { if let observer { NotificationCenter.default.removeObserver(observer) } }
        func invalidate() { completed = true; stopObserving() }
        func stopObserving() {
            if let observer { NotificationCenter.default.removeObserver(observer) }
            observer = nil
        }
        private func checkOccurrence() {
            guard !completed, EKEventStore.authorizationStatus(for: .event) == .fullAccess else { return }
            // The remote EventKit editor can commit a deletion without delivering
            // didCompleteWith. Verify the exact occurrence using a fresh read store;
            // do not reset or mutate the store currently used by the editor.
            let reader = EKEventStore()
            guard let calendar = reader.calendar(withIdentifier: original.calendarID) else { return }
            let predicate = reader.predicateForEvents(withStart: original.start.addingTimeInterval(-1),
                end: max(original.end, original.start.addingTimeInterval(1)), calendars: [calendar])
            let exists = reader.events(matching: predicate).contains {
                ($0.eventIdentifier == original.eventID || $0.calendarItemIdentifier == original.itemID) && $0.startDate == original.start
            }
            if !exists { complete(changed: true) }
        }
        func eventEditViewController(_ controller: EKEventEditViewController, didCompleteWith action: EKEventEditViewAction) {
            complete(changed: action != .canceled)
        }
        private func complete(changed: Bool) {
            guard !completed else { return }
            completed = true
            stopObserving()
            finish(changed)
        }
    }
}
