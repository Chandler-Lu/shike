import SwiftUI

struct CountdownArtwork: Identifiable, Equatable {
    enum Kind: String, CaseIterable, Identifiable {
        case rabbit = "兔兔", cat = "猫咪", together = "在一起"
        var id: String { rawValue }
    }
    let id: String
    let title: String
    let kind: Kind
    let asset: String
    static let original = Self(id: "original", title: "一起读书", kind: .together, asset: "SettingsCompanions")
    static let all: [Self] = [original] + make(.rabbit, prefix: "Rabbit", names: ["垂耳兔的书页", "肉桂兔的手账", "安哥拉兔的午后", "荷兰兔的阅读时光", "兔兔写日记"])
        + make(.cat, prefix: "Cat", names: ["缅因猫的书页", "英短的珍藏", "布偶猫的午后", "橘猫的阅读时光", "奶牛猫写日记"])
        + make(.together, prefix: "Pair", names: ["相伴读书", "一起做计划", "柔软的午后", "贴贴读书", "画下今天", "共度好时光", "书页间的小憩", "把日子收藏", "共享一本书", "写给明天"])
    private static func make(_ kind: Kind, prefix: String, names: [String]) -> [Self] {
        names.enumerated().map { index, name in
            Self(id: prefix.lowercased() + String(format: "-%02d", index + 1), title: name, kind: kind,
                 asset: "CountdownArt" + prefix + String(format: "%02d", index + 1))
        }
    }
    static var preferred: Self {
        all.first { $0.id == UserDefaults.standard.string(forKey: "countdownShareArtwork") } ?? original
    }
    func remember() { UserDefaults.standard.set(id, forKey: "countdownShareArtwork") }
}

struct CountdownArtworkPicker: View {
    let selected: CountdownArtwork
    let choose: (CountdownArtwork) -> Void
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        NavigationStack {
            ZStack { PaperBackground(); ScrollView {
                VStack(spacing: 20) {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 130), spacing: 12)], spacing: 16) {
                        ForEach(CountdownArtwork.all) { art in
                            Button { choose(art); dismiss() } label: {
                                VStack(spacing: 8) {
                                    Image(art.asset).resizable().scaledToFit().frame(height: 105)
                                    HStack(spacing: 4) {
                                        Text(art.title).font(.caption).lineLimit(2)
                                        if selected == art { Image(systemName: "checkmark.circle.fill").foregroundStyle(Notebook.accent) }
                                    }.frame(minHeight: 32)
                                }.padding(10).frame(maxWidth: .infinity)
                                    .background(selected == art ? Notebook.accent.opacity(0.08) : Notebook.paper)
                                    .overlay(PencilBorder().stroke(selected == art ? Notebook.accent : Notebook.ink.opacity(0.2), lineWidth: selected == art ? 2 : 1))
                                    .contentShape(Rectangle())
                            }.buttonStyle(.plain).accessibilityIdentifier("countdownArt-" + art.id)
                                .accessibilityAddTraits(selected == art ? .isSelected : [])
                        }
                    }
                }.padding(20).frame(maxWidth: 700).frame(maxWidth: .infinity)
            } }.foregroundStyle(Notebook.ink).navigationTitle("挑一张喜欢的插画").navigationBarTitleDisplayMode(.inline)
                .toolbar { ToolbarItem(placement: .confirmationAction) { Button("完成") { dismiss() } } }
        }.tint(Notebook.accent)
    }
}
