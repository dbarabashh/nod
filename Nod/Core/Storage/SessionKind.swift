import Foundation

/// What a recording actually is. Drives audio-stream selection and the recap
/// framing — passive `media` produces no personal to-dos (see
/// `extractsActionItems`), and a podcast has no [Me] side to suggest replies for.
///
/// Stored in the `meetings.kind` column (`20260602120100_add_meeting_kind.sql`)
/// as the raw string. `meeting` is the default for every legacy row.
enum SessionKind: String, Codable, CaseIterable, Identifiable {
    case meeting
    case voiceNote = "voice_note"
    case media

    var id: String {
        rawValue
    }

    /// Capture the user's own microphone. Off for `media` — the user is
    /// listening, not speaking.
    var capturesMic: Bool {
        self != .media
    }

    /// Capture system audio (the other side of a call, or media playback).
    /// Off for `voiceNote` — a solo memo has no second source.
    var capturesSystem: Bool {
        self != .voiceNote
    }

    /// Meeting-only live cards (Suggest reply / follow-up) assume a dialogue
    /// with a [Me] side to coach. Hidden for the listen-only kinds.
    var supportsReplyCoaching: Bool {
        self == .meeting
    }

    /// Whether the recap should be mined for first-class to-dos. A meeting or a
    /// voice note carries the user's own commitments ("call the bank", "ship the
    /// fix"); `media` is passive listening — a podcast/video has no personal
    /// action the user spoke out loud, so it produces no checklist.
    var extractsActionItems: Bool {
        self != .media
    }

    var title: String {
        switch self {
        case .meeting: "Meeting"
        case .voiceNote: "Voice note"
        case .media: "Media"
        }
    }

    /// Start-button label. Kept separate from `title` because the generic
    /// "Start <title>" template breaks for `media` — the user isn't starting
    /// media, they're capturing audio that's already playing.
    var startActionTitle: String {
        switch self {
        case .meeting: "Start meeting"
        case .voiceNote: "Start voice note"
        case .media: "Capture media"
        }
    }

    /// Status word shown in the panel header while capturing — framed as what
    /// Nod is doing for the user, varying by what's actually captured so it
    /// never reads as a stark "recording them" light.
    var activeStatusLabel: String {
        switch self {
        case .meeting: "Listening"
        case .voiceNote: "Noting"
        case .media: "Transcribing"
        }
    }

    var icon: String {
        switch self {
        case .meeting: "person.2.fill"
        case .voiceNote: "mic.fill"
        case .media: "play.rectangle.fill"
        }
    }
}
