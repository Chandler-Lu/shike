import SwiftUI
import CoreText
import ShikeCore

enum CompanionStyle {
    static let blue = Color(red: 0.20, green: 0.35, blue: 0.78)
    static let lightBlue = Color(red: 0.62, green: 0.75, blue: 1)
    static let green = Color(red: 0.74, green: 0.82, blue: 0.75)
    static func handwriting(_ size: CGFloat) -> Font { .custom("LXGWWenKai-Regular", size: size) }
    static func registerFont() {
        if let url = Bundle.main.url(forResource: "LXGWWenKai-Regular", withExtension: "ttf") {
            CTFontManagerRegisterFontsForURL(url as CFURL, .process, nil)
        }
    }
}

struct CompanionPaper: View {
    @Environment(\.colorScheme) private var scheme
    var body: some View {
        (scheme == .dark ? Color(red: 0.11, green: 0.14, blue: 0.17) : Color(red: 0.973, green: 0.976, blue: 0.953))
            .overlay {
                Canvas { context, size in
                    for x in stride(from: 12.0, to: size.width, by: 22) {
                        for y in stride(from: 12.0, to: size.height, by: 22) {
                            context.fill(Path(ellipseIn: CGRect(x: x, y: y, width: 1, height: 1)), with: .color(.primary.opacity(0.08)))
                        }
                    }
                }.accessibilityHidden(true)
            }
    }
}

struct CompanionUnderline: Shape {
    func path(in rect: CGRect) -> Path {
        var p = Path(); p.move(to: CGPoint(x: 1, y: rect.midY + 1))
        p.addQuadCurve(to: CGPoint(x: rect.maxX - 1, y: rect.midY), control: CGPoint(x: rect.midX, y: rect.midY - 2))
        return p
    }
}

struct CompanionCount: View {
    let entry: Countdown
    let now: Date
    var prominent = false
    var body: some View {
        let value = CountdownDisplayValue(entry, now: now)
        Group {
            if entry.targetTime != nil {
                if prominent {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(value.status).font(.caption2)
                        Text(value.target, style: .timer).font(.system(size: 27, weight: .semibold, design: .rounded)).monospacedDigit()
                    }
                } else {
                    HStack(spacing: 3) {
                        Text(value.phase == .elapsed ? "已过" : "余").font(.caption2)
                        Text(value.target, style: .timer).font(.system(size: 14, weight: .semibold, design: .rounded)).monospacedDigit()
                    }
                }
            } else if prominent {
                if value.phase == .today {
                    Text(value.status).font(CompanionStyle.handwriting(28))
                } else {
                    VStack(alignment: .leading, spacing: 1) {
                        Text(value.status).font(.caption)
                        HStack(alignment: .firstTextBaseline, spacing: 4) {
                            Text("\(value.days)")
                                .font(.system(size: 40, weight: .medium, design: .rounded)).monospacedDigit()
                            Text("天").font(CompanionStyle.handwriting(16))
                        }
                    }
                }
            } else { Text(value.label).font(.system(.subheadline, design: .rounded, weight: .semibold)).monospacedDigit() }
        }.lineLimit(1).minimumScaleFactor(0.7)
    }
}
