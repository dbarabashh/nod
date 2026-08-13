import Foundation

/// What will be created in the tracker, before it is created.
///
/// Editable because the model is drafting from a fragment of a conversation and
/// the person clicking has the rest of it. Two fields rather than a rendered
/// blob: they map to what every tracker takes, and to what the user is allowed
/// to change.
struct TaskDraft: Equatable {
    var title: String
    var description: String
}

/// Composes an action item into a task worth reading, using the meeting it came
/// from.
///
/// Separate from `IntegrationService` on purpose: what a task *says* is a
/// question about the meeting, and what happens to it afterwards is a question
/// about a provider. Keeping them apart is also what lets the draft be shown,
/// edited and discarded without any provider ever hearing about it.
@MainActor
final class TaskDraftComposer: ObservableObject {
    private let llm: LLMProxyClient
    private let meetings: MeetingStore
    private let language: LanguagePreference

    init(llm: LLMProxyClient, meetings: MeetingStore, language: LanguagePreference) {
        self.llm = llm
        self.meetings = meetings
        self.language = language
    }

    /// Trackers show titles in one line, and a model told to be brief still
    /// occasionally isn't.
    private static let titleLimit = 120
    /// Transcript entries either side of the one that produced the item. Wide
    /// enough for the exchange that led to the commitment, narrow enough that
    /// the draft is about this task and not about the meeting.
    private static let excerptRadius = 12

    func draft(for item: ActionItem) async -> TaskDraft {
        let meeting = meetings.meetings.first { $0.id == item.meetingID }
        let fallback = Self.fallback(for: item)

        do {
            let (system, user) = await PromptLibrary.buildTaskDraft(
                item: item.text,
                deadline: item.deadline?.nilIfBlank,
                meetingTitle: meeting?.displayTitle(dateFormatter: Meeting.shortDateFormatter) ?? "an earlier session",
                meetingDate: meeting.map { Meeting.shortDateFormatter.string(from: $0.startedAt) } ?? "",
                excerpt: excerpt(for: item),
                summary: meeting?.summary ?? "",
                language: language.current
            )
            let result = try await llm.completeJSON(
                system: system,
                user: user,
                as: PromptLibrary.TaskDraftResult.self
            )
            let title = result.title.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !title.isEmpty else { return fallback }
            return TaskDraft(
                title: String(title.prefix(Self.titleLimit)),
                description: result.description.trimmingCharacters(in: .whitespacesAndNewlines)
            )
        } catch {
            // A draft that failed is not a filing that failed: the sheet opens on
            // the item's own words, which is exactly what filing used to send.
            Log.llm.error("TaskDraftComposer.draft failed: \(error.localizedDescription)")
            return fallback
        }
    }

    /// What was being said around the line that produced this item.
    ///
    /// `evidenceIdx` is the whole reason this is cheap and specific — without it
    /// the alternative is summarising a meeting to write one ticket. An item
    /// from the live pass may not have one, and then the summary carries the
    /// draft alone.
    private func excerpt(for item: ActionItem) async -> String {
        guard let idx = item.evidenceIdx else { return "" }
        do {
            let records = try await meetings.fetchTranscript(meetingID: item.meetingID)
            let window = records.filter { abs($0.idx - idx) <= Self.excerptRadius }
            let names = meetings.meetings.first { $0.id == item.meetingID }?.speakerNames ?? [:]
            return window
                .sorted { $0.idx < $1.idx }
                .map { record in
                    let who = record.speaker.flatMap { names[String($0)] ?? "Speaker \($0)" } ?? "Me"
                    return "\(who): \(record.text)"
                }
                .joined(separator: "\n")
        } catch {
            Log.llm.error("TaskDraftComposer excerpt failed: \(error.localizedDescription)")
            return ""
        }
    }

    /// The draft filing produced before there was a draft: the item's text, and
    /// the deadline in the words it was said in.
    private static func fallback(for item: ActionItem) -> TaskDraft {
        var body: [String] = []
        if item.text.count > titleLimit { body.append(item.text) }
        if let deadline = item.deadline?.nilIfBlank { body.append("Due: \(deadline)") }
        return TaskDraft(
            title: String(item.text.prefix(titleLimit)),
            description: body.joined(separator: "\n\n")
        )
    }
}

private extension String {
    var nilIfBlank: String? {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
