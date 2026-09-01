import SwiftUI

/// The screen Nod opens onto: what needs the user's attention, before they ask.
///
/// The product's promise is that Nod remembers things before the user does, and
/// a home that opens with an empty composer makes that promise invisible. This
/// surface leads with what Nod already knows — the next meeting and what last
/// time left open, the commitments still waiting, the beats that came back with
/// something — and keeps the composer below as the escape hatch, not the point.
///
/// Beats are delivery, not a destination: a fresh report lands here on its own,
/// and the Beats page remains where routines are managed. A commitment opens
/// its actions in place — the session is evidence, not the destination.
struct TodayView: View {
    let onCapture: () -> Void
    let onOpenMeeting: (Meeting) -> Void
    let onOpenBeats: () -> Void
    let onAsk: (String) -> Void

    @EnvironmentObject private var meetingStore: MeetingStore
    @EnvironmentObject private var actionItemStore: ActionItemStore
    @EnvironmentObject private var calendar: CalendarService
    @EnvironmentObject private var beatStore: BeatStore
    @EnvironmentObject private var profileStore: ProfileStore
    @EnvironmentObject private var entitlements: EntitlementService
    @EnvironmentObject private var screenContext: ScreenContextService

    /// The rest of the day's calendar, kept whole so the card can move to the
    /// next entry on the clock without another load.
    @State private var upcoming: [CalendarOccurrence] = []
    /// The last conversation with the same people, per upcoming entry.
    @State private var lastTimeByStart: [Date: Meeting] = [:]
    @State private var beatReports: [BeatReportRow] = []
    /// The open items split once, not on every body pass: which wait on you,
    /// which were handed over. Rebuilt when the store or a delegation changes.
    @State private var partition = Partition()
    /// Related on-screen work per open item — filled only under the person's
    /// own `AmbientScopes.todaySuggestions` opt-in, shown only to them.
    @State private var ambientHints: [UUID: [ScreenObservation]] = [:]
    @State private var expandedItemID: UUID?
    @State private var draft = ""
    @State private var now = Date()
    /// "You're clear" is a claim; it waits for the first load to have earned it.
    @State private var hasLoaded = false

    /// A minute is the resolution the card speaks in ("Starts in 24 min"), so
    /// it is also how often the clock this view reads moves.
    private let clock = Timer.publish(every: 60, on: .main, in: .common).autoconnect()

    private static let rowLimit = 4

    /// One delivered beat result, resolved off the stores once per load so the
    /// body never awaits.
    struct BeatReportRow: Identifiable, Equatable {
        let beat: Beat
        let run: BeatRun
        let preview: String
        let isNew: Bool

        var id: UUID {
            run.id
        }
    }

    struct Partition: Equatable {
        var waitingOnYou: [ActionItem] = []
        var waitingOnOthers: [ActionItem] = []
    }

    /// What has to change for Today to re-read the world: the list itself, a
    /// recording starting or ending, the newest session gaining its recap, or
    /// a beat finishing a run.
    private struct ReloadKey: Equatable {
        let digest: MeetingStore.DigestKey
        let recording: UUID?
        let newestRecapReady: Bool
        let newestEndedAt: Date?
        let latestBeatRun: UUID?
    }

    private var reloadKey: ReloadKey {
        let newest = meetingStore.meetings.first
        return ReloadKey(
            digest: meetingStore.digestKey,
            recording: meetingStore.recordingMeetingID,
            newestRecapReady: newest.map { !$0.summary.isEmpty } ?? false,
            newestEndedAt: newest?.endedAt,
            latestBeatRun: beatStore.runs
                .filter { $0.status == .done }
                .max { $0.scheduledFor < $1.scheduledFor }?
                .id
        )
    }

    private var nextMeeting: CalendarOccurrence? {
        upcoming.first { $0.endsAt > now }
    }

    private var lastTime: Meeting? {
        nextMeeting.flatMap { lastTimeByStart[$0.startsAt] }
    }

    private var waitingOnYou: [ActionItem] {
        partition.waitingOnYou
    }

    private var waitingOnOthers: [ActionItem] {
        partition.waitingOnOthers
    }

