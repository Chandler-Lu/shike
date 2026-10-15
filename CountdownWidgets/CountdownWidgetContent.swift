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
struct CountdownDayEntity: AppEntity {
    static var typeDisplayRepresentation = TypeDisplayRepresentation(name: "指定日子")
    static var defaultQuery = CountdownDayQuery()
    // Optional AppEntity pickers do not consistently offer a system Clear action.
    // Keep the UUID identifier type so existing widget configurations still resolve.
    static let unselectedID = UUID(uuidString: "00000000-0000-0000-0000-000000000000")!
    static var unselected: Self { .init(id: unselectedID, name: "留空", date: "不指定日子") }
    var id: UUID
    var name: String
    var date: String
    var displayRepresentation: DisplayRepresentation { DisplayRepresentation(title: "\(name)", subtitle: "\(date)") }
}
struct CountdownDayQuery: EntityStringQuery {
    private func choices() -> [CountdownDayEntity] {
        [CountdownDayEntity.unselected] + ((try? CountdownSnapshotStorage.read())?.items ?? []).map {
            CountdownDayEntity(id: $0.id, name: $0.title, date: $0.anchorDate.description)
        }.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }
    func entities(for identifiers: [UUID]) async throws -> [CountdownDayEntity] {
        let values = choices()
        return identifiers.map { id in values.first { $0.id == id } ?? .init(id: id, name: "日子已删除", date: "请重新选择") }
    }
    func suggestedEntities() async throws -> [CountdownDayEntity] { choices() }
    func defaultResult() async -> CountdownDayEntity? { .unselected }
    func entities(matching string: String) async throws -> [CountdownDayEntity] {
        choices().filter { $0.id == CountdownDayEntity.unselectedID || string.isEmpty || $0.name.localizedStandardContains(string) }
    }
}
struct CountdownWidgetIntent: WidgetConfigurationIntent {
    static var title: LocalizedStringResource = "选择展示日子"
    static var description = IntentDescription("可指定一或两个日子。小号与锁屏优先显示第一个，中号与大号平等展示。选择“留空”可取消指定；两个都留空时按分组自动选择。")
    @Parameter(title: "显示分组") var group: CountdownGroupEntity?
    @Parameter(title: "第一个日子（可选）") var countdown: CountdownDayEntity?
    @Parameter(title: "第二个日子（可选）") var secondCountdown: CountdownDayEntity?
    init() { group = .all }
    init(group: CountdownGroupEntity) { self.group = group }
}
struct CountdownWidgetEntry: TimelineEntry {
    let date: Date
    let snapshot: CountdownSnapshot?
    let group: String
    var unavailable = false
    var countdownID: UUID? = nil
    var secondCountdownID: UUID? = nil
    private var specifiedIDs: [UUID] {
        var seen = Set<UUID>()
        return [countdownID, secondCountdownID].compactMap { $0 }.filter {
            $0 != CountdownDayEntity.unselectedID && seen.insert($0).inserted
        }
    }
    var hasSpecifiedDays: Bool { !specifiedIDs.isEmpty }
    var displayedEntries: [Countdown] {
        if hasSpecifiedDays {
            return specifiedIDs.compactMap { id in snapshot?.items.first { $0.id == id }?.countdown }
        }
        return snapshot?.entries(in: group, now: date) ?? []
    }
    func selection(limitPerSection: Int = 1) -> CountdownWidgetSelection {
        CountdownWidgetSelection(displayedEntries, limitPerSection: limitPerSection, now: date, preserveOrder: hasSpecifiedDays)
    }
    var displayedName: String? { hasSpecifiedDays ? "指定日子" : snapshot?.name(for: group) }
    var routeGroup: String { hasSpecifiedDays ? "all" : group }
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
        let entries = value.displayedEntries
        let dates = CountdownPresentation.timelineDates(entries, now: value.date)
        return Timeline(entries: dates.map { .init(date: $0, snapshot: value.snapshot, group: value.group, unavailable: value.unavailable, countdownID: value.countdownID, secondCountdownID: value.secondCountdownID) }, policy: .atEnd)
    }
    func recommendations() -> [AppIntentRecommendation<CountdownWidgetIntent>] {
        #if os(watchOS)
        if #available(watchOS 26, *) { return [] }
        #endif
        return CountdownGroupQuery.groups().map { AppIntentRecommendation(intent: CountdownWidgetIntent(group: $0), description: $0.name) }
    }
    private func load(_ configuration: CountdownWidgetIntent) -> CountdownWidgetEntry {
        do { return .init(date: .now, snapshot: try CountdownSnapshotStorage.read(), group: configuration.group?.id ?? "all", countdownID: configuration.countdown?.id, secondCountdownID: configuration.secondCountdown?.id) }
        catch { return .init(date: .now, snapshot: nil, group: configuration.group?.id ?? "all", unavailable: true, countdownID: configuration.countdown?.id, secondCountdownID: configuration.secondCountdown?.id) }
    }
}

