import Combine
import Foundation

/// How eagerly `LiveMeetingAnalyst` surfaces what it hears — from a few
/// high-conviction interruptions an hour to reading as often as it usefully
/// can. Replaces what used to be three numbers hardcoded into the analyst;
/// see `Level` for what each step actually changes.
@MainActor
final class ProactivityPreference: ObservableObject {
    enum Level: Int, CaseIterable, Identifiable {
        case minimal
        case balanced
        case frequent
        case maximum

        var id: Int {
            rawValue
        }

        var title: String {
            switch self {
            case .minimal: "Minimal"
            case .balanced: "Balanced"
            case .frequent: "Frequent"
            case .maximum: "Maximum"
            }
        }

        var detail: String {
            switch self {
            case .minimal: "A couple of high-confidence nudges an hour — everything else still reaches the recap."
            case .balanced: "Nod's default pace — a task or decision worth naming, without narrating the whole call."
            case .frequent: "Checks in more often and needs less new speech before it does."
            case .maximum: "Reads as often as it usefully can — the freshest notices, the most interruptions."
            }
        }

        /// The floor between live passes, in seconds. A pass that reads too
        /// soon after the last one is spend for nothing — it is mostly
        /// re-reading what the previous one already saw.
        var minInterval: TimeInterval {
            switch self {
            case .minimal: 90
            case .balanced: 40
            case .frequent: 25
            case .maximum: 15
            }
        }

        /// How much new speech has to land before a pass is worth paying
        /// for. Below this the window is mostly old material.
        var minNewLines: Int {
            switch self {
            case .minimal: 14
            case .balanced: 8
            case .frequent: 6
            case .maximum: 4
            }
        }

        /// The quiet stretch after a notice, before another may interrupt.
        /// The lever a user actually feels day to day — `minInterval` and
        /// `minNewLines` only change how fresh a notice is when one does
        /// land, not how often one reaches the screen.
        var noticeCooldown: TimeInterval {
            switch self {
            case .minimal: 25 * 60
            case .balanced: 3 * 60
            case .frequent: 60
            case .maximum: 20
            }
        }
    }

    private static let key = "live.proactivityLevel"

    /// `.balanced` reproduces the app's pre-existing hardcoded cadence
    /// exactly, so installing this setting doesn't change anyone's meeting
    /// mid-flight — only picking a different level does.
    @Published var level: Level {
        didSet { UserDefaults.standard.set(level.rawValue, forKey: Self.key) }
    }

    init() {
        let stored = UserDefaults.standard.object(forKey: Self.key) as? Int
        level = stored.flatMap(Level.init(rawValue:)) ?? .balanced
    }
}
