import Foundation

/// One scheduled change, at an absolute offset from the moment the demo starts.
struct DemoBeat {
    let at: TimeInterval
    let action: Action

    enum Action {
        case stage(DemoStage)
        /// Move a running workflow row to its next progress line.
        case advance(DemoTool)
        /// Mark a running workflow row finished.
        case complete(DemoTool)
    }
}

/// The four scripted stories. They share one structure — existing context
/// found, a proactive insight, a multi-tool workflow, a calendar follow-up, an
/// immediate summary — so a viewer who has seen one can read any of the others
/// at a glance. Only the content differs.
/// Whether Start plays a scripted story instead of opening a microphone, which
/// story it tells, and how fast.
///
/// Its own settings rather than the existing `DemoMode` flag: that one is
/// DEBUG-only and fills the app with canned history, which is a different job.
/// This has to work in whatever build gets screen-recorded, and it has to name a
/// scenario — four presets are useless behind a boolean.
@MainActor
final class DemoPlayback: ObservableObject {
    @Published var isEnabled: Bool {
        didSet { defaults.set(isEnabled, forKey: Self.enabledKey) }
    }

    @Published var scenario: DemoScenario {
        didSet { defaults.set(scenario.rawValue, forKey: Self.scenarioKey) }
    }

    /// Stretches or compresses the whole timeline. The scripted offsets are
    /// tuned for reading, but "long enough to read" depends on the viewer and on
    /// whether the recording will carry a voice-over — so it is a dial rather
    /// than a number baked into every beat.
    @Published var pace: Double {
        didSet { defaults.set(pace, forKey: Self.paceKey) }
    }

    /// Draw the surface as though this screen had no cut-out.
    ///
    /// Every external display is already this case, and so is any Mac older than
    /// the notch — but checking it otherwise means unplugging a monitor or
    /// dragging the menu bar between screens. This shows the same fallback on
    /// the built-in display.
    @Published var previewWithoutNotch: Bool {
        didSet { defaults.set(previewWithoutNotch, forKey: Self.previewKey) }
    }

    static let enabledKey = "demo.script.enabled"
    static let scenarioKey = "demo.script.scenario"
    static let paceKey = "demo.script.pace"
    static let previewKey = "notch.previewWithoutNotch"

    /// Sensible ends of the dial: below this the cards can't be read, above it
    /// the recording outstays a landing page's attention.
    static let paceRange: ClosedRange<Double> = 0.7 ... 1.6

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        isEnabled = defaults.bool(forKey: Self.enabledKey)
        scenario = defaults.string(forKey: Self.scenarioKey)
            .flatMap(DemoScenario.init(rawValue:)) ?? .productEngineering
        pace = defaults.object(forKey: Self.paceKey) as? Double ?? 1.0
        previewWithoutNotch = defaults.bool(forKey: Self.previewKey)
    }

    /// The scenario to play, or nil when Start should open a real microphone.
    var armed: DemoScenario? {
        isEnabled ? scenario : nil
    }
}

enum DemoScenario: String, CaseIterable, Identifiable {
    case productEngineering
    case recruiting
    case sales
    case management

    var id: String {
        rawValue
    }

    var displayName: String {
        switch self {
        case .productEngineering: "Product & Engineering"
        case .recruiting: "Recruiting"
        case .sales: "Sales"
        case .management: "Management"
        }
    }

    /// Where the demo's clock starts. A meeting already well under way, so the
    /// recording opens mid-conversation rather than on an empty state.
    var startingElapsed: Int {
        35 * 60 + 12
    }

    /// The last beat's offset, plus the tail the summary needs to be read.
    var duration: TimeInterval {
        59
    }

    /// Every scenario opens the same way — the assistant speaking first, before
    /// a word has been said. Written once so the four scripts cannot drift on
    /// the one beat that carries the product's whole claim.
    static let openingBeats: [DemoBeat] = [
        .init(at: 0, action: .stage(.opening)),
        .init(at: 1.6, action: .stage(.listening("Following along")))
    ]

    var beats: [DemoBeat] {
        Self.openingBeats + scenarioBeats
    }

    private var scenarioBeats: [DemoBeat] {
        switch self {
        case .productEngineering: Self.productEngineeringBeats
        case .recruiting: Self.recruitingBeats
        case .sales: Self.salesBeats
        case .management: Self.managementBeats
        }
    }
}
