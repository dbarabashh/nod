import AppKit
import Combine

/// Which theme Nod paints in.
///
/// The companion transparency switch is not held here — see
/// `AppearanceDefaults` for why it travels as a defaults key instead.
@MainActor
final class AppearancePreference: ObservableObject {
    /// The system option is not "dark by default" — it follows the Mac, which
    /// is what a user who never opens this setting expects.
    enum Mode: String, CaseIterable {
        case system
        case light
        case dark

        var title: String {
            switch self {
            case .system: "System"
            case .light: "Light"
            case .dark: "Dark"
            }
        }

        var detail: String {
            switch self {
            case .system: "Follows your Mac's Light or Dark setting."
            case .light: "Always light, whatever your Mac is set to."
            case .dark: "Always dark, whatever your Mac is set to."
            }
        }

        /// nil means "inherit" — the appearance AppKit resolves from System
        /// Settings, which is exactly what `.system` wants.
        var appearance: NSAppearance? {
            switch self {
            case .system: nil
            case .light: NSAppearance(named: .aqua)
            case .dark: NSAppearance(named: .darkAqua)
            }
        }
    }

    @Published var mode: Mode {
        didSet {
            guard mode != oldValue else { return }
            defaults.set(mode.rawValue, forKey: AppearanceDefaults.modeKey)
            apply()
        }
    }

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        let stored = defaults.string(forKey: AppearanceDefaults.modeKey)
        mode = stored.flatMap(Mode.init(rawValue:)) ?? .system
    }

    /// Applied to `NSApp` rather than window by window: every window Nod opens
    /// inherits from the application unless it deliberately pins its own, so
    /// one assignment retints the whole app including sheets and menus.
    func apply() {
        NSApp.appearance = mode.appearance
    }
}
