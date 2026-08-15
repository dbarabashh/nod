import Foundation

/// Re-reads the conferencing app's participant list off the main actor for as
/// long as a recording runs, accumulating what it finds.
///
/// Purely additive: no roster at all simply means diarization falls back to its
/// distance threshold.
@MainActor
final class MeetingRosterSampler {
    /// How often the participant list is re-read while recording.
    ///
    /// Sampling once at the start read the roster at the worst possible moment:
    /// recording begins as people are still joining and before anyone has opened
    /// the participant panel, so a five-person call routinely produced no count
    /// at all and clustering fell back to its length-sensitive threshold. Loose
    /// on purpose — a participant list changes a handful of times per call, and
    /// each sample is an accessibility walk of the app's windows.
    private static let interval: TimeInterval = 15

    private let exclusions: ScreenExclusions
    private var roster: MeetingRoster?
    private var task: Task<Void, Never>?

    init(exclusions: ScreenExclusions) {
        self.exclusions = exclusions
    }

    deinit {
        task?.cancel()
    }

    func start() {
        task?.cancel()
        task = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                let rules = exclusions.rules
                let sampled = await Task.detached(priority: .utility) {
                    MeetingRosterReader(exclusions: rules).sample()
                }.value
                // A walk in flight when the meeting ended must not resurrect a
                // roster the finalize has already consumed.
                guard !Task.isCancelled else { return }
                if let sampled { merge(sampled) }
                try? await Task.sleep(nanoseconds: UInt64(Self.interval * 1_000_000_000))
            }
        }
    }

    func stop() {
        task?.cancel()
        task = nil
    }

    /// Hands this session's roster to its finalize and clears the field.
    ///
    /// Taken once and dropped: the names are session-scoped by policy
    /// (privacy.md § 3.10), and the next recording must start from nothing
    /// rather than merge into what this one left behind.
    func consume() -> MeetingRoster? {
        defer { roster = nil }
        return roster
    }

    func clear() {
        roster = nil
    }

    private func merge(_ sampled: MeetingRoster) {
        let before = roster?.speakerCount ?? 0
        let merged = roster?.merging(sampled) ?? sampled
        roster = merged
        if merged.speakerCount != before {
            Log.screen.info("roster: \(merged.app.displayName) — \(merged.speakerCount) participant(s) so far")
        }
    }
}
