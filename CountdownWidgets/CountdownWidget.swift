import SwiftUI
import WidgetKit

@main struct ShikeCountdownWidget: Widget {
    init() { CompanionStyle.registerFont() }
    var body: some WidgetConfiguration {
        AppIntentConfiguration(kind: "ShikeCountdowns", intent: CountdownWidgetIntent.self, provider: CountdownWidgetProvider()) { CountdownWidgetView(entry: $0) }
            .configurationDisplayName("拾刻计划倒数日")
            .description("值得期待，也值得记住。按分组查看倒数日与正数日。")
            #if os(watchOS)
            .supportedFamilies([.accessoryRectangular])
            #else
            .supportedFamilies([.systemSmall, .systemMedium, .systemLarge])
            #endif
    }
}

#if !os(watchOS)
#Preview(as: .systemSmall) { ShikeCountdownWidget() } timeline: { CountdownWidgetEntry.preview }

#endif
