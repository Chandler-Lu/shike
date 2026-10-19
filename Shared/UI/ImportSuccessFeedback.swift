import SwiftUI
import UIKit

// The page owns each success event; the footer reports its bounds and draws the sweep.
struct ImportSuccessHighlightState {
    private(set) var pending: ImportSaveSuccess?
    private(set) var playing: ImportSaveSuccess?
    private var lastStartedID: UUID?

    mutating func queue(_ success: ImportSaveSuccess) {
        guard success.id != lastStartedID else { return }
        pending = success
        playing = nil
    }

    mutating func begin(frame: CGRect, viewport: CGRect) {
        guard let pending, Self.isVisible(frame, in: viewport) else { return }
        playing = pending
        lastStartedID = pending.id
        self.pending = nil
    }

    mutating func stop() { playing = nil }
    mutating func clear() { pending = nil; playing = nil }

    static func isVisible(_ frame: CGRect, in viewport: CGRect) -> Bool {
        guard !frame.isEmpty, !viewport.isEmpty else { return false }
        // The footer text is already readable when its bottom padding reaches the safe area.
        let intersection = frame.intersection(viewport)
        return !intersection.isNull
            && intersection.width >= min(frame.width, viewport.width) * 0.8
            && intersection.height >= min(frame.height, viewport.height) * 0.7
    }
}

private struct ImportSuccessPlaybackKey: EnvironmentKey {
    static let defaultValue: ImportSaveSuccess? = nil
}
private extension EnvironmentValues {
    var importSuccessPlayback: ImportSaveSuccess? {
        get { self[ImportSuccessPlaybackKey.self] }
        set { self[ImportSuccessPlaybackKey.self] = newValue }
    }
}
private struct ImportSuccessBounds: PreferenceKey {
    static let defaultValue: CGRect = .zero
    static func reduce(value: inout CGRect, nextValue: () -> CGRect) {
        let next = nextValue()
        if !next.isEmpty { value = next }
    }
}

extension View {
    func importSuccessFeedback(_ controller: ImportController, planning: Bool = false) -> some View {
        modifier(ImportSuccessFeedback(controller: controller, planning: planning))
    }
    func importSuccessHighlight() -> some View {
        modifier(ImportSuccessHighlight())
    }
}

private struct ImportSuccessFeedback: ViewModifier {
    @ObservedObject var controller: ImportController
    let planning: Bool
    @Environment(\.accessibilityVoiceOverEnabled) private var voiceOver
    @Environment(\.scenePhase) private var scenePhase
    @State private var visible = false
    @State private var highlight = ImportSuccessHighlightState()
    @State private var bounds: CGRect = .zero
    @State private var viewport: CGRect = .zero

    private var ownsFeedback: Bool { controller.showsPlanning == planning }
    private var reviewing: Bool {
        controller.reviewSheetPresented || controller.review != nil || controller.countdownReview != nil
    }
    private var ready: Bool { visible && ownsFeedback && !reviewing && !controller.isBusy && scenePhase == .active }

    func body(content: Content) -> some View {
        content
            .environment(\.importSuccessPlayback, highlight.playing)
            // Measure this viewport directly; sibling preference defaults must not erase it.
            .onGeometryChange(for: CGRect.self) { geometry in
                geometry.frame(in: .global)
            } action: { frame in
                viewport = frame
                beginIfReady()
            }
            .onPreferenceChange(ImportSuccessBounds.self) { bounds = $0; beginIfReady() }
            .onAppear { visible = true; beginIfReady() }
            .onDisappear {
                visible = false
                highlight.stop()
                if !reviewing { highlight.clear() }
            }
            // Never replay an old event when returning to a page or opening a saved record.
            .onChange(of: controller.saveSuccess) { _, success in
                guard let success else { highlight.clear(); return }
                guard ownsFeedback, visible || reviewing, scenePhase == .active,
                      success.sessionID == controller.session.id else { return }
                highlight.queue(success)
                beginIfReady()
            }
            .onChange(of: ready) { _, ready in
                if ready { beginIfReady() } else { highlight.stop() }
            }
            .onChange(of: ownsFeedback) { _, owns in if !owns { highlight.clear() } }
            .onChange(of: controller.session.id) { _, _ in highlight.clear() }
            .onChange(of: scenePhase) { _, phase in if phase != .active { highlight.clear() } }
            .task(id: highlight.playing?.id) {
                guard let playback = highlight.playing else { return }
                if voiceOver { UIAccessibility.post(notification: .announcement, argument: playback.title) }
                do {
                    try await Task.sleep(for: .milliseconds(850))
                    try Task.checkCancellation()
                    if highlight.playing?.id == playback.id { highlight.stop() }
                } catch { }
            }
    }

    private func beginIfReady() {
        guard ready, highlight.pending?.sessionID == controller.session.id else { return }
        highlight.begin(frame: bounds, viewport: viewport)
    }
}

private struct ImportSuccessHighlight: ViewModifier {
    @Environment(\.importSuccessPlayback) private var playback

    func body(content: Content) -> some View {
        content
            .background {
                GeometryReader { geometry in
                    Color.clear.preference(key: ImportSuccessBounds.self, value: geometry.frame(in: .global))
                }
            }
            .background {
                if let playback {
                    ImportSuccessSweep().id(playback.id)
                        .clipShape(RoundedRectangle(cornerRadius: 13))
                        .allowsHitTesting(false).accessibilityHidden(true)
                }
            }
    }
}

private struct ImportSuccessSweep: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorScheme) private var colorScheme
    @State private var progress: CGFloat = 0

    var body: some View {
        GeometryReader { geometry in
            if reduceMotion {
                Notebook.yellow.opacity((colorScheme == .dark ? 0.18 : 0.25) * Double(progress))
            } else {
                let width = geometry.size.width * 0.55
                LinearGradient(colors: [.clear, Notebook.yellow.opacity(colorScheme == .dark ? 0.40 : 0.60), .white.opacity(0.22), .clear],
                               startPoint: .leading, endPoint: .trailing)
                    .frame(width: width)
                    .offset(x: -width + (geometry.size.width + width) * progress)
            }
        }
        .task {
            // Give the initial offscreen position a frame before starting the animation.
            do { try await Task.sleep(for: .milliseconds(20)) } catch { return }
            if reduceMotion {
                withAnimation(.easeIn(duration: 0.2)) { progress = 1 }
                do { try await Task.sleep(for: .milliseconds(600)) } catch { return }
                withAnimation(.easeOut(duration: 0.2)) { progress = 0 }
            } else {
                withAnimation(.easeInOut(duration: 0.8)) { progress = 1 }
            }
        }
    }
}
