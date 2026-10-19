import SwiftUI

/// A stable viewport inside the review's navigation stack. Changing the page resets form state
/// and scroll position without replacing the sheet or its navigation bar.
struct ReviewPageContainer<Content: View>: View {
    let pageID: String
    @ViewBuilder var content: Content
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var turningPage: String?

    var body: some View {
        ZStack(alignment: .top) {
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                .id(pageID)
                .transition(reduceMotion ? .opacity : .asymmetric(insertion: .move(edge: .trailing), removal: .move(edge: .leading)))
        }
        .clipped()
        .disabled(turningPage != nil)
        .animation(.easeInOut(duration: reduceMotion ? 0.15 : 0.3), value: pageID)
        .onChange(of: pageID) { _, new in turningPage = new }
        .task(id: turningPage) {
            guard let turningPage else { return }
            do {
                try await Task.sleep(for: .milliseconds(reduceMotion ? 150 : 300))
                try Task.checkCancellation()
                if self.turningPage == turningPage { self.turningPage = nil }
            } catch { }
        }
    }
}
