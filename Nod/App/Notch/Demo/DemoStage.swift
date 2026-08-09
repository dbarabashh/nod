import AppKit
import Foundation

/// One frame of the scripted demo: everything the notch shows at a given
/// moment, with no live data behind any of it.
///
/// The demo exists to be screen-recorded for the landing page, so it is fully
/// deterministic — no transcription, no network, no clock but its own. Each
/// stage is a value; the director hands them to `NotchModel` on a timeline and
/// the notch renders them through the same silhouette, springs and fold-between
/// transitions as the real surface.
enum DemoStage: Equatable {
    /// The first card, and the only one that arrives unasked: the assistant
    /// saying it has already started rather than reporting a detection.
    case opening
    /// Resting: the elapsed clock and a waveform, with a word for what Nod is
    /// doing. The state the demo returns to between cards.
    case listening(String)
    /// A line of what was just said, shown briefly and then gone.
    case transcript(String)
    /// Nod is looking something up.
    case searching(String)
    /// What it found, in the tools the team already uses.
    case context(DemoContext)
    /// The proactive find — the demo's strongest moment.
    case insight(DemoInsight)
    /// Nod acknowledging a spoken decision before acting on it.
    case acknowledgement(String)
    /// Several integrations running at once, each row loading then done.
    case workflow(DemoWorkflow)
    /// Everything that ended up being created.
    case workflowResult(DemoWorkflowResult)
    /// Context assembled for the *next* meeting, unprompted.
    case brief(DemoBrief)
    /// The meeting is over.
    case ended
    /// The recap, scrollable, available immediately.
    case summary(DemoSummary)

    /// How this stage sits in the notch, which decides whether moving to it
    /// folds the surface shut on the way.
    ///
    /// Only card→card folds. Two transcript lines in a row must not — a fold
    /// between every spoken line reads as a stutter, not as the notch thinking.
    enum Form {
        /// The bare resting surface.
        case resting
        /// A single line, wider than resting but not a card.
        case line
        /// A full card.
        case card
    }

    var form: Form {
        switch self {
        case .opening: .card
        case .listening: .resting
        case .transcript, .searching, .acknowledgement, .ended: .line
        case .context, .insight, .workflow, .workflowResult, .brief, .summary: .card
        }
    }

    /// Identity for SwiftUI's transition machinery — two different lines have to
    /// count as different content, or the second replaces the first in place
    /// with no animation at all.
    var contentID: String {
        switch self {
        case .opening: "demo.opening"
        case let .listening(label): "demo.listening.\(label)"
        case let .transcript(line): "demo.transcript.\(line.prefix(24))"
        case let .searching(label): "demo.searching.\(label)"
        case .context: "demo.context"
        case .insight: "demo.insight"
        case let .acknowledgement(line): "demo.ack.\(line.prefix(24))"
        case let .workflow(workflow): "demo.workflow.\(workflow.revision)"
        case .workflowResult: "demo.workflowResult"
        case .brief: "demo.brief"
        case .ended: "demo.ended"
        case .summary: "demo.summary"
        }
    }

    /// How wide each half of the resting bar has to be, measured rather than
    /// guessed.
    ///
    /// The bar is symmetric around the cut-out — both halves are
    /// `maxWidth: .infinity` — so the surface must fit twice the wider one, and
    /// the label is always the wider one. It was a hardcoded number, and the
    /// number was too small: `.fixedSize()` on the label means it never
    /// truncates, it simply keeps drawing, and the tail of "Following along…"
    /// ran underneath the hardware where nobody could read it. Nothing warns
    /// about that, which is exactly why this is computed from the string.
    var restingSideWidth: CGFloat {
        guard case let .listening(label) = self else { return 0 }
        let text = Self.width(of: label, size: 11, weight: .medium)
        return max(DemoWaveform.intrinsicWidth + DemoRestingBar.gap + text, Self.restingClockWidth)
    }

