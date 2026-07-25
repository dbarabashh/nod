import Combine
import Foundation

/// Which Settings pane a deep link (post-checkout return, an upsell button, the
/// menu-bar item) wants open.
///
/// Settings lives inside the main window now, so the request has to survive the
/// gap between "show the window" and "the pane mounts" — a notification posted
/// before the view exists is delivered to nobody. The request is held here until
/// the pane consumes it.
@MainActor
final class SettingsFocus: ObservableObject {
    enum Pane: String {
        case profile
        case subscription
        case modes
        case privacy
    }

    /// Carries an id so asking twice for the same pane is still two requests.
    struct Request: Equatable {
        let pane: Pane
        let id: UUID
    }

    @Published private(set) var request: Request?

    func open(_ pane: Pane) {
        request = Request(pane: pane, id: UUID())
    }

    /// Takes the pending pane, if any, and clears it, so a later visit isn't
    /// dragged back to the last deep link's pane.
    func consume() -> Pane? {
        defer { request = nil }
        return request?.pane
    }
}
