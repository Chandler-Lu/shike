import SwiftUI
import ShikeCore

struct PlanningView: View {
    @ObservedObject var controller: ImportController
    @ObservedObject var calendars: CalendarService
    @ObservedObject var preferences: Preferences
    @Environment(\.dismiss) private var dismiss
    @State private var answer = ""
    @FocusState private var answerFocused: Bool
    private var plan: PlanningConversation? { controller.session.planning }
    private var zone: TimeZone { TimeZone(identifier: controller.session.referenceTimeZone) ?? .current }
    private var calendar: Calendar { var value = Calendar(identifier: .gregorian); value.timeZone = zone; return value }
    var body: some View {
        GeometryReader { geometry in
        let wide = geometry.size.width >= 880
        let columns = wide ? AnyLayout(HStackLayout(alignment: .top, spacing: 28)) : AnyLayout(VStackLayout(alignment: .leading, spacing: 20))
        NavigationStack {
            ZStack {
                PaperBackground()
                ScrollViewReader { scroll in
                    ScrollView {
                        columns {
                            VStack(alignment: .leading, spacing: 20) {
                            MarginTitle(title: "给想做的事，留点时间", subtitle: plan?.goal)
                            DisclosureGroup("安排范围与参考日历") {
                                VStack(alignment: .leading, spacing: 14) {
                                    DatePicker("从哪一天", selection: Binding(get: { plan?.start ?? .now }, set: setStart), displayedComponents: .date)
                                    DatePicker("安排到", selection: Binding(get: { calendar.date(byAdding: .day, value: -1, to: plan?.end ?? .now)! }, set: setEnd), displayedComponents: .date)
                                    Text("单次最多 30 天；长期目标可以分段安排。日历页隐藏的事件仍会参与避让，除非在这里取消勾选。")
                                        .font(.caption).foregroundStyle(Notebook.secondaryInk)
                                    NavigationLink {
                                        TimeZoneSelectionView(selection: Binding(get: { controller.session.referenceTimeZone }, set: setTimeZone), date: plan?.start ?? .now)
                                    } label: { Label("时区 · \(TimeZoneOption.offsetTitle(zone.secondsFromGMT(for: plan?.start ?? .now)))", systemImage: "globe.asia.australia") }
                                    if calendars.authorized {
                                        CalendarFilterControls(calendars: calendars, preferences: preferences, forPlanning: true)
                                    }
                                }.padding(.top, 12).environment(\.timeZone, zone)
                            }.font(.subheadline).disabled(controller.isBusy || controller.session.savedCount > 0)

                            if !calendars.authorized {
                                PaperCard {
                                    VStack(alignment: .leading, spacing: 10) {
                                        Text("允许日历访问，就能避开已有安排。").font(.subheadline)
                                        Button("允许日历访问") { Task { await controller.requestCalendarAccess() } }
                                            .buttonStyle(InkButtonStyle(prominent: false)).accessibilityIdentifier("planningGrantCalendar")
                                        Text("也可以先回答问题，保存前再检查时间。仅发送可用时段，不发送已有事件的标题、地点和备注。")
                                            .font(.caption).foregroundStyle(Notebook.secondaryInk)
                                    }
                                }
                            }

                            if let plan, !plan.turns.isEmpty {
                                if plan.turns.count > 1 {
                                    DisclosureGroup("前面的问答") {
                                        ForEach(plan.turns.dropLast()) { turn in
                                            VStack(alignment: .leading, spacing: 5) {
                                                Text(turn.role == "user" ? "我的回答" : "拾刻计划").font(.caption).foregroundStyle(Notebook.secondaryInk)
                                                Text(turn.text).font(.subheadline).textSelection(.enabled)
                                            }.frame(maxWidth: .infinity, alignment: .leading).padding(.vertical, 8)
                                        }
                                    }.font(.subheadline)
                                }
                                if let last = plan.turns.last {
                                    PaperCard(tint: Notebook.green.opacity(0.15)) {
                                        VStack(alignment: .leading, spacing: 14) {
                                            Text(last.text).font(last.role == "assistant" ? Notebook.handwriting(23) : .body).textSelection(.enabled)
                                            if last.role == "assistant", controller.session.savedCount == 0 {
                                                ForEach(Array(last.options.enumerated()), id: \.offset) { _, option in
                                                    Button(option) { send(option) }.buttonStyle(InkButtonStyle(prominent: false))
                                                        .accessibilityIdentifier("planningOption-\(option)")
                                                }
                                            }
                                        }
                                    }.disabled(controller.isBusy)
                                }
                            }
                            if let error = controller.errorMessage { NoteMessage(text: error, isError: true) }
                            if let info = controller.information { NoteMessage(text: info) }
                            if let busy = controller.busyMessage {
                                HStack {
                                    ProgressView(); Text(busy).font(.subheadline); Spacer()
                                    if !busy.contains("加入日历") { Button("取消") { controller.cancel() } }
                                }
                            } else if plan?.turns.isEmpty == true || plan?.awaitingReply == true {
                                Button(plan?.turns.isEmpty == true && plan?.awaitingReply == false ? "开始安排" : "继续安排") {
                                    controller.advancePlanning()
                                }.buttonStyle(InkButtonStyle()).accessibilityIdentifier("startPlanning")
                            }

                            if controller.session.savedCount == 0, plan?.turns.isEmpty == false {
                                HStack(alignment: .bottom, spacing: 10) {
                                    TextField(plan?.hasProposal == true ? "例如：改到晚上八点" : "也可以写下自己的回答", text: $answer, axis: .vertical)
                                        .lineLimit(1...5).padding(12).background(Notebook.ink.opacity(0.05), in: RoundedRectangle(cornerRadius: 12))
                                        .focused($answerFocused).accessibilityIdentifier("planningAnswer")
                                    Button { send(answer) } label: {
                                        Image(systemName: "arrow.up.circle.fill").font(.system(size: 34)).frame(width: 44, height: 44)
                                    }.disabled(controller.isBusy || answer.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                                        .accessibilityLabel("发送回答").accessibilityIdentifier("sendPlanningAnswer")
                                }.id("answer").disabled(controller.isBusy)
                            }
                            if plan?.proposalNeedsUpdate == true {
                                NoteMessage(text: "下方保留上一版方案，继续回答后会更新。")
                                Button("使用上一版方案") { controller.session.planning?.proposalNeedsUpdate = false; controller.errorMessage = nil }
                                    .font(.subheadline).disabled(controller.isBusy)
                            }
                            }.frame(maxWidth: .infinity, alignment: .topLeading)
                            ImportFlowView(controller: controller, calendars: calendars, isPlanningContent: true)
                                .frame(maxWidth: .infinity, alignment: .topLeading)
                        }.padding(22).frame(maxWidth: wide ? 1200 : 680).frame(maxWidth: .infinity)
                    }.scrollDismissesKeyboard(.interactively)
                        .onChange(of: controller.session.planning?.turns.count) { _, _ in
                            if controller.session.planning?.hasProposal != true { withAnimation { scroll.scrollTo("answer", anchor: .bottom) } }
                        }
                }
            }.foregroundStyle(Notebook.ink)
                .navigationTitle("帮我安排").navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) { Button("收起") { controller.persistReportingError(); dismiss() }.accessibilityIdentifier("closePlanning") }
                    ToolbarItemGroup(placement: .keyboard) { Spacer(); Button("收起键盘") { answerFocused = false } }
                }
                .onDisappear { controller.persistReportingError() }
        }.tint(Notebook.accent)
        }
    }
    private func setTimeZone(_ identifier: String) {
        guard let newZone = TimeZone(identifier: identifier) else { return }
        if var plan {
            var target = Calendar(identifier: .gregorian); target.timeZone = newZone
            plan.start = target.date(from: calendar.dateComponents([.year, .month, .day], from: plan.start)) ?? plan.start
            plan.end = target.date(from: calendar.dateComponents([.year, .month, .day], from: plan.end)) ?? plan.end
            if plan.hasProposal { plan.proposalNeedsUpdate = true }
            controller.session.planning = plan
        }
        controller.session.referenceTimeZone = identifier
    }
    private func send(_ text: String) { answerFocused = false; controller.advancePlanning(answer: text); answer = "" }
    private func setStart(_ date: Date) {
        guard var plan else { return }
        let days = min(30, max(1, calendar.dateComponents([.day], from: plan.start, to: plan.end).day ?? 7))
        plan.start = calendar.startOfDay(for: date)
        plan.end = calendar.date(byAdding: .day, value: days, to: plan.start)!
        if plan.hasProposal { plan.proposalNeedsUpdate = true }
        controller.session.planning = plan
    }
    private func setEnd(_ date: Date) {
        guard var plan else { return }
        plan.end = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: date))!
        if plan.hasProposal { plan.proposalNeedsUpdate = true }
        controller.session.planning = plan
    }
}

