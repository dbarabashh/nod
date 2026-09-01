import Foundation

/// State behind the quick panel: what was typed, which mode that puts it in,
/// and the results for it. Kept out of the view so the keyboard driving
/// (arrows, Return) can act on it from an event monitor rather than SwiftUI's
/// version-gated key handling.
@MainActor
final class LauncherModel: ObservableObject {
    /// A row in the list. Asking is an action alongside the sessions rather
    /// than a mode you have to switch into: typing a question and pressing
    /// Return should answer it, which is what people actually do.
    enum Row: Identifiable, Equatable {
        case ask(String)
        case session(Result)

        var id: String {
            switch self {
            case .ask: "nod.launcher.ask"
            case let .session(result): result.id.uuidString
            }
        }
    }

    struct Result: Identifiable, Equatable {
        let id: UUID
        let title: String
        let subtitle: String
        let date: Date
        let icon: String
        /// Set when the row came from the semantic index rather than a title
        /// match — the excerpt that matched, to show why it's here.
        var excerpt: String?
    }

    @Published var query = "" {
        didSet { queryChanged(from: oldValue) }
    }

    @Published private(set) var results: [Result] = []

    @Published private(set) var isSearching = false
    @Published var selection = 0
    /// True once a question has been sent from here — the panel then shows the
    /// answer instead of the list.
    @Published private(set) var isAnswering = false

    /// Number of messages the shared thread already had when the panel opened.
    /// The launcher shows only what it asked for — the Library's conversation
    /// keeps running underneath instead of being wiped or leaking into view.
    @Published private(set) var threadBaseline = 0

    /// Reopening this soon after a dismissal resumes what was on screen. Beyond
    /// the window it opens fresh — a launcher that greets you with a
    /// half-forgotten answer from this morning stops being a launcher. Same
    /// shape as the "pop to root search after a while" behaviour people already
    /// know from other launchers.
    static let resumeWindow: TimeInterval = 90

    private var dismissedAt: Date?
    /// Set when the dismissal was the point — a session was opened, or the
    /// thread was handed to the Library. There's nothing to come back to.
    private var consumed = false

    /// Called when the panel opens. Restores the last question and its answer
    /// after an accidental dismissal (Escape, a click away), and starts clean
    /// otherwise.
    func prepareForPresentation(now: Date = Date()) {
        if Self.resumes(dismissedAt: dismissedAt, now: now, hasContent: hasContent, consumed: consumed) {
            dismissedAt = nil
            return
        }
        consumed = false
        dismissedAt = nil
        reset()
        threadBaseline = chat.messages.count
    }

    func noteDismissed(now: Date = Date()) {
        dismissedAt = now
    }

    /// The dismissal completed something, so the next open starts clean.
    func noteConsumed() {
        consumed = true
    }

    /// Anything worth coming back to: an answer being read, or a query typed.
    private var hasContent: Bool {
        answer != nil || !question.isEmpty
    }

    static func resumes(dismissedAt: Date?, now: Date, hasContent: Bool, consumed: Bool) -> Bool {
        guard !consumed, hasContent, let dismissedAt else { return false }
        return now.timeIntervalSince(dismissedAt) < resumeWindow
    }