struct CountdownWidgetView: View {
    let entry: CountdownWidgetEntry
    @Environment(\.widgetFamily) private var family
    var body: some View {
        #if os(iOS) && !targetEnvironment(macCatalyst)
        if [.accessoryInline, .accessoryCircular, .accessoryRectangular].contains(family) {
            CountdownLockScreenContent(entry: entry, family: family)
                .containerBackground(for: .widget) { Color.clear }
        } else {
            desktopContent
        }
        #else
        desktopContent
        #endif
    }
    private var desktopContent: some View {
        CountdownWidgetContent(entry: entry, family: family)
            .containerBackground(for: .widget) { CompanionPaper() }
    }
}

#if os(iOS) && !targetEnvironment(macCatalyst)
/// Lock Screen uses the system's monochrome treatment and small accessory canvas.
struct CountdownLockScreenContent: View {
    let entry: CountdownWidgetEntry
    let family: WidgetFamily
    private var selection: CountdownWidgetSelection {
        entry.selection()
    }
    private var emptyMessage: String {
        if entry.unavailable { return "打开拾刻计划重试" }
        if entry.snapshot == nil { return "打开拾刻计划添加日子" }
        if entry.hasSpecifiedDays { return "日子已删除，请重新选择" }
        if entry.snapshot?.name(for: entry.group) == nil { return "请重新选择分组" }
        return "这个分组还没有日子"
    }
    var body: some View {
        Group {
            if let primary = selection.primary {
                let value = CountdownDisplayValue(primary, now: entry.date)
                switch family {
                case .accessoryInline:
                    if primary.targetTime != nil {
                        Label {
                            Text("\(value.status) ") + Text(value.target, style: .timer) + Text(" · \(primary.title)")
                        } icon: { Image(systemName: value.phase == .elapsed ? "heart" : "calendar") }
                    } else {
                        Label("\(countLabel(primary)) · \(primary.title)", systemImage: value.phase == .elapsed ? "heart" : "calendar")
                    }
                case .accessoryCircular:
                    ZStack {
                        AccessoryWidgetBackground()
                        VStack(spacing: 1) {
                            Text(value.phase == .today ? "就在" : value.status).font(.system(size: 10))
                            Text(value.phase == .today ? "今天" : "\(value.days)天")
                                .font(.system(size: 21, weight: .semibold, design: .rounded)).monospacedDigit()
                                .lineLimit(1).minimumScaleFactor(0.45).widgetAccentable()
                            Text(primary.title).font(.system(size: 9)).lineLimit(1)
                        }.padding(4)
                    }.accessibilityElement(children: .ignore).accessibilityLabel("\(primary.title)，\(value.label)")
                default:
                    VStack(alignment: .leading, spacing: 3) {
                        Text(primary.title).font(.headline).lineLimit(1).widgetAccentable()
                        HStack(alignment: .firstTextBaseline, spacing: 5) {
                            if primary.targetTime != nil {
                                Text(value.status).font(.caption2)
                                Text(value.target, style: .timer).monospacedDigit().font(.system(size: 20, weight: .semibold, design: .rounded))
                            } else {
                                Text(countLabel(primary)).font(.system(size: 21, weight: .semibold, design: .rounded)).monospacedDigit()
                            }
                        }.lineLimit(1).minimumScaleFactor(0.6)
                        if let secondary = selection.secondary {
                            HStack(spacing: 4) {
                                Text(secondary.title).lineLimit(1).frame(maxWidth: .infinity, alignment: .leading)
                                Text(countLabel(secondary)).lineLimit(1).fixedSize()
                            }.font(.caption2)
                        } else {
                            Text(value.date.description + (primary.calendar == .chinese ? " · 农历" : ""))
                                .font(.caption2).lineLimit(1)
                        }
                    }.frame(maxWidth: .infinity, alignment: .leading)
                }
            } else if family == .accessoryCircular {
                ZStack {
                    AccessoryWidgetBackground()
                    VStack(spacing: 3) { Image(systemName: "calendar.badge.plus"); Text("打开拾刻").font(.system(size: 10)) }
                }.accessibilityLabel(emptyMessage)
            } else {
                Label(emptyMessage, systemImage: "calendar.badge.plus").font(.caption)
            }
        }
        .foregroundStyle(.primary)
        .privacySensitive()
        .widgetURL(CountdownRoute(group: entry.routeGroup, id: selection.primary?.id).url)
    }
    private func countLabel(_ countdown: Countdown) -> String {
        let value = CountdownDisplayValue(countdown, now: entry.date)
        return value.phase == .today ? "就是今天" : "\(value.status) \(value.days) 天"
    }
}
#endif
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
    private var isAccessory: Bool {
        #if os(macOS) || targetEnvironment(macCatalyst)
        false
        #else
        family == .accessoryRectangular
        #endif
    }
    private var secondaryInk: Color { ink.opacity(0.7) }
    private var memoryColor: Color { scheme == .dark ? Color(red: 0.69, green: 0.85, blue: 0.73) : Color(red: 0.25, green: 0.44, blue: 0.34) }
    var body: some View {
        let snapshot = entry.snapshot
        let name = entry.displayedName
        let entries = entry.displayedEntries
        let selection = entry.selection(limitPerSection: sectionLimit)
        VStack(alignment: .leading, spacing: isSmall ? 5 : 8) {
            if snapshot == nil || name == nil || entries.isEmpty {
                Label("拾刻计划 · 倒数日", systemImage: "heart.text.clipboard").font(.caption)
                Spacer(minLength: 0)
                Text(emptyMessage(snapshot: snapshot, name: name)).font(CompanionStyle.handwriting(isAccessory ? 13 : 19))
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
            } else if isAccessory {
                // The Watch keeps its compact two-row design.
                accessory(entries: entry.hasSpecifiedDays ? [selection.primary, selection.secondary].compactMap { $0 } : entries, name: name!)
            } else if isSmall, let primary = selection.primary {
                small(primary: primary, secondary: selection.secondary, name: name!)
            } else if entry.hasSpecifiedDays {
                header(name: name!, total: entries.count)
                specified(entries).frame(maxHeight: .infinity)
                yearFooter(remaining: 0)
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
        .widgetURL(CountdownRoute(group: entry.routeGroup, id: isSmall ? selection.primary?.id : nil).url)
    }

    private func header(name: String, total: Int) -> some View {
        Link(destination: CountdownRoute(group: entry.routeGroup).url) {
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

    private func specified(_ entries: [Countdown]) -> some View {
        let layout = isLarge ? AnyLayout(VStackLayout(alignment: .leading, spacing: 14)) : AnyLayout(HStackLayout(alignment: .top, spacing: 14))
        return layout {
            ForEach(entries) { value in
                Link(destination: CountdownRoute(group: entry.routeGroup, id: value.id).url) {
                    VStack(alignment: .leading, spacing: isLarge ? 6 : 3) {
                        title(value, size: isLarge ? 22 : 16, lines: isLarge ? 2 : 1)
                        dayCount(value, size: isLarge ? 40 : 30, inlineStatus: true)
                        dateCaption(value, showCalendar: true)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
                }.buttonStyle(.plain)
            }
        }
    }

    private func section(_ values: [Countdown], elapsed: Bool) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            sectionHeading(elapsed: elapsed)
            ForEach(values) { value in
                Link(destination: CountdownRoute(group: entry.routeGroup, id: value.id).url) {
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
                Link(destination: CountdownRoute(group: entry.routeGroup, id: value.id).url) {
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
                Link(destination: CountdownRoute(group: entry.routeGroup, id: value.id).url) {
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
        if entry.hasSpecifiedDays { return "指定日子已删除，请重新选择。" }
        if name == nil { return "分组已删除，请重新选择。" }
        return "这个分组，还没有日子。"
    }
}

