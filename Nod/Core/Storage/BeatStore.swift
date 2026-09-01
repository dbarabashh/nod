import Combine
import Foundation
import Supabase

/// Owns the user's beats and the runs they produced. RLS (`auth.uid() =
/// user_id`) scopes every read and write to the owner; the one thing that is
/// not a plain table write is claiming a run, which has to be atomic because
/// two Macs on one account see the same due run at the same second.
@MainActor
final class BeatStore: ObservableObject {
    @Published private(set) var beats: [Beat] = []
    /// The recent runs, newest first — what the Beats list shows under each
    /// row and what the answer cards are built from.
    @Published private(set) var runs: [BeatRun] = []
    /// The answer each finished run wrote, keyed by run. Loaded lazily — the
    /// list only needs the first line, the detail view needs all of it, and a
    /// month of daily reports is not something to fetch to draw a card.
    @Published private(set) var reports: [UUID: String] = [:]
    /// The last refusal, in the words the database used. Editing happens in a
    /// sheet with nowhere to put a spinner, so a failure that only reached the
    /// log looked exactly like a save that did nothing.
    @Published var lastError: String?

    /// Optional so a preview can hold a store with nothing behind it — the
    /// same reason `ActionProposalStore` does.
    private let supabase: SupabaseClient?
    private let auth: AuthService?
    private static let beatsTable = "beats"
    private static let runsTable = "beat_runs"
    /// How much history the list needs. A beat that ran every weekday for a
    /// month is 20 rows; the card only ever shows the latest few.
    private static let runHistory = 50

    init(supabase: SupabaseClient?, auth: AuthService?) {
        self.supabase = supabase
        self.auth = auth
    }

    // MARK: - Reads

    /// Drops the previous account's beats and everything they produced.
    func clear() {
        beats = []
        runs = []
        reports = [:]
        lastError = nil
    }

    func refresh() async {
        #if DEBUG
            if DemoMode.isEnabled { return }
        #endif
        guard let supabase, auth?.currentSupabaseSession != nil else { return }
        do {
            beats = try await supabase
                .from(Self.beatsTable)
                .select()
                .order("created_at", ascending: false)
                .execute()
                .value
            runs = try await supabase
                .from(Self.runsTable)
                .select()
                .order("scheduled_for", ascending: false)
                .limit(Self.runHistory)
                .execute()
                .value
            Log.ui.info("BeatStore.refresh \(beats.count) beat(s), \(runs.count) run(s)")
        } catch {
            Log.ui.error("BeatStore.refresh failed: \(error.localizedDescription)")
        }
    }

    /// The latest run of a beat, whatever became of it.
    func latestRun(of beatID: UUID) -> BeatRun? {
        runs.first { $0.beatID == beatID }
    }

    /// Every run of one beat, newest first.
    func runs(of beatID: UUID) -> [BeatRun] {
        runs.filter { $0.beatID == beatID }
    }

    /// The report a run wrote. Cached for the app run: a finished report never
    /// changes, so reopening the beat must not refetch it.
    @discardableResult
    func loadReport(for run: BeatRun) async -> String? {
        if let cached = reports[run.id] { return cached }
        guard let supabase, let threadID = run.threadID else { return nil }
        struct Row: Decodable { let content: String }
        do {
            let rows: [Row] = try await supabase
                .from("knowledge_messages")
                .select("content")
                .eq("thread_id", value: threadID.uuidString)
                .eq("role", value: "assistant")
                .order("created_at", ascending: true)
                .limit(1)
                .execute()
                .value
            guard let content = rows.first?.content else { return nil }
            reports[run.id] = content
            return content
        } catch {
            Log.ui.error("BeatStore.loadReport failed: \(error.localizedDescription)")
            return nil
        }
    }

    /// Asks for a run now instead of at the beat's hour. The row is enqueued
    /// exactly as the cron tick would enqueue it, so the Mac answers it through
    /// the one path that already exists.
    @discardableResult
    func runNow(_ beatID: UUID) async -> BeatRun? {
        struct Params: Encodable { let p_beat_id: UUID }
        guard let supabase else { return nil }
        do {
            let queued: [BeatRun] = try await supabase
                .rpc("run_beat_now", params: Params(p_beat_id: beatID))
                .execute()
                .value
            return queued.first
        } catch {
            Log.ui.error("BeatStore.runNow failed: \(error.localizedDescription)")
            lastError = error.localizedDescription
            return nil
        }
    }

    // MARK: - Beat CRUD

