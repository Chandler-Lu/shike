import AppIntents
import WidgetKit
import SwiftUI
import ShikeCore

struct CountdownGroupEntity: AppEntity {
    static var typeDisplayRepresentation = TypeDisplayRepresentation(name: "倒数日分组")
    static var defaultQuery = CountdownGroupQuery()
    var id: String
    var name: String
    var displayRepresentation: DisplayRepresentation { DisplayRepresentation(title: "\(name)") }
    static var all: Self { .init(id: "all", name: "全部日子") }
}
struct CountdownGroupQuery: EntityQuery {
    func entities(for identifiers: [String]) async throws -> [CountdownGroupEntity] {
        let snapshot = try CountdownSnapshotStorage.read() ?? CountdownSnapshot()
        return identifiers.map { .init(id: $0, name: snapshot.name(for: $0) ?? "分组已删除") }
    }
    func suggestedEntities() async throws -> [CountdownGroupEntity] { Self.groups() }
    func defaultResult() async -> CountdownGroupEntity? { .all }
    static func groups() -> [CountdownGroupEntity] {
        [.all, .init(id: "none", name: "未分类")] + ((try? CountdownSnapshotStorage.read())?.categories ?? []).map { .init(id: $0.id.uuidString, name: $0.name) }
    }
}
struct CountdownWidgetIntent: WidgetConfigurationIntent {
    static var title: LocalizedStringResource = "选择倒数日分组"
    static var description = IntentDescription("显示一个分组，或者全部日子。")
    @Parameter(title: "显示分组") var group: CountdownGroupEntity?
    init() { group = .all }
    init(group: CountdownGroupEntity) { self.group = group }
}
struct CountdownWidgetEntry: TimelineEntry {
    let date: Date
    let snapshot: CountdownSnapshot?
    let group: String
    var unavailable = false
    static var preview: Self {
        var calendar = Calendar(identifier: .gregorian); calendar.timeZone = .current
        let titles = ["下一次，一起去看海", "每年的小小纪念", "回家吃一顿饭", "在一起的日子", "第一次远行", "开始新的生活"]
        let offsets = [12, 30, 46, -1421, -290, -873]
        let entries = titles.enumerated().map {
            var value = Countdown(title: $0.element, date: CivilDate(calendar.date(byAdding: .day, value: offsets[$0.offset], to: .now)!))
            value.pinned = $0.offset == 0 || $0.offset == 3
            return value
        }
        return Self(date: .now, snapshot: CountdownSnapshot(entries: entries), group: "all")
    }
}
struct CountdownWidgetProvider: AppIntentTimelineProvider {
    func placeholder(in context: Context) -> CountdownWidgetEntry { .preview }
    func snapshot(for configuration: CountdownWidgetIntent, in context: Context) async -> CountdownWidgetEntry {
        context.isPreview ? .preview : load(configuration)
    }
    func timeline(for configuration: CountdownWidgetIntent, in context: Context) async -> Timeline<CountdownWidgetEntry> {
        let value = load(configuration)
        let entries = value.snapshot?.entries(in: value.group, now: value.date) ?? []
        let dates = CountdownPresentation.timelineDates(entries, now: value.date)
        return Timeline(entries: dates.map { .init(date: $0, snapshot: value.snapshot, group: value.group, unavailable: value.unavailable) }, policy: .atEnd)
    }
    func recommendations() -> [AppIntentRecommendation<CountdownWidgetIntent>] {
        #if os(watchOS)
        if #available(watchOS 26, *) { return [] }
        #endif
        return CountdownGroupQuery.groups().map { AppIntentRecommendation(intent: CountdownWidgetIntent(group: $0), description: $0.name) }
    }
    private func load(_ configuration: CountdownWidgetIntent) -> CountdownWidgetEntry {
        do { return .init(date: .now, snapshot: try CountdownSnapshotStorage.read(), group: configuration.group?.id ?? "all") }
        catch { return .init(date: .now, snapshot: nil, group: configuration.group?.id ?? "all", unavailable: true) }
    }
}

