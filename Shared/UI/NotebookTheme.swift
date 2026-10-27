import SwiftUI
import ShikeCore

/// Launch-only styling for real App Store captures. Never enabled in Release.
enum StoreCaptureStyle {
    static var isEnabled: Bool {
        #if DEBUG
        let arguments = ProcessInfo.processInfo.arguments
        return ["-ui-testing", "-store-screenshots", "-store-clean-capture"].allSatisfy(arguments.contains)
        #else
        return false
        #endif
    }

    @MainActor static func configureBars() {
        #if DEBUG
        guard isEnabled else { return }
        let navigation = UINavigationBarAppearance()
        navigation.configureWithOpaqueBackground()
        navigation.backgroundColor = .white
        navigation.shadowColor = .clear
        let bar = UINavigationBar.appearance()
        bar.standardAppearance = navigation
        bar.scrollEdgeAppearance = navigation
        bar.compactAppearance = navigation
        bar.compactScrollEdgeAppearance = navigation
        let tabs = UITabBarAppearance()
        tabs.configureWithOpaqueBackground()
        tabs.backgroundColor = .white
        UITabBar.appearance().standardAppearance = tabs
        UITabBar.appearance().scrollEdgeAppearance = tabs
        #endif
    }
}

extension View {
    @ViewBuilder func storeCaptureAppearance() -> some View {
        if StoreCaptureStyle.isEnabled {
            if #available(iOS 26.0, *) {
                self.preferredColorScheme(.light)
                    .toolbarBackground(.white, for: .navigationBar, .tabBar)
                    .toolbarBackground(.visible, for: .navigationBar, .tabBar)
                    .scrollEdgeEffectHidden()
            } else {
                self.preferredColorScheme(.light)
                    .toolbarBackground(.white, for: .navigationBar, .tabBar)
                    .toolbarBackground(.visible, for: .navigationBar, .tabBar)
            }
        } else { self }
    }
}

enum Notebook {
    static let blue = Color(red: 49/255, green: 89/255, blue: 199/255)
    static let yellow = Color(red: 246/255, green: 221/255, blue: 117/255)
    static let green = Color(red: 189/255, green: 209/255, blue: 190/255)
    static let red = Color(red: 184/255, green: 68/255, blue: 62/255)
    static var secondaryInk: Color { Color(uiColor: UIColor { $0.userInterfaceStyle == .dark ? UIColor(red: 0.71, green: 0.76, blue: 0.78, alpha: 1) : UIColor(red: 0.36, green: 0.40, blue: 0.44, alpha: 1) }) }
    static var paper: Color { StoreCaptureStyle.isEnabled ? .white : Color(uiColor: UIColor { $0.userInterfaceStyle == .dark ? UIColor(red: 0.11, green: 0.14, blue: 0.17, alpha: 1) : UIColor(red: 248/255, green: 249/255, blue: 243/255, alpha: 1) }) }
    static var ink: Color { Color(uiColor: UIColor { $0.userInterfaceStyle == .dark ? UIColor(red: 0.91, green: 0.94, blue: 0.89, alpha: 1) : UIColor(red: 40/255, green: 53/255, blue: 66/255, alpha: 1) }) }
    static var accent: Color { Color(uiColor: UIColor { $0.userInterfaceStyle == .dark ? UIColor(red: 0.57, green: 0.70, blue: 1, alpha: 1) : UIColor(red: 49/255, green: 89/255, blue: 199/255, alpha: 1) }) }
    static func handwriting(_ size: CGFloat, relativeTo style: Font.TextStyle = .title2) -> Font {
        .custom("LXGWWenKai-Regular", size: size, relativeTo: style)
    }
}