    @discardableResult
    func create(
        title: String,
        prompt: String,
        cadence: Beat.Cadence,
        hour: Int,
        minute: Int,
        weekday: Int = 1,
        dayOfMonth: Int = 1,
        timezone: String = TimeZone.current.identifier
    ) async -> Beat? {
        let trimmedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedPrompt = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedPrompt.isEmpty else { return nil }
        guard let supabase, let userID = auth?.currentSupabaseSession?.user.id else { return nil }
        let draft = Beat(
            id: UUID(),
            userID: userID,
            title: trimmedTitle.isEmpty ? String(trimmedPrompt.prefix(60)) : trimmedTitle,
            prompt: trimmedPrompt,
            cadence: cadence,
            hour: hour,
            minute: minute,
            weekday: weekday,
            dayOfMonth: dayOfMonth,
            timezone: timezone,
            enabled: true,
            nextRunAt: nil,
            createdAt: nil
        )
        do {
            let saved: Beat = try await supabase
                .from(Self.beatsTable)
                .insert(draft)
                .select()
                .single()
                .execute()
                .value
            beats.insert(saved, at: 0)
            return saved
        } catch {
            Log.ui.error("BeatStore.create failed: \(error.localizedDescription)")
            lastError = error.localizedDescription
            return nil
        }
    }

    func update(_ beat: Beat) async {
        guard let supabase else { return }
        do {
            let saved: Beat = try await supabase
                .from(Self.beatsTable)
                .update(beat)
                .eq("id", value: beat.id.uuidString)
                .select()
                .single()
                .execute()
                .value
            replace(saved)
        } catch {
            Log.ui.error("BeatStore.update failed: \(error.localizedDescription)")
            lastError = error.localizedDescription
        }
    }

    func delete(_ beatID: UUID) async {
        guard let supabase else { return }
        do {
            try await supabase
                .from(Self.beatsTable)
                .delete()
                .eq("id", value: beatID.uuidString)
                .execute()
            beats.removeAll { $0.id == beatID }
            runs.removeAll { $0.beatID == beatID }
        } catch {
            Log.ui.error("BeatStore.delete failed: \(error.localizedDescription)")
            lastError = error.localizedDescription
        }
    }

    // MARK: - Runs

    /// Runs waiting to be answered, oldest first — a Mac that was shut answers
    /// the morning briefing before the midday one.
    func dueRuns() async -> [BeatRun] {
        guard let supabase, auth?.currentSupabaseSession != nil else { return [] }
        do {
            return try await supabase
                .from(Self.runsTable)
                .select()
                .eq("status", value: "due")
                .order("scheduled_for", ascending: true)
                .execute()
                .value
        } catch {
            Log.ui.error("BeatStore.dueRuns failed: \(error.localizedDescription)")
            return []
        }
    }

    /// Takes a run for this Mac. Nil when another one got there first — the
    /// claim is the update, so the loser learns it lost by being handed nothing.
    func claim(_ runID: UUID) async -> BeatRun? {
        struct Params: Encodable { let p_run_id: UUID }
        guard let supabase else { return nil }
        do {
            let claimed: [BeatRun] = try await supabase
                .rpc("claim_beat_run", params: Params(p_run_id: runID))
                .execute()
                .value
            return claimed.first
        } catch {
            Log.ui.error("BeatStore.claim failed: \(error.localizedDescription)")
            return nil
        }
    }

    func finish(_ runID: UUID, threadID: UUID) async {
        await close(runID, status: "done", threadID: threadID.uuidString, reason: nil)
    }

    func fail(_ runID: UUID, reason: String) async {
        await close(runID, status: "failed", threadID: nil, reason: reason)
    }

    /// Optional fields are omitted rather than nulled — closing a failed run
    /// must not erase the thread a retry already wrote.
    private struct RunClose: Encodable {
        let status: String
        let thread_id: String?
        let error: String?
        let finished_at: String
    }

    private func close(_ runID: UUID, status: String, threadID: String?, reason: String?) async {
        guard let supabase else { return }
        let payload = RunClose(
            status: status,
            thread_id: threadID,
            error: reason,
            finished_at: ISO8601DateFormatter().string(from: Date())
        )
        do {
            try await supabase
                .from(Self.runsTable)
                .update(payload)
                .eq("id", value: runID.uuidString)
                .execute()
        } catch {
            Log.ui.error("BeatStore.close failed: \(error.localizedDescription)")
        }
    }

    private func replace(_ beat: Beat) {
        guard let index = beats.firstIndex(where: { $0.id == beat.id }) else { return }
        beats[index] = beat
    }
}
