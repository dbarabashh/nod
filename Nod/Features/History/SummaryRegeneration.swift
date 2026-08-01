import Combine
import Foundation

/// Rebuilds the recap of a meeting whose generation never landed — the laptop
/// closed mid-summary, the network dropped — from the transcript that was saved
/// anyway, then patches the row. The end-of-meeting flow has no retry of its
/// own: it stamps `Meeting.summaryUnavailableNote` and moves on, so without this
/// the transcript would keep a meeting that can never be summarised.
///
/// Runs from two places: the detail view's button, and once per meeting at
/// launch (`retryFailedSummaries`).
@MainActor
final class SummaryRegeneration: ObservableObject {
    enum State: Equatable {
        case idle
        case running(partial: String?)
        case failed(String)
    }

    /// Keyed by meeting so a regeneration outlives the detail view that started
    /// it, and so a launch retry surfaces in a detail view opened mid-run.
    @Published private(set) var states: [UUID: State] = [:]

    private let llm: LLMProxyClient
    private let meetingStore: MeetingStore
    private let actionItemStore: ActionItemStore
    private let knowledgeStore: KnowledgeStore
    private let profileStore: ProfileStore
    private let modeStore: ModeStore
    private let entitlements: EntitlementService

    /// Bounds on the launch retry — it spends metered hours nobody asked it to
    /// spend, so it takes a few of the newest failures and leaves the rest to
    /// the button.
    private static let retryLimit = 3
    private static let retryWindow: TimeInterval = 7 * 24 * 60 * 60

    init(
        llm: LLMProxyClient,
        meetingStore: MeetingStore,
        actionItemStore: ActionItemStore,
        knowledgeStore: KnowledgeStore,
        profileStore: ProfileStore,
        modeStore: ModeStore,
        entitlements: EntitlementService
    ) {
        self.llm = llm
        self.meetingStore = meetingStore
        self.actionItemStore = actionItemStore
        self.knowledgeStore = knowledgeStore
        self.profileStore = profileStore
        self.modeStore = modeStore
        self.entitlements = entitlements
    }

    func state(for meetingID: UUID) -> State {
        states[meetingID] ?? .idle
    }

    /// User-initiated re-run. Streams, so the recap fills in section by section
    /// in the open detail view. Failures land in `states`, not in a throw — the
    /// caller is a button.
    @discardableResult
    func run(for meeting: Meeting) async -> Meeting? {
        if case .running = state(for: meeting.id) { return nil }
        states[meeting.id] = .running(partial: nil)
        do {
            let updated = try await regenerate(meeting, streaming: true)
            states[meeting.id] = nil
            return updated
        } catch {
            Log.llm.error("summary regeneration failed: \(error.localizedDescription)")
            states[meeting.id] = .failed(error.localizedDescription)
            return nil
        }
    }

    /// One automatic re-run per meeting that ended without a recap, at launch.
    /// Bounded on every axis on purpose — never the same meeting twice
    /// (`attemptedKey` persists across launches), never one older than
    /// `retryWindow`, never one still queued in the outbox (the drain would
    /// overwrite the result), at most `retryLimit` per launch, and it stops at
    /// the first entitlement rejection rather than popping the paywall once per
    /// candidate.
    func retryFailedSummaries() async {
        if entitlements.entitlement == nil { await entitlements.refresh() }
        guard let entitlement = entitlements.entitlement,
              entitlement.isActive,
              entitlement.remainingHours > 0
        else {
            Log.llm.info("summary auto-retry skipped — no active entitlement or hours left")
            return
        }

        let attempted = Self.attemptedIDs
        let rows: [Meeting]
        do {
            rows = try await meetingStore.fetchMeetingsMissingRecap(
                since: Date().addingTimeInterval(-Self.retryWindow),
                limit: Self.retryLimit * 4
            )
        } catch {
            Log.llm.error("summary auto-retry lookup failed: \(error.localizedDescription)")
            return
        }
        let candidates = rows.filter { meeting in
            meeting.lacksRecap
                && !meetingStore.unsyncedMeetingIDs.contains(meeting.id)
                && !attempted.contains(meeting.id.uuidString)
        }
        .prefix(Self.retryLimit)
        guard !candidates.isEmpty else { return }
        Log.llm.info("summary auto-retry — \(candidates.count) meeting(s) without a recap")

        for meeting in candidates {
            // Recorded BEFORE the call: a meeting that crashes or errors the
            // model every time must not re-spend hours on every launch.
            Self.markAttempted(meeting.id)
            states[meeting.id] = .running(partial: nil)
            do {
                // Buffered, not streamed: nothing is on screen to fill in at
                // launch, and the streaming path re-parses the whole accumulated
                // JSON several times a second on the main actor.
                _ = try await regenerate(meeting, streaming: false)
                states[meeting.id] = nil
                Log.llm.info("summary auto-retry succeeded for \(meeting.id.uuidString)")
            } catch LLMProxyClient.ClientError.entitlementRequired {
                states[meeting.id] = nil
                Log.llm.info("summary auto-retry stopped — entitlement required")
                return
            } catch LLMProxyClient.ClientError.networkFailed {
                // Launch is exactly when Wi-Fi is still reconnecting, so an
                // offline attempt must not consume this meeting's one shot.
                Self.unmarkAttempted(meeting.id)
                states[meeting.id] = nil
                Log.llm.info("summary auto-retry deferred — offline")
                return
            } catch {
                states[meeting.id] = nil
                Log.llm.error("summary auto-retry failed: \(error.localizedDescription)")
            }
        }
    }

