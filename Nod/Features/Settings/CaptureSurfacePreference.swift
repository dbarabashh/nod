import AppKit
import Combine

/// Which shape the capture surface takes, and — for the free-standing one —
/// where the user last left it.
///
/// The two surfaces were always in the code (see `NotchGeometry`), but which one
/// you got was decided by your hardware: a cut-out meant the notch shape, no
/// cut-out meant the pill. That is right as a *default* and wrong as a rule —
/// plenty of people on a notched Mac would rather have a card they can put
/// where they want than a shape welded to the bezel.
///
/// `.notch` is therefore "use the cut-out when this display has one", not "there
/// is a cut-out": on an external display it still resolves to the pill, because
/// there is nothing else it could be.
@MainActor
final class CaptureSurfacePreference: ObservableObject {
    enum Surface: String, CaseIterable, Identifiable {
        case notch
        case floatingPanel

        var id: String {
            rawValue
        }

        var title: String {
            switch self {
            case .notch: "Notch"
            case .floatingPanel: "Floating panel"
            }
        }

        var detail: String {
            switch self {
            case .notch: "Hangs from the cut-out and fills dead space. External displays show the panel either way."
            case .floatingPanel: "A card you can drag anywhere. Nod remembers where you left it on each display."
            }
        }

        /// Whether the surface may be dragged. Only the free-standing one: the
        /// notch shape is a continuation of the bezel, and a bezel that has been
        /// dragged into the middle of the screen is just a bug with a shadow.
        var isMovable: Bool {
            self == .floatingPanel
        }
    }

    @Published var surface: Surface {
        didSet {
            guard surface != oldValue else { return }
            defaults.set(surface.rawValue, forKey: Self.surfaceKey)
        }
    }

    private let defaults: UserDefaults
    private static let surfaceKey = "capture.surface"
    private static let originsKey = "capture.panelOrigins"

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        let stored = defaults.string(forKey: Self.surfaceKey)
        surface = stored.flatMap(Surface.init(rawValue:)) ?? .notch
    }

    // MARK: - Remembered position

    /// Keyed by display rather than saved as one frame: an external monitor and
    /// the built-in screen are different places to work, and a position that
    /// made sense on one is usually wrong on the other. A display we have never
    /// seen answers nil and gets the default placement.
    func savedOrigin(forDisplay id: CGDirectDisplayID) -> CGPoint? {
        guard let pair = origins()[String(id)], pair.count == 2 else { return nil }
        return CGPoint(x: pair[0], y: pair[1])
    }

    func saveOrigin(_ origin: CGPoint, forDisplay id: CGDirectDisplayID) {
        var all = origins()
        all[String(id)] = [origin.x, origin.y]
        defaults.set(all, forKey: Self.originsKey)
    }

    private func origins() -> [String: [CGFloat]] {
        (defaults.dictionary(forKey: Self.originsKey) as? [String: [CGFloat]]) ?? [:]
    }
}

extension NSScreen {
    /// The display this screen renders on, for keying a remembered position.
    /// Screens have no stable identity of their own across reconnects; the
    /// display id is the closest thing AppKit offers.
    var nodDisplayID: CGDirectDisplayID? {
        deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID
    }
}
