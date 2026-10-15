import SwiftUI
import WidgetKit

@main struct ShikeCountdownWidget: Widget {
    init() { CompanionStyle.registerFont() }
    var body: some WidgetConfiguration {
        AppIntentConfiguration(kind: "ShikeCountdowns", intent: CountdownWidgetIntent.self, provider: CountdownWidgetProvider()) { CountdownWidgetView(entry: $0) }
            .configurationDisplayName("拾刻计划倒数日")
            .description("值得期待，也值得记住。按分组自动选择，或指定一到两个正数日、倒数日。")
            #if os(watchOS)
            .supportedFamilies([.accessoryRectangular])
            #elseif os(iOS) && !targetEnvironment(macCatalyst)
            .supportedFamilies([.systemSmall, .systemMedium, .systemLarge, .accessoryInline, .accessoryCircular, .accessoryRectangular])
            #else
            .supportedFamilies([.systemSmall, .systemMedium, .systemLarge])
            #endif
    }
}

#if !os(watchOS)
#Preview(as: .systemSmall) { ShikeCountdownWidget() } timeline: { CountdownWidgetEntry.preview }

#endif