    /// What gets asked. A leading "?" is still honoured as a way to force the
    /// ask row to the top for a query that doesn't read as a question.
    var question: String {
        let text = query.hasPrefix("?") ? String(query.dropFirst()) : query
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Sessions, plus the ask action — first when the query reads as a
    /// question (so Return answers it), last otherwise (so Return still opens
    /// the obvious match and asking stays one keystroke away).
    var rows: [Row] {
        let sessions = results.map(Row.session)
        guard !question.isEmpty else { return sessions }
        return leadsWithAsk ? [.ask(question)] + sessions : sessions + [.ask(question)]
    }

    var leadsWithAsk: Bool {
        query.hasPrefix("?") || QuestionIntent.isQuestion(question)
    }

    var selectedRow: Row? {
        rows.indices.contains(selection) ? rows[selection] : nil
    }

    private let meetings: MeetingStore
    private let knowledge: KnowledgeStore
    private let chat: KnowledgeChatStore
    private var searchTask: Task<Void, Never>?

    /// Long enough that a fast typist makes one semantic round trip instead of
    /// one per keystroke; short enough to feel like it's keeping up. Each miss
    /// is a billed embedding + vector scan, so this is a cost dial as much as a
    /// UX one.
    private static let debounce: Duration = .milliseconds(320)
    /// Below this, a semantic search is noise — the local title filter already
    /// covers prefixes, and two letters match everything.
    private static let minSemanticLength = 3
    private static let recentCount = 6

    init(meetings: MeetingStore, knowledge: KnowledgeStore, chat: KnowledgeChatStore) {
        self.meetings = meetings
        self.knowledge = knowledge
        self.chat = chat
    }

    /// Asks the shared thread and remembers that this panel is the one waiting
    /// on it. Owned here rather than in the window controller so "am I asking",
    /// "is there an answer", and "can I hand this to the Library" are one
    /// answer read from one place.
    func ask() async {
        let question = question
        guard !question.isEmpty else { return }
        isAnswering = true
        await chat.ask(question)
    }

    /// The answer to what was asked *here*. The shared thread keeps running for
    /// the Library dock underneath, so the panel only shows turns that landed
    /// after it opened. Safe as a count because `KnowledgeChatStore.ask` refuses
    /// to start while another is in flight — there is never a second asker.
    var answer: KnowledgeChatStore.Message? {
        chat.answer(after: threadBaseline)
    }

    /// Fresh panel: empty query, most recent sessions, nothing selected but the
    /// first row.
    func reset() {
        searchTask?.cancel()
        isAnswering = false
        isSearching = false
        // Assigning the query runs `queryChanged`, which loads the recents and
        // resets the selection — no need to do either twice.
        query = ""
    }

    /// Editing the question means the answer on screen no longer answers it.
    private func markStale() {
        isAnswering = false
    }

    func moveSelection(by delta: Int) {
        let count = rows.count
        guard count > 0 else { return }
        selection = min(max(selection + delta, 0), count - 1)
    }

    private func queryChanged(from previous: String) {
        guard query != previous else { return }
        selection = 0
        markStale()
        searchTask?.cancel()

        let text = question
        guard !text.isEmpty else {
            isSearching = false
            results = recentResults()
            return
        }

        // Local title/summary matches paint immediately; the semantic pass is
        // what takes a round trip, so it merges in behind them rather than
        // holding the whole list back.
        results = localResults(matching: text)
        guard text.count >= Self.minSemanticLength else {
            isSearching = false
            return
        }
        isSearching = true
        searchTask = Task { [weak self] in
            try? await Task.sleep(for: Self.debounce)
            guard !Task.isCancelled else { return }
            await self?.mergeSemanticResults(for: text)
        }
    }

    private func mergeSemanticResults(for text: String) async {
        let hits = await knowledge.searchWithConcepts(query: text)
        guard !Task.isCancelled, question == text else { return }
        let byID = meetings.byID
        var merged = results
        var seen = Set(merged.map(\.id))
        // Concepts first: "Pricing moved to $59 (since 26 Aug)" is a better
        // reason to open a session than the transcript fragment it was
        // distilled from — and it claims the row before the chunk pass can.
        for concept in hits.concepts {
            guard let meetingID = concept.meetingID, seen.insert(meetingID).inserted,
                  let meeting = byID[meetingID] else { continue }
            let dated = concept.validFromLabel.map { "\(concept.body) · \($0)" } ?? concept.body
            merged.append(result(for: meeting, excerpt: dated))
        }
        for chunk in hits.chunks where seen.insert(chunk.meetingID).inserted {
            guard let meeting = byID[chunk.meetingID] else { continue }
            merged.append(result(for: meeting, excerpt: chunk.content))
        }
        results = merged
        isSearching = false
    }

    /// Substring match over what's already loaded — no network, so it can run
    /// on every keystroke. Each hit carries the line it matched on, so the row
    /// shows why it's there rather than making the user open it to find out.
    private func localResults(matching text: String) -> [Result] {
        // Match first, snippet second: building a snippet allocates several
        // copies of the summary, and this runs on every keystroke over every
        // meeting — so it only runs for the ones that actually matched.
        meetings.meetings
            .filter { $0.matches(text) }
            .map { result(for: $0, excerpt: TextSnippet.around(text, in: $0.summary)) }
    }

    private func recentResults() -> [Result] {
        meetings.meetings.prefix(Self.recentCount).map { result(for: $0) }
    }

    private func result(for meeting: Meeting, excerpt: String? = nil) -> Result {
        Result(
            id: meeting.id,
            title: meeting.displayTitle(dateFormatter: Meeting.shortDateFormatter),
            subtitle: Meeting.shortDateFormatter.string(from: meeting.startedAt),
            date: meeting.startedAt,
            icon: meeting.kind.icon,
            excerpt: excerpt.map { $0.replacingOccurrences(of: "\n", with: " ") }
        )
    }
}
