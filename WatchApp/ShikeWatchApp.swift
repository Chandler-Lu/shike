import SwiftUI
import ShikeCore

@main struct ShikeWatchApp: App {
    @StateObject private var connectivity = CountdownConnectivity()
    init() { CompanionStyle.registerFont() }
    var body: some Scene { WindowGroup { WatchCountdownList(connectivity: connectivity) } }
}

struct WatchCountdownList: View {
    @ObservedObject var connectivity: CountdownConnectivity
    @AppStorage("watchCountdownGroup") private var group = "all"
    @Environment(\.scenePhase) private var scenePhase
    @State private var path: [UUID] = []
    var body: some View {
        NavigationStack(path: $path) {
            TimelineView(.periodic(from: .now, by: 60)) { context in
                List {
                    Picker("显示分组", selection: $group) {
                        Text("全部日子").tag("all")
                        Text("未分类").tag("none")
                        ForEach(connectivity.snapshot?.categories ?? []) { Text($0.name).tag($0.id.uuidString) }
                        if connectivity.snapshot?.name(for: group) == nil && group != "all" && group != "none" {
                            Text("分组已删除").tag(group)
                        }
                    }.accessibilityIdentifier("watchCountdownGroup")
                    if let snapshot = connectivity.snapshot {
                        let entries = snapshot.entries(in: group, now: context.date)
                        if entries.isEmpty {
                            Text(snapshot.name(for: group) == nil ? "分组已删除，请选择其他分组。" : "这里还没有记下日子。")
                                .font(CompanionStyle.handwriting(18))
                        }
                        ForEach(entries) { value in
                            NavigationLink(value: value.id) {
                                VStack(alignment: .leading, spacing: 5) {
                                    Text(value.title).font(CompanionStyle.handwriting(19)).lineLimit(2)
                                    CompanionCount(entry: value, now: context.date).foregroundStyle(CompanionStyle.lightBlue)
                                }.padding(.vertical, 5)
                            }.accessibilityIdentifier("watchCountdown-\(value.id)")
                        }
                        Section {
                            Text("上次同步 \(snapshot.generatedAt.formatted(date: .abbreviated, time: .shortened))").font(.caption2).foregroundStyle(.secondary)
                        }
                    } else {
                        Text("打开配对 iPhone 上的拾刻计划，日子就会来到这里。")
                            .font(CompanionStyle.handwriting(19)).padding(.vertical, 12)
                    }
                    if let status = connectivity.status { Text(status).font(.caption2).foregroundStyle(.secondary) }
                }
            }
            .navigationTitle("拾刻计划")
            .navigationDestination(for: UUID.self) { id in
                if let item = connectivity.snapshot?.items.first(where: { $0.id == id }) { WatchCountdownDetail(entry: item.countdown) }
                else { Text("这个日子已被删除。").font(CompanionStyle.handwriting(20)) }
            }
        }
        .onAppear { connectivity.refresh() }
        .onChange(of: scenePhase) { _, value in if value == .active { connectivity.refresh() } }
        .onOpenURL { url in
            guard let route = CountdownRoute(url: url) else { return }
            group = route.group; path = route.id.map { [$0] } ?? []
        }
    }
}

struct WatchCountdownDetail: View {
    let entry: Countdown
    @Environment(\.isLuminanceReduced) private var reduced
    var body: some View {
        TimelineView(.periodic(from: .now, by: entry.targetTime != nil && !reduced ? 1 : 60)) { context in
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    Text(entry.title).font(CompanionStyle.handwriting(24)).fixedSize(horizontal: false, vertical: true)
                    CompanionCount(entry: entry, now: context.date, prominent: true).foregroundStyle(CompanionStyle.lightBlue)
                    CompanionUnderline().stroke(CompanionStyle.green, style: StrokeStyle(lineWidth: 3, lineCap: .round)).frame(height: 4)
                    Text(CountdownDates.targetDescription(entry)).font(.footnote).monospacedDigit()
                    Text(entry.calendar.title + " · " + entry.recurrence.title).font(.caption).foregroundStyle(.secondary)
                    if entry.calendar == .chinese, let lunar = CountdownDates.lunarDate(entry) {
                        Text("农历\(lunar.isLeapMonth ? "闰" : "")\(lunar.month)月\(lunar.day)日").font(.caption)
                    }
                    if let next = CountdownDates.next(entry, onOrAfter: context.date), entry.recurrence != .none {
                        Text("下一次 · \(CivilDate(next, timeZone: entry.timeZone()).description)").font(.caption)
                    }
                    Text(entry.timeZoneIdentifier ?? "系统时区").font(.caption2).foregroundStyle(.secondary)
                }.frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 6)
            }
        }.navigationTitle("记下的日子")
    }
}
