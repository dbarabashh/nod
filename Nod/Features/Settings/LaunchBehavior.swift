import Combine
import Foundation

/// What Nod puts on screen when it starts.
///
/// The default is the main window and nothing else: opening the app is not the
/// same as asking to capture, and a floating panel that arrives on its own —
/// over whatever the user was already doing — reads as "I've already started",
/// which is exactly the thing Nod must never imply.
@MainActor
final class LaunchBehavior: ObservableObject {
    enum Mode: String, CaseIterable, Identifiable {
        case mainWindow
        case capturePanel
        case menuBarOnly

        var id: String {
            rawValue
        }

        var title: String {
            switch self {
            case .mainWindow: "Open the main window"
            case .capturePanel: "Show the capture panel"
            case .menuBarOnly: "Stay in the menu bar"
            }
        }

        var detail: String {
            switch self {
            case .mainWindow: "What needs you, and everything you've captured."
            case .capturePanel: "The floating panel, ready to record."
            case .menuBarOnly: "Nothing on screen until you ask — hotkey or menu bar."
            }
        }
    }

    private static let key = "app.launchBehavior"

    @Published var mode: Mode {
        didSet { UserDefaults.standard.set(mode.rawValue, forKey: Self.key) }
    }

    init() {
        let stored = UserDefaults.standard.string(forKey: Self.key)
        mode = stored.flatMap(Mode.init(rawValue:)) ?? .mainWindow
    }
}