    /// Split from the store's cache so the checkbox's optimistic tick shows
    /// instantly and `setDone` resolves against the cache it needs. A
    /// handed-over item stops waiting on you: it moves to its own quieter
    /// section, and out of the attention count — thirty-one things cannot all
    /// need attention, and a home that says so is a backlog, not a briefing.
    private func repartition() {
        guard entitlements.mayUse(.actionItems) else {
            partition = Partition()
            return
        }
        let open = actionItemStore.items
            .filter(\.isOpen)
            .sorted { $0.createdAt ?? .distantPast > $1.createdAt ?? .distantPast }
        partition = Partition(
            waitingOnYou: open.filter { ActionDelegation.recorded(for: $0.id) == nil },
            waitingOnOthers: open.filter { ActionDelegation.recorded(for: $0.id) != nil }
        )
        if let expandedItemID, !partition.waitingOnYou.contains(where: { $0.id == expandedItemID }) {
            self.expandedItemID = nil
        }
    }

    /// Open but not on today's screen: neither shown nor counted as urgent.
    private var trackedCount: Int {
        max(0, waitingOnYou.count - Self.rowLimit)
    }

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    header
                    if let nextMeeting {
                        TodayMeetingCard(
                            occurrence: nextMeeting,
                            lastTime: lastTime,
                            now: now,
                            onCapture: onCapture,
                            onOpenMeeting: onOpenMeeting
                        )
                    }
                    if !waitingOnYou.isEmpty {
                        // Above the cards that follow: an open drawer's pickers
                        // float past the card's edge, and a later sibling would
                        // otherwise paint over them.
                        commitmentsCard.zIndex(1)
                    }
                    if !waitingOnOthers.isEmpty {
                        TodayWaitingOnOthersCard(items: Array(waitingOnOthers.prefix(3)))
                    }
                    if !beatReports.isEmpty {
                        TodayBeatsCard(reports: beatReports, onOpenBeats: onOpenBeats)
                    }
                    if hasLoaded, attentionCount == 0, waitingOnOthers.isEmpty {
                        allClearCard
                    }
                }
                .frame(maxWidth: 640, alignment: .leading)
                .frame(maxWidth: .infinity)
                .padding(.horizontal, 28)
                .padding(.top, 36)
                .padding(.bottom, 20)
            }
            composer
        }
        // Keyed on a cheap signal rather than the whole meetings array, and
        // structured so a reload in flight is cancelled instead of racing the
        // next one. `digestKey` alone missed the case this screen exists for:
        // a meeting that was already in the list finishing — same count, same
        // newest id — while its recap and action items landed unseen.
        .task(id: reloadKey) {
            await load()
        }
        .onReceive(clock) { tick in
            now = tick
        }
        .onChange(of: actionItemStore.items) { _ in repartition() }
        .onReceive(NotificationCenter.default.publisher(for: .nodActionDelegated)) { _ in
            repartition()
        }
    }

    private var attentionCount: Int {
        (nextMeeting == nil ? 0 : 1) + min(waitingOnYou.count, Self.rowLimit) + beatReports.filter(\.isNew).count
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 6) {
                Text(TodayBrief.greeting(for: profileStore.profile?.displayName, at: now))
                    .font(.system(size: 24, weight: .semibold))
                    .foregroundStyle(Theme.Palette.ink)
                Text(subtitle)
                    .font(.system(size: 13))
                    .foregroundStyle(Theme.Palette.muted)
            }
            Spacer(minLength: 8)
            // Ad-hoc capture lives on the meeting card when one is coming; with
            // nothing scheduled it still needs a door on this screen.
            if nextMeeting == nil {
                Button {
                    onCapture()
                } label: {
                    HStack(spacing: 5) {
                        Image("nc-plus").icon(10)
                        Text("New capture")
                    }
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Theme.Palette.ink)
                    .padding(.horizontal, 11)
                    .padding(.vertical, 6)
                    .background(Capsule(style: .continuous).fill(Theme.Palette.surfaceStrong))
                }
                .buttonStyle(.plain)
                .linkCursor()
            }
        }
    }

    private var subtitle: String {
        guard attentionCount > 0 else {
            return ChatHomeSuggestions.dayLine(now)
        }
        let things = attentionCount == 1 ? "1 thing needs" : "\(attentionCount) things need"
        var parts = ["\(things) your attention"]
        if !waitingOnOthers.isEmpty { parts.append("\(waitingOnOthers.count) waiting on others") }
        if trackedCount > 0 { parts.append("\(trackedCount) tracked") }
        return parts.joined(separator: " · ")
    }

    private var commitmentsCard: some View {
        TodayCommitmentsCard(
            openItems: Array(waitingOnYou.prefix(Self.rowLimit)),
            ambientHints: ambientHints,
            expandedItemID: $expandedItemID,
            onAsk: onAsk,
            onOpenMeeting: onOpenMeeting
        )
    }

    private var allClearCard: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Image("nc-circle-check")
                .icon(13)
                .foregroundStyle(Theme.Palette.success)
            VStack(alignment: .leading, spacing: 2) {
                Text("You're clear")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Theme.Palette.ink)
                Text(
                    meetingStore.meetings.isEmpty
                        ? "Nothing is waiting on you yet. Capture a session to give Nod something to remember."
                        : "Nod checked \(meetingStore.meetings.count) sessions and found nothing waiting on you."
                )
                .font(.system(size: 12))
                .foregroundStyle(Theme.Palette.muted)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .surfaceCard()
    }

    private var composer: some View {
        HStack(spacing: 10) {
            Image("nc-magnifier")
                .icon(12)
                .foregroundStyle(Theme.Palette.muted)
            TextField("Ask anything across your memory…", text: $draft)
                .textFieldStyle(.plain)
                .font(.system(size: 13))
                .onSubmit(submit)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .surfaceCard()
        .frame(maxWidth: 640)
        .padding(.horizontal, 28)
        .padding(.bottom, 20)
    }

    private func submit() {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        draft = ""
        onAsk(text)
    }

    /// Every write below is fenced on cancellation: `reloadKey` flips twice
    /// when a meeting ends (the recording stops, then its recap lands), and
    /// the first load finishing after the second started used to interleave
    /// half its results into the other's.
    private func load() async {
        now = Date()
        await calendar.refreshRemoteIfStale(maxAge: 300)
        guard !Task.isCancelled else { return }
        let horizon = DateInterval(start: now, duration: 12 * 3600)
        let ahead = calendar.meetings(overlapping: horizon)
            .filter { $0.endsAt > now }
            .sorted { $0.startsAt < $1.startsAt }
        upcoming = ahead
        lastTimeByStart = Dictionary(
            ahead.prefix(3).compactMap { occurrence in
                TodayBrief.lastSession(before: occurrence, in: meetingStore.meetings).map { (occurrence.startsAt, $0) }
            },
            uniquingKeysWith: { first, _ in first }
        )

        // The store's cache is what the rows and the checkbox both read, so it
        // is the thing to refresh. Forced: the plain refresh is a one-time
        // load, and a meeting that just ended has written items the cache has
        // never seen.
        await actionItemStore.refresh(force: true)
        guard !Task.isCancelled else { return }
        repartition()

        // The "you worked on this" hints, only under their own opt-in. The
        // service returns nothing when ambient itself is off or paused, and
        // does its own term extraction from the words it is given.
        var hints: [UUID: [ScreenObservation]] = [:]
        if AmbientScopes.todaySuggestions {
            for item in waitingOnYou.prefix(Self.rowLimit) {
                let related = await screenContext.linkedContext(aboutProjects: [[item.matchable]], limit: 2)
                guard !Task.isCancelled else { return }
                if !related.isEmpty { hints[item.id] = related }
            }
        }
        ambientHints = hints

        await beatStore.refresh()
        guard !Task.isCancelled else { return }
        var rows: [BeatReportRow] = []
        let delivered = beatStore.beats
            .filter(\.enabled)
            .compactMap { beat -> (Beat, BeatRun)? in
                guard let run = beatStore.latestRun(of: beat.id), run.status == .done else { return nil }
                return (beat, run)
            }
            .sorted { $0.1.scheduledFor > $1.1.scheduledFor }
            .prefix(3)
        for (beat, run) in delivered {
            let report = await beatStore.loadReport(for: run) ?? ""
            guard !Task.isCancelled else { return }
            rows.append(BeatReportRow(
                beat: beat,
                run: run,
                preview: TodayBrief.firstLine(of: report),
                isNew: TodayBrief.isUnseen(run, of: beat)
            ))
        }
        beatReports = rows
        hasLoaded = true
    }
}
