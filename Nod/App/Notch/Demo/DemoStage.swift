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

    var surfaceWidth: CGFloat {
        switch self {
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
    /// progresses ("Finding time…" → "Checking availability…").
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