struct CalendarFilterControls: View {
    @ObservedObject var calendars: CalendarService
    @ObservedObject var preferences: Preferences
    var forPlanning = false
    private var references: [CalendarReference]? {
        forPlanning ? preferences.calendarPreferences.planningCalendars : preferences.calendarPreferences.visibleCalendars
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Button("选择全部日历") { update(nil) }.padding(.vertical, 6)
            ForEach(calendars.readableCalendars) { item in
                Toggle(isOn: Binding(get: { references == nil || references!.contains(item.reference) }, set: { selected in
                    var values = references ?? calendars.readableCalendars.map(\.reference)
                    values.removeAll { $0 == item.reference }
                    if selected { values.append(item.reference) }
                    update(values)
                })) {
                    HStack {
                        Circle().fill(item.color).frame(width: 9, height: 9)
                        VStack(alignment: .leading, spacing: 3) {
                            Text(item.title)
                            Text(item.account + (item.canWrite ? "" : " · 只读")).font(.caption).foregroundStyle(Notebook.secondaryInk)
                        }
                    }
                }.tint(Notebook.accent).padding(.vertical, 4).accessibilityIdentifier("calendarFilter-\(item.id)")
            }
            if references?.isEmpty == true { Text(forPlanning ? "未选择参考日历，不会避开已有事件。" : "未选择要显示的日历。").font(.caption).foregroundStyle(Notebook.secondaryInk) }
        }
    }
    private func update(_ references: [CalendarReference]?) {
        var value = preferences.calendarPreferences
        if forPlanning { value.planningCalendars = references } else { value.visibleCalendars = references }
        preferences.setCalendarPreferences(value)
    }
}