extension CountdownCardColor {
    var paperFill: Color {
        guard self != .paper else { return Notebook.paper }
        let light: UInt32, dark: UInt32
        switch self {
        case .paper: return Notebook.paper
        case .cream: (light, dark) = (0xF6EDCA, 0x332E22)
        case .peach: (light, dark) = (0xF4E2DF, 0x34272C)
        case .sage: (light, dark) = (0xE4ECDD, 0x273128)
        case .sky: (light, dark) = (0xDFE9F1, 0x23303B)
        case .lilac: (light, dark) = (0xE9E2F1, 0x2D293B)
        }
        return Self.adaptiveColor(light: light, dark: dark)
    }

    /// Muted ink paired with the paper, shared by the count and its small labels.
    var countInk: Color {
        let light: UInt32, dark: UInt32
        switch self {
        case .paper: (light, dark) = (0x4B5D73, 0xC5CED7)
        case .cream: (light, dark) = (0x6B604A, 0xD5C8AE)
        case .peach: (light, dark) = (0x765D60, 0xD9BEC1)
        case .sage: (light, dark) = (0x536B59, 0xBBD0BE)
        case .sky: (light, dark) = (0x50677C, 0xBCD0E0)
        case .lilac: (light, dark) = (0x685E78, 0xCBC2DB)
        }
        return Self.adaptiveColor(light: light, dark: dark)
    }

    private static func adaptiveColor(light: UInt32, dark: UInt32) -> Color {
        return Color(uiColor: UIColor { traits in
            let hex = traits.userInterfaceStyle == .dark ? dark : light
            return UIColor(red: CGFloat((hex >> 16) & 255) / 255,
                           green: CGFloat((hex >> 8) & 255) / 255,
                           blue: CGFloat(hex & 255) / 255, alpha: 1)
        })
    }
}

struct PencilBorder: Shape {
    func path(in r: CGRect) -> Path {
        if StoreCaptureStyle.isEnabled {
            return Path(roundedRect: r.insetBy(dx: 0.6, dy: 0.6), cornerRadius: 13)
        }
        var p = Path()
        p.move(to: CGPoint(x: r.minX + 13, y: r.minY + 1))
        p.addCurve(to: CGPoint(x: r.maxX - 12, y: r.minY + 2), control1: CGPoint(x: r.width * 0.35, y: r.minY - 1), control2: CGPoint(x: r.width * 0.72, y: r.minY + 3))
        p.addQuadCurve(to: CGPoint(x: r.maxX - 1, y: r.minY + 12), control: CGPoint(x: r.maxX + 1, y: r.minY))
        p.addLine(to: CGPoint(x: r.maxX - 2, y: r.maxY - 11))
        p.addQuadCurve(to: CGPoint(x: r.maxX - 14, y: r.maxY - 1), control: CGPoint(x: r.maxX, y: r.maxY + 1))
        p.addCurve(to: CGPoint(x: r.minX + 12, y: r.maxY - 2), control1: CGPoint(x: r.width * 0.67, y: r.maxY + 1), control2: CGPoint(x: r.width * 0.33, y: r.maxY - 3))
        p.addQuadCurve(to: CGPoint(x: r.minX + 1, y: r.maxY - 12), control: CGPoint(x: r.minX - 1, y: r.maxY))
        p.addLine(to: CGPoint(x: r.minX + 2, y: r.minY + 13))
        p.addQuadCurve(to: CGPoint(x: r.minX + 13, y: r.minY + 1), control: CGPoint(x: r.minX, y: r.minY))
        return p
    }
}

struct PaperBackground: View {
    var body: some View {
        Notebook.paper.overlay {
            if !StoreCaptureStyle.isEnabled { Canvas { context, size in
                for y in stride(from: 10.0, to: size.height, by: 24) {
                    for x in stride(from: 14.0, to: size.width, by: 24) {
                        context.fill(Path(ellipseIn: CGRect(x: x, y: y, width: 1.1, height: 1.1)), with: .color(Notebook.ink.opacity(0.10)))
                    }
                }
            }.accessibilityHidden(true) }
        }.ignoresSafeArea()
    }
}