    private func regenerate(_ meeting: Meeting, streaming: Bool) async throws -> Meeting {
        let records = try await meetingStore.fetchTranscript(meetingID: meeting.id)
        let transcript = records.promptContext(names: meeting.speakerNames)
        guard !transcript.isEmpty else { throw Failure.noTranscript }

        // The meeting's own output language, not today's preference — a repaired
        // meeting should read like the one the user recorded. The roster isn't
        // persisted, so `participants` is the one input the finalize has and
        // this can't recover.
        let language = AppLanguage(rawValue: meeting.language) ?? .english
        let framing = MeetingFraming.active(for: meeting.kind, mode: modeStore.selected)
        let (system, user) = PromptLibrary.build(
            kind: .summary,
            transcript: transcript,
            language: language,
            personalContext: profileStore.promptContext,
            sessionKind: meeting.kind,
            summaryTemplate: framing.summary,
            modeFocus: framing.focus,
            meetingDate: PromptLibrary.sessionDateString(meeting.startedAt)
        )

        let generator = RecapGenerator(llm: llm)
        let recap: MeetingRecap = if streaming {
            try await generator.streamedRecap(
                system: system,
                user: user,
                transcript: transcript,
                language: language
            ) { [weak self] markdown in
                self?.states[meeting.id] = .running(partial: markdown)
            }
        } else {
            try await generator.recap(system: system, user: user, transcript: transcript, language: language)
        }

        let text = recap.toMarkdown()
        // A title the user already typed wins; a repaired meeting only gets a
        // generated one when it never had any.
        var title = meeting.title
        if title == nil {
            title = await generator.title(from: text, language: language)
        }

        let updated = meeting.updating(title: title, summary: text, recap: recap)
        try await meetingStore.update(updated)
        // The same enrichment the finalize runs once a recap lands, minus the
        // entity extraction it keeps private: without these the repaired meeting
        // has a summary but no checklist and no place in cross-session search.
        await actionItemStore.promoteMissing(in: [updated])
        await knowledgeStore.index(meetingID: updated.id, transcript: transcript)
        return updated
    }

    enum Failure: LocalizedError {
        case noTranscript

        var errorDescription: String? {
            switch self {
            case .noTranscript: "No transcript saved for this meeting."
            }
        }
    }

    private static let attemptedKey = "summary.autoRetryAttempted"

    /// Meetings the launch retry has already spent a shot on. Capped, oldest
    /// dropped — a ledger, not a permanent record.
    private static var attemptedIDs: [String] {
        get { UserDefaults.standard.stringArray(forKey: attemptedKey) ?? [] }
        set { UserDefaults.standard.set(Array(newValue.suffix(200)), forKey: attemptedKey) }
    }

    private static func markAttempted(_ id: UUID) {
        attemptedIDs.append(id.uuidString)
    }

    private static func unmarkAttempted(_ id: UUID) {
        attemptedIDs.removeAll { $0 == id.uuidString }
    }
}
