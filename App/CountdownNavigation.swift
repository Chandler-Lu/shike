import Foundation
import Combine
import ShikeCore

@MainActor final class CountdownNavigation: ObservableObject {
    @Published var pending: CountdownRoute?
    func open(_ url: URL) { if let route = CountdownRoute(url: url) { pending = route } }
}