struct PaperCard<Content: View>: View {
    var tint: Color = Notebook.paper
    var contentPadding: CGFloat = 18
    @ViewBuilder var content: Content
    var body: some View {
        content.padding(contentPadding).frame(maxWidth: .infinity, alignment: .leading)
            .background(tint, in: RoundedRectangle(cornerRadius: 13))
            .overlay(PencilBorder().stroke(Notebook.ink.opacity(StoreCaptureStyle.isEnabled ? 0.38 : 0.30), style: StrokeStyle(lineWidth: 1.2, lineCap: .round)))
    }
}

struct InkButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled
    var prominent = true
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.font(.system(.body, design: .rounded, weight: .semibold))
            .frame(maxWidth: .infinity).frame(minHeight: 48)
            .foregroundStyle(prominent ? .white : Notebook.ink)
            .background(prominent ? Notebook.blue : Notebook.paper, in: RoundedRectangle(cornerRadius: 13))
            .overlay(PencilBorder().stroke(prominent ? Notebook.blue : Notebook.ink.opacity(0.45), lineWidth: 1.3))
            .opacity(!isEnabled ? 0.45 : (configuration.isPressed ? 0.78 : 1))
    }
}

/// Keep tap and hold mutually exclusive. Do not attach GestureState to only the
/// first gesture: resetting it on release can cancel the pending tap gesture.
struct HoldActionButtonStyle: PrimitiveButtonStyle {
    @Environment(\.isEnabled) private var isEnabled
    let holdLabel: String
    var onHold: () -> Void

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .accessibilityElement(children: .combine)
            .contentShape(Rectangle())
            .gesture(LongPressGesture(minimumDuration: 0.55, maximumDistance: 12)
                .exclusively(before: TapGesture())
                .onEnded { value in
                    guard isEnabled else { return }
                    switch value {
                    case .first(true): onHold()
                    case .second: configuration.trigger()
                    default: break
                    }
                })
            .accessibilityAction { if isEnabled { configuration.trigger() } }
            .accessibilityAction(named: Text(holdLabel)) { if isEnabled { onHold() } }
    }
}

/// Keep the gesture outside the text view so double-tapping a word still selects it.
struct ExpandTextEditorControl: View {
    @Binding var text: String
    let title: String
    let editorID: String
    var placeholder = ""
    var characterLimit: Int? = nil
    var beforeExpand: () -> Void = {}
    @Environment(\.isEnabled) private var isEnabled
    @State private var showsEditor = false

    var body: some View {
        Image(systemName: "arrow.up.left.and.arrow.down.right")
            .font(.system(size: 17, weight: .medium))
            .foregroundStyle(Notebook.accent)
            .frame(width: 44, height: 44)
            .contentShape(Rectangle())
            .opacity(isEnabled ? 1 : 0.4)
            .onTapGesture(count: 2, perform: expand)
            .accessibilityElement()
            .accessibilityLabel("放大编辑\(title)")
            .accessibilityHint("双击右下角可展开输入框")
            .accessibilityAddTraits(.isButton)
            .accessibilityAction { expand() }
            .accessibilityIdentifier("expand-\(editorID)")
            .sheet(isPresented: $showsEditor) {
                ExpandedTextEditor(text: $text, title: title, editorID: editorID,
                                   placeholder: placeholder, characterLimit: characterLimit)
                    .presentationDetents([.large])
                    .presentationDragIndicator(.visible)
            }
    }

    private func expand() {
        guard isEnabled else { return }
        beforeExpand()
        showsEditor = true
    }
}

private struct ExpandedTextEditor: View {
    @Binding var text: String
    let title: String
    let editorID: String
    let placeholder: String
    let characterLimit: Int?
    @Environment(\.dismiss) private var dismiss
    @FocusState private var focused: Bool