    /// The other half. Both are `maxWidth: .infinity`, so a label short enough
    /// to be narrower than the clock must not shrink the surface out from under
    /// it.
    static let restingClockWidth = width(of: "00:00", size: 13, weight: .semibold, monospaced: true)

    private static func width(
        of text: String,
        size: CGFloat,
        weight: NSFont.Weight,
        monospaced: Bool = false
    ) -> CGFloat {
        let font = monospaced
            ? NSFont.monospacedDigitSystemFont(ofSize: size, weight: weight)
            : NSFont.systemFont(ofSize: size, weight: weight)
        return (text as NSString).size(withAttributes: [.font: font]).width.rounded(.up)
    }

    var surfaceWidth: CGFloat {
        switch self {
        case .opening: 300
        case .listening: 0
        case .transcript, .acknowledgement: 420
        case .searching, .ended: 320
        case .context: 400
        case .insight: 420
        case .workflow, .workflowResult: 420
        case .brief: 420
        case .summary: 440
        }
    }
}

// MARK: - Payloads

/// Something already written down somewhere the team works.
struct DemoSource: Equatable, Identifiable {
    let tool: DemoTool
    /// The reference itself — a ticket key, a channel name, a document title.
    let reference: String
    let detail: String
    /// Optional status chip, e.g. a Jira workflow state.
    var status: String?

    var id: String {
        "\(tool.rawValue).\(reference)"
    }
}

struct DemoContext: Equatable {
    let lead: String
    let sources: [DemoSource]
    let actions: [String]
}

struct DemoInsight: Equatable {
    let title: String
    let explanation: String
    /// Counted evidence, most convincing first.
    let evidence: [DemoEvidence]
    let quote: String
    let action: String
}

struct DemoEvidence: Equatable, Identifiable {
    let tool: DemoTool
    let label: String

    var id: String {
        "\(tool.rawValue).\(label)"
    }
}

/// One integration doing one job, with the two states it moves through.
struct DemoWorkflowStep: Equatable, Identifiable {
    let tool: DemoTool
    /// What it says while working. More than one when the step visibly
    /// progresses ("Finding time" → "Checking availability").
    let progress: [String]
    let completed: String
    let details: [String]
    /// Which progress line is showing, or nil once the step is done.
    var progressIndex: Int?

    var id: String {
        tool.rawValue
    }

    var isDone: Bool {
        progressIndex == nil
    }

    var currentLabel: String {
        guard let progressIndex, progress.indices.contains(progressIndex) else {
            return completed
        }
        return progress[progressIndex]
    }
}

struct DemoWorkflow: Equatable {
    let title: String
    var steps: [DemoWorkflowStep]
    /// Bumped whenever a step advances, so the view's identity changes and the
    /// row animates rather than swapping its text silently.
    var revision: Int = 0
}

struct DemoWorkflowResult: Equatable {
    let title: String
    let outcomes: [DemoOutcome]
    let confirmations: [String]
    let actions: [String]
}

struct DemoOutcome: Equatable, Identifiable {
    let tool: DemoTool
    let headline: String
    let detail: String

    var id: String {
        "\(tool.rawValue).\(headline)"
    }
}

struct DemoBrief: Equatable {
    let title: String
    let explanation: String
    let attachments: [DemoEvidence]
    let action: String
}

struct DemoSummary: Equatable {
    /// "Hey Maya — here's where onboarding landed." Addressed to the viewer,
    /// the same way a real recap greets whoever it's for
    /// (`NotchOffer.title`'s "Hey \(userName)") — the four scripts each name a
    /// different fictional viewer so a person who watches more than one story
    /// doesn't read the same name twice.
    let greeting: String
    let title: String
    let overview: String
    let keyInsight: String
    let decisions: [String]
    let actionItems: [String]
    let completed: [String]
    let event: DemoEvent
}

struct DemoEvent: Equatable {
    let title: String
    let when: String
    let attendees: [String]
    let attachments: [String]
    let status: String
}