struct CountdownWidgetView: View {
    let entry: CountdownWidgetEntry
    @Environment(\.widgetFamily) private var family
    var body: some View {
        CountdownWidgetContent(entry: entry, family: family)
            .containerBackground(for: .widget) { CompanionPaper() }
    }
}
struct CountdownWidgetContent: View {
    let entry: CountdownWidgetEntry
    let family: WidgetFamily
    @Environment(\.colorScheme) private var scheme
    @Environment(\.dynamicTypeSize) private var typeSize
    @Environment(\.widgetRenderingMode) private var renderingMode
    private var accent: Color { scheme == .dark ? CompanionStyle.lightBlue : CompanionStyle.blue }
    private var ink: Color { scheme == .dark ? Color(red: 0.91, green: 0.94, blue: 0.89) : Color(red: 0.16, green: 0.21, blue: 0.26) }
    private var isSmall: Bool {
        #if os(watchOS)
        false
        #else
        family == .systemSmall
        #endif
    }
    private var isLarge: Bool {
        #if os(watchOS)
        false
        #else
        family == .systemLarge
        #endif
    }
    private var sectionLimit: Int { isLarge ? (typeSize.isAccessibilitySize ? 2 : 3) : 1 }
    private var secondaryInk: Color { ink.opacity(0.7) }
    private var memoryColor: Color { scheme == .dark ? Color(red: 0.69, green: 0.85, blue: 0.73) : Color(red: 0.25, green: 0.44, blue: 0.34) }
    var body: some View {
        let snapshot = entry.snapshot
        let name = snapshot?.name(for: entry.group)
        let entries = snapshot?.entries(in: entry.group, now: entry.date) ?? []
        let selection = CountdownWidgetSelection(entries, limitPerSection: sectionLimit, now: entry.date)
        VStack(alignment: .leading, spacing: isSmall ? 5 : 8) {
            if snapshot == nil || name == nil || entries.isEmpty {
                Label("拾刻计划 · 倒数日", systemImage: "heart.text.clipboard").font(.caption)
                Spacer(minLength: 0)
                Text(emptyMessage(snapshot: snapshot, name: name)).font(CompanionStyle.handwriting(family == .accessoryRectangular ? 13 : 19))
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
            } else if family == .accessoryRectangular {
                // The Watch keeps its compact two-row design.
                accessory(entries: entries, name: name!)
            } else if isSmall, let primary = selection.primary {
                small(primary: primary, secondary: selection.secondary, name: name!)
            } else {
                header(name: name!, total: entries.count)
                if !selection.upcoming.isEmpty && !selection.elapsed.isEmpty {
                    HStack(alignment: .top, spacing: 12) {
                        section(selection.upcoming, elapsed: false)
                        Rectangle().fill(ink.opacity(0.12)).frame(width: 1).accessibilityHidden(true)
                        section(selection.elapsed, elapsed: true)
                    }.frame(maxHeight: .infinity)
                } else {
                    singleSection(selection.upcoming.isEmpty ? selection.elapsed : selection.upcoming,
                                  elapsed: selection.upcoming.isEmpty)
                        .frame(maxHeight: .infinity)
                }
                yearFooter(remaining: selection.remainingCount)
            }
        }
        .foregroundStyle(ink)
        .dynamicTypeSize(...DynamicTypeSize.xxxLarge)
        .widgetURL(CountdownRoute(group: entry.group, id: isSmall ? selection.primary?.id : nil).url)
    }

    private func header(name: String, total: Int) -> some View {
        Link(destination: CountdownRoute(group: entry.group).url) {
            HStack(spacing: 4) {
                Image(systemName: "book.closed").font(.system(size: 10))
                Text(name).lineLimit(1)
                Spacer(minLength: 2)
                Text("\(total) 个日子").lineLimit(1).fixedSize()
            }.font(.system(size: 11)).foregroundStyle(secondaryInk)
        }.buttonStyle(.plain)
    }

