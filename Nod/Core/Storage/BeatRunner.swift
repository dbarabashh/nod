import AppKit
import Foundation

/// Answers the beats that have come due, on whichever Mac happens to be awake.
///
/// The schedule is Postgres'; the answering is this. Nothing runs while the
/// machine is asleep and nothing is queued up to run later — `enqueue_due_beats`
/// expires a run nobody claimed, so a laptop opened after a week delivers this
/// morning's beat and not a week of them.
///
/// One run at a time on purpose. A beat is a full grounded turn — retrieval,
/// the screen record, a couple of model round trips — and three of them at once
/// on a machine somebody is trying to work on is a fan, not a feature.
@MainActor
final class BeatRunner: ObservableObject {
    /// How often to look for work. A beat is due to the minute, so anything
    /// finer is a poll for nothing; anything coarser eats into the claim window
    /// on a Mac that woke just before the hour.
    private static let interval: TimeInterval = 60

    private let beats: BeatStore
    private let chat: KnowledgeChatStore
    private let threads: KnowledgeThreadStore
    private let entitlements: EntitlementService
    private let auth: AuthService

    private var timer: Task<Void, Never>?
    private var sleepObservers: [NSObjectProtocol] = []

    init(
        beats: BeatStore,
        chat: KnowledgeChatStore,
        threads: KnowledgeThreadStore,
        entitlements: EntitlementService,
        auth: AuthService
    ) {
        self.beats = beats
        self.chat = chat
        self.threads = threads
        self.entitlements = entitlements
        self.auth = auth
        observeSleep()
    }

    deinit {
        let center = NSWorkspace.shared.notificationCenter
        for observer in sleepObservers {
            center.removeObserver(observer)
        }
    }

    func start() {
        guard timer == nil else { return }
        Log.ui.info("beats: watching for due runs (every \(Int(Self.interval))s)")
        timer = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: UInt64(Self.interval * 1_000_000_000))
                guard let self, !Task.isCancelled else { return }
                await tick()
            }
        }
    }

    func stop() {
        guard timer != nil else { return }
        timer?.cancel()
        timer = nil
        Log.ui.info("beats: stopped watching")
    }

    /// Answer whatever is waiting, right now. The "Run now" button enqueues a
    /// run and then calls this, so the report starts being written while the
    /// person is still looking at the screen instead of up to a minute later.
    func answerDueNow() async {
        await tick()
    }

    private func tick() async {
        // The same entitlement a typed cross-session question needs. A beat is
        // that question on a timer, so it cannot be gated more loosely — or
        // more tightly — than the thing it repeats.
        guard auth.currentSupabaseSession != nil,
              let entitlement = entitlements.entitlement,
              entitlement.isActive,
              entitlement.can(.askAcrossMeetings)
        else { return }
        // Serially, oldest first: the morning briefing is answered before the
        // midday one, and each is a whole grounded turn.
        for run in await beats.dueRuns() {
            await answer(run)
        }
    }

    private func answer(_ run: BeatRun) async {
        guard let claimed = await beats.claim(run.id) else { return }
        var beat = beats.beats.first { $0.id == claimed.beatID }
        if beat == nil {
            // The run names a beat this Mac hasn't loaded — it was created on
            // another machine minutes ago. Worth one read before calling it
            // deleted.
            await beats.refresh()
            beat = beats.beats.first { $0.id == claimed.beatID }
        }
        guard let beat else {
            await beats.fail(claimed.id, reason: "The agent was deleted before its run was answered.")
            return
        }
        let started = ContinuousClock.now
        chat.startNewThread()
        await chat.ask(beat.prompt, products: beat.providers)
        guard let threadID = chat.threadID else {
            await beats.fail(claimed.id, reason: chat.failure?.message ?? "The answer could not be saved.")
            Log.ui.error("beat \(beat.displayTitle) produced no thread")
            return
        }
        await threads.attach(threadID: threadID, to: beat.id, title: beat.displayTitle)
        await beats.finish(claimed.id, threadID: threadID)
        let seconds = Int(started.duration(to: .now).components.seconds)
        Log.ui.info("beat ran \(beat.displayTitle) in \(seconds)s")
        await beats.refresh()
    }

    private func observeSleep() {
        let center = NSWorkspace.shared.notificationCenter
        sleepObservers = [
            center.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.stop() }
            },
            center.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.start() }
            }
        ]
    }
}