    var body: some View {
        NavigationStack {
            ZStack {
                PaperBackground()
                PaperCard {
                    VStack(alignment: .leading, spacing: 10) {
                        ZStack(alignment: .topLeading) {
                            Text(placeholder).foregroundStyle(Notebook.secondaryInk)
                                .padding(.top, 8).padding(.leading, 5).allowsHitTesting(false)
                                .opacity(text.isEmpty ? 1 : 0).accessibilityHidden(!text.isEmpty)
                            TextEditor(text: $text)
                                .foregroundColor(Notebook.ink).tint(Notebook.accent)
                                .scrollContentBackground(.hidden)
                                .focused($focused)
                                .accessibilityLabel(title)
                                .accessibilityIdentifier("expanded-\(editorID)")
                        }.font(.body).frame(maxWidth: .infinity, maxHeight: .infinity)
                        Text(characterLimit.map { "\(text.count) / \($0) 字" } ?? "\(text.count) 字")
                            .font(.caption).foregroundStyle(Notebook.secondaryInk)
                    }
                }.padding(.horizontal, 16).padding(.vertical, 12)
            }.foregroundStyle(Notebook.ink)
                .navigationTitle(title).navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("收起") { focused = false; dismiss() }
                            .accessibilityIdentifier("collapse-\(editorID)")
                    }
                    ToolbarItemGroup(placement: .keyboard) {
                        Spacer()
                        Button("收起键盘") { focused = false }
                    }
                }
                .task {
                    // Wait for presentation before moving focus from the compact editor.
                    do { try await Task.sleep(for: .milliseconds(250)) } catch { return }
                    focused = true
                }
        }.tint(Notebook.accent)
    }
}

struct MarginTitle: View {
    let title: String
    var subtitle: String? = nil
    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title).font(Notebook.handwriting(30, relativeTo: .title)).foregroundStyle(Notebook.ink)
            if let subtitle { Text(subtitle).font(.subheadline).foregroundStyle(Notebook.secondaryInk).fixedSize(horizontal: false, vertical: true) }
        }.frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct NoteMessage: View {
    let text: String
    var isError = false
    var body: some View {
        HStack(alignment: .top, spacing: 9) {
            Image(systemName: isError ? "exclamationmark.circle" : "checkmark.circle")
            Text(text).fixedSize(horizontal: false, vertical: true)
        }.font(.subheadline).foregroundStyle(isError ? Notebook.red : Notebook.ink)
            .padding(13).frame(maxWidth: .infinity, alignment: .leading)
            .background((isError ? Notebook.red : Notebook.green).opacity(0.15), in: RoundedRectangle(cornerRadius: 10))
            .accessibilityElement(children: .combine)
    }
}

struct CalendarDoodle: View {
    var body: some View {
        ZStack {
            PencilBorder().fill(Notebook.paper)
            PencilBorder().stroke(Notebook.ink, style: StrokeStyle(lineWidth: 2.3, lineCap: .round))
            Path { p in
                p.move(to: CGPoint(x: 3, y: 25)); p.addLine(to: CGPoint(x: 76, y: 24))
                p.move(to: CGPoint(x: 21, y: 0)); p.addLine(to: CGPoint(x: 20, y: 12))
                p.move(to: CGPoint(x: 58, y: 0)); p.addLine(to: CGPoint(x: 59, y: 12))
            }.stroke(Notebook.ink, style: StrokeStyle(lineWidth: 2.7, lineCap: .round))
            Path { p in
                p.move(to: CGPoint(x: 23, y: 46)); p.addLine(to: CGPoint(x: 35, y: 57)); p.addLine(to: CGPoint(x: 59, y: 36))
            }.stroke(Notebook.blue, style: StrokeStyle(lineWidth: 5, lineCap: .round, lineJoin: .round))
        }.frame(width: 80, height: 75).rotationEffect(.degrees(-7)).accessibilityHidden(true)
    }
}

// Date.FormatStyle does not inherit SwiftUI's environment time zone.
extension Date.FormatStyle {
    func inTimeZone(_ zone: TimeZone) -> Self { var value = self; value.timeZone = zone; return value }
}