    private func small(primary: Countdown, secondary: Countdown?, name: String) -> some View {
        let value = CountdownDisplayValue(primary, now: entry.date)
        return VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(name).lineLimit(1)
                Spacer(minLength: 2)
                Image(systemName: value.phase == .elapsed ? "heart" : "sun.max")
            }.font(.system(size: 10)).foregroundStyle(secondaryInk)
            title(primary, size: 16, lines: typeSize.isAccessibilitySize ? 1 : 2)
            dayCount(primary, size: 32, inlineStatus: true)
            dateCaption(primary, showCalendar: false)
            Spacer(minLength: 0)
            if let secondary {
                CompanionUnderline().stroke(CompanionStyle.green, style: StrokeStyle(lineWidth: 2, lineCap: .round))
                    .frame(height: 2).accessibilityHidden(true)
                HStack(alignment: .firstTextBaseline, spacing: 4) {
                    Text(secondary.title).font(CompanionStyle.handwriting(12)).lineLimit(1)
                    Spacer(minLength: 0)
                    shortCount(secondary).font(.system(size: 10, weight: .medium, design: .rounded))
                        .frame(maxWidth: 88, alignment: .trailing).fixedSize(horizontal: true, vertical: false).layoutPriority(1)
                }
                .accessibilityElement(children: .combine)
            }
        }
    }

    private func section(_ values: [Countdown], elapsed: Bool) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            sectionHeading(elapsed: elapsed)
            ForEach(values) { value in
                Link(destination: CountdownRoute(group: entry.group, id: value.id).url) {
                    VStack(alignment: .leading, spacing: 2) {
                        title(value, size: isLarge ? 15 : 16, lines: isLarge ? 2 : 1, reserveTitleSpace: isLarge)
                        dayCount(value, size: isLarge ? 24 : 30, inlineStatus: false)
                        dateCaption(value, showCalendar: isLarge)
                    }.padding(.vertical, isLarge ? 2 : 0)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                        .contentShape(Rectangle())
                }.buttonStyle(.plain)
                    .overlay(alignment: .bottom) {
                        if isLarge && value.id != values.last?.id {
                            CompanionUnderline().stroke(ink.opacity(0.13), lineWidth: 0.8).frame(height: 1).accessibilityHidden(true)
                        }
                    }
            }
            if !isLarge { Spacer(minLength: 0) }
        }.frame(maxWidth: .infinity, alignment: .leading)
    }

    private func singleSection(_ values: [Countdown], elapsed: Bool) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            sectionHeading(elapsed: elapsed)
            ForEach(values) { value in
                Link(destination: CountdownRoute(group: entry.group, id: value.id).url) {
                    HStack(spacing: 10) {
                        VStack(alignment: .leading, spacing: 3) {
                            title(value, size: 17)
                            dateCaption(value, showCalendar: true)
                        }.frame(maxWidth: .infinity, alignment: .leading)
                        dayCount(value, size: isLarge ? 24 : 22, inlineStatus: false)
                            .frame(width: 115, alignment: .trailing)
                    }.frame(maxHeight: .infinity).contentShape(Rectangle())
                }.buttonStyle(.plain)
            }
        }
    }

    private func sectionHeading(elapsed: Bool) -> some View {
        Label(elapsed ? "已经走过" : "值得期待", systemImage: elapsed ? "heart" : "sun.max")
            .font(.system(size: 11, weight: .medium)).foregroundStyle(elapsed ? memoryColor : accent)
            .lineLimit(1).minimumScaleFactor(0.8).widgetAccentable()
    }

    private func title(_ value: Countdown, size: CGFloat, lines: Int = 1, reserveTitleSpace: Bool = false) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 3) {
            Text(value.title).font(CompanionStyle.handwriting(size)).foregroundStyle(ink)
                .lineLimit(lines, reservesSpace: reserveTitleSpace)
                .fixedSize(horizontal: false, vertical: true)
            if value.pinned { Image(systemName: "pin.fill").font(.system(size: 8)).foregroundStyle(secondaryInk) }
        }.frame(maxWidth: .infinity, alignment: .leading)
    }

    private func dayCount(_ countdown: Countdown, size: CGFloat, inlineStatus: Bool) -> some View {
        let value = CountdownDisplayValue(countdown, now: entry.date)
        return Group {
            if countdown.targetTime != nil {
                VStack(alignment: .leading, spacing: 1) {
                    Text(value.status).font(.system(size: 10))
                    Text(value.target, style: .timer).font(.system(size: size * 0.65, weight: .medium, design: .rounded)).monospacedDigit()
                }
            } else if value.phase == .today {
                Text(value.status).font(CompanionStyle.handwriting(size * 0.7))
            } else {
                HStack(alignment: .firstTextBaseline, spacing: 3) {
                    if inlineStatus { Text(value.status).font(.system(size: 10)) }
                    Text("\(value.days)").font(CompanionStyle.handwriting(size)).monospacedDigit()
                    Text("天").font(CompanionStyle.handwriting(13))
                }
            }
        }
        .foregroundStyle(value.phase == .elapsed ? memoryColor : accent)
        .lineLimit(1).minimumScaleFactor(0.7).widgetAccentable()
        .accessibilityElement(children: .ignore).accessibilityLabel(value.label)
    }

    private func shortCount(_ countdown: Countdown) -> some View {
        let value = CountdownDisplayValue(countdown, now: entry.date)
        return Group {
            if countdown.targetTime != nil {
                HStack(spacing: 2) {
                    Text(value.phase == .elapsed ? "已过" : "还有")
                    Text(value.target, style: .timer).monospacedDigit()
                }
            } else {
                Text(value.phase == .today ? "今天" : "\(value.phase == .elapsed ? "已" : "余")\(value.days)天")
            }
        }.foregroundStyle(value.phase == .elapsed ? memoryColor : accent).lineLimit(1).minimumScaleFactor(0.7)
    }

    private func dateCaption(_ countdown: Countdown, showCalendar: Bool) -> some View {
        let value = CountdownDisplayValue(countdown, now: entry.date)
        let suffix = showCalendar && countdown.calendar == .chinese ? " · 农历" : ""
        return Text(value.date.description + suffix)
            .font(.system(size: 10)).monospacedDigit().foregroundStyle(secondaryInk).lineLimit(1).minimumScaleFactor(0.8)
    }

    private func yearFooter(remaining: Int) -> some View {
        let progress = YearProgress(now: entry.date, timeZone: .current)
        return VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 4) {
                Text("今年已过 \(progress.elapsedDays) 天")
                Spacer(minLength: 0)
                Text(remaining > 0 ? "还有 \(remaining) 个日子" : progress.fraction.formatted(.percent.precision(.fractionLength(1))))
            }.font(.system(size: 10)).foregroundStyle(secondaryInk).lineLimit(1)
            GeometryReader { proxy in
                Capsule().fill(ink.opacity(0.08))
                    .overlay(alignment: .leading) {
                        Capsule().fill(LinearGradient(colors: renderingMode == .fullColor
                                                      ? [accent.opacity(0.7), CompanionStyle.green, Color(red: 0.96, green: 0.87, blue: 0.46)]
                                                      : [.primary, .primary.opacity(0.6)], startPoint: .leading, endPoint: .trailing))
                            .frame(width: proxy.size.width * progress.fraction).widgetAccentable()
                    }
            }.frame(height: 4).accessibilityHidden(true)
        }
    }

    private func accessory(entries: [Countdown], name: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(name).font(.caption2).foregroundStyle(secondaryInk).lineLimit(1)
            ForEach(Array(entries.prefix(2))) { value in
                Link(destination: CountdownRoute(group: entry.group, id: value.id).url) {
                    HStack(spacing: 8) {
                        Text(value.title).font(CompanionStyle.handwriting(14)).lineLimit(1).foregroundStyle(ink)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        CompanionCount(entry: value, now: entry.date).foregroundStyle(accent).widgetAccentable()
                    }.frame(maxHeight: .infinity)
                }.buttonStyle(.plain)
            }
        }
    }
    private func emptyMessage(snapshot: CountdownSnapshot?, name: String?) -> String {
        if entry.unavailable { return "暂时无法读取，打开拾刻计划重试。" }
        if snapshot == nil {
            #if os(watchOS)
            return "打开 iPhone 上的拾刻计划，开始同步。"
            #else
            return "打开拾刻计划，记下值得期待的日子。"
            #endif
        }
        if name == nil { return "分组已删除，请重新选择。" }
        return "这个分组，还没有日子。"
    }
}

