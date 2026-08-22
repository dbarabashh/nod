import Foundation

/// Owns the day's briefing: assembles the rows from what the app already holds,
/// and asks the model for the prose above them.
///
/// The rows are rebuilt on every refresh because they are free and they go
/// stale within the hour — a call that has ended is no longer ahead. The prose
/// is not free, so it is held against the *facts* it was written about: while
/// the day holds the same shape the same paragraph stands, and the moment it
/// doesn't it is rewritten rather than left contradicting the list under it.
///
/// Held in memory only. The prose names meetings and commitments, and a copy of
/// it in `UserDefaults` would outlive both signing out and deleting the account.
@MainActor
final class DailyBriefingStore: ObservableObject {
    @Published private(set) var brief: String?
    @Published private(set) var facts = DailyBriefing.Facts(ahead: [], owed: [], loose: [])
    @Published private(set) var isWriting = false

    private let llm: LLMProxyClient
    private let meetings: MeetingStore
    private let actionItems: ActionItemStore
    private let entitlements: EntitlementService
    private let profiles: ProfileStore
    private let language: LanguagePreference
    private let calendar: CalendarService
    /// Ambient screen context, when the user has it on. It never becomes a row
    /// — what it is for is telling the prose which piece of work a commitment
    /// belongs to, which nothing else here knows.
    private let screen: ScreenContextService

    private var writing: Task<Void, Never>?
    /// The facts the current `brief` was written about. Comparing against this
    /// rather than a stored digest keeps `Row.id` free to stay a view identity.
    private var writtenFor: [String] = []

    init(
        llm: LLMProxyClient,
        meetings: MeetingStore,
        actionItems: ActionItemStore,
        entitlements: EntitlementService,
        profiles: ProfileStore,
        language: LanguagePreference,
        calendar: CalendarService,
        screen: ScreenContextService
    ) {
        self.llm = llm
        self.meetings = meetings
        self.actionItems = actionItems
        self.entitlements = entitlements
        self.profiles = profiles
        self.language = language
        self.calendar = calendar
        self.screen = screen
    }

    /// Load what the rows are made of, rebuild them, then write the prose if it
    /// isn't already standing for these facts.
    ///
    /// The load comes first because it is the difference between briefing the
    /// day and briefing an empty list: on a cold open `ActionItemStore` has not
    /// fetched yet, and a paragraph written against no commitments is a model
    /// call spent on the wrong facts.
    func refresh(now: Date = Date()) async {
        await actionItems.refresh()
        rebuild(now: now)
    }

    /// The same work without the fetch, for a change that has already landed in
    /// one of the stores.
    func rebuild(now: Date = Date()) {
        let built = DailyBriefing.facts(
            meetings: meetings.meetings,
            actionItems: entitlements.mayUse(.actionItems) ? actionItems.openItems : [],
            events: calendar.meetings(overlapping: today(from: now)),
            now: now
        )
        if built != facts { facts = built }

        let keys = built.rows.map(\.factKey)
        guard !built.isEmpty else {
            // Nothing happened and nothing is owed. A briefing generated anyway
            // is the thing that teaches people to stop reading it.
            cancelWriting()
            brief = nil
            writtenFor = []
            return
        }
        guard keys != writtenFor else { return }

        cancelWriting()
        isWriting = true
        writing = Task { [weak self] in
            guard let self else { return }
            let written = await write(built, now: now)
            guard !Task.isCancelled else { return }
            isWriting = false
            guard let written, !written.brief.isEmpty else { return }
            brief = written.brief
            writtenFor = keys
        }
    }

    private func cancelWriting() {
        writing?.cancel()
        writing = nil
        if isWriting { isWriting = false }
    }

    private func write(_ built: DailyBriefing.Facts, now: Date) async -> PromptLibrary.DailyBriefingResult? {
        let (system, user) = await PromptLibrary.buildDailyBriefing(
            name: Profile.firstName(in: profiles.profile?.displayName),
            dayLabel: ChatHomeSuggestions.dayLine(now),
            clock: PromptLibrary.localTimeString(now),
            items: PromptLibrary.DailyBriefingItems(
                ahead: built.ahead.map(Self.line),
                owed: built.owed.map(Self.line),
                loose: built.loose.map(Self.line),
                onScreen: onScreen(before: now)
            ),
            language: language.current
        )
        do {
            return try await llm.completeJSON(
                system: system,
                user: user,
                as: PromptLibrary.DailyBriefingResult.self,
                primaryModel: llm.utilityModel
            )
        } catch {
            Log.llm.error("daily briefing failed: \(error.localizedDescription)")
            return nil
        }
    }

    /// A day back, which is what "lately" means to somebody opening this in the
    /// morning. Empty whenever ambient capture is off or unentitled —
    /// `windowsOnScreen(in:)` answers that itself, so nothing here has to ask.
    private func onScreen(before now: Date) async -> [String] {
        await DailyBriefing.screenLines(from: screen.windowsOnScreen(in: ScreenRecall.defaultWindow(now: now)))
    }

    /// One row as the prompt sees it. The trailing label carries the deadline
    /// and the time, which is most of what the prose has to be right about.
    private static func line(_ row: DailyBriefing.Row) -> String {
        var line = row.title
        if let meta = row.meta, !meta.isEmpty { line += " (\(meta))" }
        if let subtitle = row.subtitle, !subtitle.isEmpty { line += " [\(subtitle)]" }
        return line
    }

    private func today(from now: Date) -> DateInterval {
        Foundation.Calendar.current.dateInterval(of: .day, for: now)
            ?? DateInterval(start: now, duration: 0)
    }
}
