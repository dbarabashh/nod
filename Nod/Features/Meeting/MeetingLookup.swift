import Foundation

/// Answers one spoken request out of the tools the user has connected.
///
/// Read-only, and that is a property of this type rather than of a policy
/// somewhere: it filters to `!tool.mutating` before the model ever sees the
/// catalogue, so there is no prompt to talk round and no round trip that could
/// write. Every call the chat makes is confirmed by hand first; this one is not
/// confirmed by anybody, and the only reason that is safe is that it cannot
/// change anything.
///
/// Its own type rather than more of `LiveMeetingAnalyst`, for the reason
/// `ProposalRaiser` is its own type: the analyst is about what the room said,
/// and this is about what the user connected. They fail differently, and an
/// account with no integrations should make this produce nothing at all rather
/// than make the analyst quieter.
@MainActor
struct MeetingLookup {
    let llm: LLMProxyClient
    let integrations: IntegrationService
    let language: LanguagePreference
    /// Which earlier sessions to search, asked at the moment of the request —
    /// a meeting can be filed into a project while it is still running.
    let scope: () -> LookupScope
    /// Turns a session id into "Product Sync · Aug 8". The same injection
    /// `LiveMeetingAnalyst.recallSourceLabel` takes, and for the same reason:
    /// an answer from memory that cannot be placed is one nobody can check.
    let sessionLabel: (UUID) -> String?

    func answer(_ request: String) async -> LiveLookup.State {
        // Both, at once. A tool call and a vector search have nothing to say to
        // each other, so running them in sequence would spend the slower one's
        // latency twice — and this is the surface where a second of silence is
        // the whole cost.
        async let tooling = runTool(for: request)
        async let remembered = recall(request)
        let (ran, memory) = await (tooling, remembered)

        // Nothing to work from at all. Distinguished from "found nothing" so
        // the card can say which, because they mean different things to somebody
        // deciding whether to connect a tool.
        if ran == nil, memory.isEmpty {
            return await integrations.chatTools().isEmpty ? .refused(.noProvider) : .empty
        }
        if case .failed? = ran, memory.isEmpty { return .failed }

        guard let written = await phrase(request, ran: ran, memory: memory.map(\.text)) else { return .failed }
        let text = written.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return .empty }

        // The mark follows what the answer actually used, not what was fetched.
        let usedTool = written.usedTool ?? (ran?.tool != nil)
        return .answered(
            LiveLookup.Answer(
                text: text,
                provider: usedTool ? ran?.tool?.provider : nil,
                subject: written.subject?.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty
                    ?? (usedTool ? nil : memory.first?.source),
                readAt: Date()
            )
        )
    }

    /// What a tool run came back with. `nil` means no tool was chosen at all,
    /// which is not a failure — plenty of questions are answered from memory.
    private enum ToolRun {
        case succeeded(ChatTool, String)
        case failed

        var tool: ChatTool? {
            if case let .succeeded(tool, _) = self { tool } else { nil }
        }

        var result: String? {
            if case let .succeeded(_, result) = self { result } else { nil }
        }
    }

    private func runTool(for request: String) async -> ToolRun? {
        // The gate, before the catalogue is built rather than after: a mutating
        // tool is never named to the model, so it can never be chosen.
        let readable = await integrations.chatTools().filter { !$0.mutating }
        guard !readable.isEmpty else { return nil }
        guard let (tool, arguments) = await route(request, among: readable) else { return nil }

        let call = ChatToolCall(
            id: UUID().uuidString,
            type: "function",
            function: ChatToolCall.Function(name: tool.name, arguments: arguments)
        )
        let result = await integrations.run(call, tool: tool)
        guard !result.isEmpty, !result.contains("\"error\"") else { return .failed }
        return .succeeded(tool, result)
    }

    /// An excerpt from an earlier session, with somewhere to put it.
    private struct Remembered {
        let text: String
        let source: String?
    }

    /// What earlier sessions said about this.
    ///
    /// Scoped when the meeting is filed or recurs, unscoped when it is neither
    /// — see `LookupScope` for why widening is safe. The floor is the recall
    /// pass's own: below it retrieval had nothing worth paying a model to read.
    private func recall(_ request: String) async -> [Remembered] {
        let scope = scope()
        do {
            let matches = try await llm.searchKnowledge(
                query: request,
                matchCount: Self.memoryMatches,
                meetingIDs: scope.meetingIDs
            )
            .filter { $0.similarity >= LiveMeetingAnalyst.recallFloor }
            Log.llm.info("live: lookup memory scope=\(scope.label ?? "all") hits=\(matches.count)")
            return matches.map { Remembered(text: $0.content, source: sessionLabel($0.meetingID)) }
        } catch {
            // Memory failing is not the lookup failing: a tool may still answer.
            Log.llm.error("live: lookup memory failed — \(error.localizedDescription)")
            return []
        }
    }

    /// Enough to answer from, few enough that the card's one model call stays
    /// short. The recall pass uses six to pick one; this reads all of them.
    private static let memoryMatches = 4

    /// Which provider a request would reach, before running anything — so a
    /// card can name what it is waiting on while it waits.
    func provider(for request: String) async -> IntegrationProvider? {
        let readable = await integrations.chatTools().filter { !$0.mutating }
        return await route(request, among: readable)?.0.provider
    }

    private func route(_ request: String, among tools: [ChatTool]) async -> (ChatTool, String)? {
        let (system, user) = PromptLibrary.buildLookupRouting(request: request, tools: tools)
        let choice: PromptLibrary.LookupChoice
        do {
            choice = try await llm.completeJSON(
                system: system,
                user: user,
                as: PromptLibrary.LookupChoice.self,
                primaryModel: llm.utilityModel
            )
        } catch {
            Log.llm.error("lookup routing failed: \(error.localizedDescription)")
            return nil
        }
        guard let name = choice.tool, let tool = tools.first(where: { $0.name == name }) else { return nil }
        // Re-checked against the catalogue this call was built from. The model
        // is asked for a name and answers with a string; a name that is not in
        // the list it was given is not a tool, whatever it looks like.
        guard let arguments = Self.encode(choice.arguments ?? [:]) else { return nil }
        return (tool, arguments)
    }

    private func phrase(
        _ request: String,
        ran: ToolRun?,
        memory: [String]
    ) async -> PromptLibrary.LookupAnswer? {
        let (system, user) = PromptLibrary.buildLookupAnswer(
            request: request,
            toolName: ran?.tool?.name,
            result: ran?.result,
            memory: memory,
            language: language.current
        )
        do {
            return try await llm.completeJSON(
                system: system,
                user: user,
                as: PromptLibrary.LookupAnswer.self,
                primaryModel: llm.utilityModel
            )
        } catch {
            Log.llm.error("lookup phrasing failed: \(error.localizedDescription)")
            return nil
        }
    }

    private static func encode(_ arguments: [String: String]) -> String? {
        guard let data = try? JSONEncoder().encode(arguments) else { return nil }
        return String(data: data, encoding: .utf8)
    }
}

private extension String {
    var nonEmpty: String? {
        isEmpty ? nil : self
    }
}
