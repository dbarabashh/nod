import Foundation

/// A reusable, user-named bundle of meeting framing — the "mode" the user picks
/// in the panel when starting a *meeting*, instead of opening Settings to
/// coordinate the recap layout and reply framing by hand each time.
///
/// Modes apply to meetings only. A voice note (talking to yourself) or a media
/// capture (transcribing a lecture) has no recap/reply framing to choose, so
/// they aren't modes — the panel's recording-type picker owns that axis. A mode
/// bundles the recap layout (`SummaryTemplate`), the suggest-reply framing
/// (`ReplyContext`), and a free-text `focus`. The active mode is resolved into a
/// `MeetingFraming` at generation time (see `MeetingSession`); the `focus` is
/// injected as a `[MEETING FOCUS]` block in the meeting prompts.
struct MeetingMode: Identifiable, Codable, Equatable {
    let id: UUID
    var name: String
    var icon: String
    var summary: SummaryTemplate
    var reply: ReplyContext
    var focus: String

    init(
        id: UUID = UUID(),
        name: String,
        icon: String,
        summary: SummaryTemplate,
        reply: ReplyContext,
        focus: String = ""
    ) {
        self.id = id
        self.name = name
        self.icon = icon
        self.summary = summary
        self.reply = reply
        self.focus = focus
    }
}

/// The recap layout, reply framing, and focus applied to one generation —
/// resolved from the active mode, but neutralized for non-meeting recordings
/// since modes are meeting-only. Centralizing the kind gating here means a new
/// `SessionKind` or a new generation call site can't silently inherit the last
/// meeting mode: every consumer asks `MeetingFraming.active(for:mode:)`.
struct MeetingFraming {
    let summary: SummaryTemplate
    let reply: ReplyContext
    let focus: String

    static let neutral = MeetingFraming(summary: .auto, reply: .auto, focus: "")

    static func active(for kind: SessionKind, mode: MeetingMode) -> MeetingFraming {
        guard kind == .meeting else { return .neutral }
        return MeetingFraming(summary: mode.summary, reply: mode.reply, focus: mode.focus)
    }
}

extension MeetingMode {
    /// Used only as a non-optional fallback for `ModeStore.selected` so the
    /// store never force-unwraps; in practice the seeded presets are non-empty.
    static let fallback = MeetingMode(
        name: "General",
        icon: "circle.grid.2x2",
        summary: .auto,
        reply: .auto
    )

    /// The modes a fresh install starts with — one neutral default plus the
    /// meeting shapes the recap/reply enums already special-case.
    static let presets: [MeetingMode] = [
        MeetingMode(name: "General", icon: "circle.grid.2x2", summary: .auto, reply: .auto),
        MeetingMode(
            name: "Interview",
            icon: "person.crop.rectangle.stack",
            summary: .interview,
            reply: .interview,
            focus: "Senior backend candidate. Probe system-design depth, ownership, and how they handle ambiguity. Flag anything that suggests they oversell."
        ),
        MeetingMode(name: "Sales call", icon: "chart.line.uptrend.xyaxis", summary: .salesCall, reply: .salesCall),
        MeetingMode(name: "1:1", icon: "bubble.left.and.bubble.right", summary: .oneOnOne, reply: .oneOnOne),
        MeetingMode(name: "Standup", icon: "checklist", summary: .standup, reply: .meeting)
    ]
}
