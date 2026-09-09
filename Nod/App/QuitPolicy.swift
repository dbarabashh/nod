import Foundation

/// What ⌘Q and Quit mean for a background companion.
///
/// ⌘Q on a Mac app is "go away"; on Nod it used to be "stop listening to my
/// meeting and lose the recap", which nobody pressing it by habit meant. So
/// the shortcut hides every surface and leaves the process where it was, and
/// quitting is its own, named act — one that still refuses to drop a
/// recording on the floor.
enum QuitPolicy {
    enum Decision: Equatable {
        /// Nothing in flight: quit now.
        case terminate
        /// A session is recording: ask, and only end it on a yes.
        case askToEndRecording
    }

    static func decision(meeting: MeetingState) -> Decision {
        meeting == .idle ? .terminate : .askToEndRecording
    }

    /// How long the end-of-meeting flow gets to land the transcript in the
    /// outbox before the process leaves. The WAL is written as the session
    /// runs; this covers the last flush, not the summary — which the next
    /// launch recovers from the same outbox.
    static let endGraceSeconds: TimeInterval = 3
}
