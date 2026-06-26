import AppKit
import Combine

/// Whether the floating panel is included in screen shares and recordings.
/// Off by default so Nod stays out of what the user shares; opt-in for
/// presenting or recording with the panel on screen.
@MainActor
final class PanelSharingPreference: ObservableObject {
    private static let key = "panel.visibleWhenSharing"

    @Published var visibleWhenSharing: Bool {
        didSet { UserDefaults.standard.set(visibleWhenSharing, forKey: Self.key) }
    }

    init() {
        visibleWhenSharing = UserDefaults.standard.bool(forKey: Self.key)
    }

    var sharingType: NSWindow.SharingType {
        visibleWhenSharing ? .readOnly : .none
    }
}
