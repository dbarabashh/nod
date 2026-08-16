import AppKit
import Foundation
import Supabase

/// Outbound integrations: which providers the user has linked, and starting the
/// authorization when they haven't.
///
/// Authorization runs in the browser, not in the app — `integration-connect`
/// mints a Nango Connect session and we open the link it returns. The result
/// comes back out of band, through Nango's webhook into
/// `integration_connections`, so after opening the browser the only way to learn
/// the outcome is to watch the table.
@MainActor
final class IntegrationService: ObservableObject {
    @Published private(set) var linked: Set<IntegrationProvider> = []
    /// The products a task can be filed in right now — connected, and able to
    /// take one. Stored rather than computed: it is read from a view body once
    /// per action-item row, and changes only when `linked` does.
    @Published private(set) var taskTargets: [IntegrationProvider] = []
    /// Which team each linked provider is pointed at, when the person has said.
    @Published private(set) var teamByProvider: [IntegrationProvider: UUID] = [:]
    /// Providers the organization has switched off.
    ///
    /// Held as the exceptions rather than the permissions, because that is what
    /// the server stores and why: an organization that has never opened the
    /// setting permits everything, and an empty set here has to mean exactly
    /// that rather than "nothing is allowed yet".
    @Published private(set) var blockedByOrganization: Set<IntegrationProvider> = []
    @Published private(set) var pending: IntegrationProvider?
    /// Which provider's member list is being read right now.
    @Published private(set) var isSyncingDirectory: IntegrationProvider?
    @Published private(set) var isLoading = false
    @Published var lastError: String?

    /// Optional so a preview can hold a service with state and no network,
    /// exactly as `OrganizationService` already does. Every call below is a
    /// no-op without it rather than a crash.
    private let supabase: SupabaseClient?
    private var watch: Task<Void, Never>?
    private var hasLoaded = false

    private enum Unavailable: Error {
        case noClient
    }

    init(supabase: SupabaseClient?) {
        self.supabase = supabase
    }

    deinit {
        watch?.cancel()
    }

    /// Loads the links once per launch. The chat needs to know what's connected
    /// before it can offer any tools, and it can't wait for the user to have
    /// visited Settings first.
    func refreshIfNeeded() async {
        guard !hasLoaded else { return }
        await refresh()
    }

    func refresh() async {
        guard let supabase else { return }
        isLoading = true
        defer { isLoading = false }
        do {
            let rows: [IntegrationConnection] = try await supabase
                .from("integration_connections")
                .select("provider, team_id")
                .is("revoked_at", value: nil)
                .execute()
                .value
            linked = Set(rows.compactMap { IntegrationProvider(rawValue: $0.provider) })
            teamByProvider = rows.reduce(into: [:]) { table, row in
                guard let provider = IntegrationProvider(rawValue: row.provider), let teamID = row.teamID else { return }
                table[provider] = teamID
            }
            blockedByOrganization = await loadBlockedProviders()
            taskTargets = providers(serving: .tasks)
            hasLoaded = true
            lastError = nil
            Log.ui.info("integrations linked=\(linked.map(\.rawValue).sorted().joined(separator: ","))")
        } catch {
            lastError = "Couldn't load your integrations."
            Log.ui.error("IntegrationService.refresh failed: \(error.localizedDescription)")
        }
    }

    /// Whether Nod may act in a product on this account's behalf: the person
    /// linked it, and the organization has not switched it off.
    ///
    /// Both halves, always. The connection is the individual's decision and the
    /// policy is the company's, and neither substitutes for the other.
    func isUsable(_ provider: IntegrationProvider) -> Bool {
        linked.contains(provider) && !blockedByOrganization.contains(provider)
    }

    /// Every usable product that can serve a capability.
    ///
    /// The question the rest of the app asks — "somewhere to file this", "some­
    /// where to talk about this" — rather than "is Slack connected". A company
    /// on Teams or Telegram answers the same question with a different product,
    /// and nothing above this line should have to know which.
    func providers(serving capability: IntegrationCapability) -> [IntegrationProvider] {
        IntegrationProvider.all(serving: capability).filter(isUsable)
    }

    /// Re-reads a connected workspace's member list into the organization.
    ///
    /// Connecting already does this once, which is what makes a company usable
    /// the minute it is set up. This is for afterwards: somebody joined the
    /// workspace, or the tool was connected before the organization existed.
    /// Administrators only, enforced by the server.
    func syncDirectory(_ provider: IntegrationProvider) async -> Int? {
        guard let supabase else { return nil }
        isSyncingDirectory = provider
        defer { isSyncingDirectory = nil }

        struct Request: Encodable { let provider: String }
        struct Response: Decodable {
            struct Failure: Decodable {
                let message: String
            }

            let linked: Int?
            let error: Failure?
        }
        do {
            let response: Response = try await supabase.functions.invoke(
                "directory-sync",
                options: FunctionInvokeOptions(body: Request(provider: provider.rawValue))
            )
            if let failure = response.error {
                lastError = failure.message
                return nil
            }
            lastError = nil
            Log.ui.info("directory synced provider=\(provider.rawValue) linked=\(response.linked ?? 0)")
            return response.linked
        } catch {
            lastError = "Couldn't read that tool's member list."
            Log.ui.error("IntegrationService.syncDirectory failed: \(error.localizedDescription)")
            return nil
        }
    }

    /// The organization's answer for one product, from an administrator's pane.
    func setAllowed(_ allowed: Bool, for provider: IntegrationProvider, in orgID: UUID) async {
        guard let supabase else { return }
        struct Params: Encodable {
            let p_org: UUID
            let p_provider: String
            let p_allowed: Bool
        }
        do {
            _ = try await supabase
                .rpc("set_org_integration_policy", params: Params(
                    p_org: orgID,
                    p_provider: provider.rawValue,
                    p_allowed: allowed
                ))
                .execute()
            if allowed {
                blockedByOrganization.remove(provider)
            } else {
                blockedByOrganization.insert(provider)
            }
            taskTargets = providers(serving: .tasks)
            lastError = nil
            Log.ui.info("integration policy provider=\(provider.rawValue) allowed=\(allowed)")
        } catch {
            lastError = "Couldn't change that for your organization."
            Log.ui.error("IntegrationService.setAllowed failed: \(error.localizedDescription)")
        }
    }

    /// What the organization has turned off. Row-level security scopes this to
    /// the caller's own organizations, so no filter is needed and a personal
    /// account reads nothing.
    ///
    /// Never throws, and that is the point rather than tidiness. No policy means
    /// everything is permitted — the same answer as an organization that has
    /// never opened the setting — so a backend without the table yet has to
    /// produce "nothing is blocked", not "integrations are unavailable".
    /// Letting it throw took `taskTargets` and `hasLoaded` down with it, which
    /// removed the filing marks from every action item and made the client
    /// re-ask on every call: a feature that has not shipped breaking one that
    /// has, which is exactly what deploying a client ahead of its migrations is
    /// supposed to be safe from.
    private func loadBlockedProviders() async -> Set<IntegrationProvider> {
        guard let supabase else { return [] }
        struct Row: Decodable {
            let provider: String
            let isAllowed: Bool

            enum CodingKeys: String, CodingKey {
                case provider
                case isAllowed = "is_allowed"
            }
        }
        do {
            let rows: [Row] = try await supabase
                .from("org_integration_policies")
                .select("provider, is_allowed")
                .eq("is_allowed", value: false)
                .execute()
                .value
            return Set(rows.compactMap { IntegrationProvider(rawValue: $0.provider) })
        } catch {
            Log.ui.error("integration policy unavailable, allowing all: \(error.localizedDescription)")
            return []
        }
    }

    /// Points a connection at one of the caller's teams, or at none.
    ///
    /// The server checks membership: you cannot scope a connection to a team you
    /// are not in, and you cannot scope somebody else's connection at all.
    func setTeam(_ teamID: UUID?, for provider: IntegrationProvider) async {
        guard let supabase else { return }
        do {
            struct Params: Encodable {
                let p_provider: String
                let p_team: UUID?
            }
            _ = try await supabase
                .rpc("set_integration_team", params: Params(p_provider: provider.rawValue, p_team: teamID))
                .execute()
            if let teamID {
                teamByProvider[provider] = teamID
            } else {
                teamByProvider[provider] = nil
            }
            lastError = nil
            Log.ui.info("integration scoped to team provider=\(provider.rawValue)")
        } catch {
            lastError = "Couldn't point that integration at a team."
            Log.ui.error("IntegrationService.setTeam failed: \(error.localizedDescription)")
        }
    }

    /// Opens the provider's authorization page and then watches for the webhook
    /// to land. Safe to call again while one is pending — the previous watch is
    /// replaced rather than stacked.
    func connect(_ provider: IntegrationProvider) async {
        guard let supabase else { return }
        pending = provider
        lastError = nil
        struct Request: Encodable { let provider: String }
        struct Response: Decodable { let connectLink: URL }

        do {
            let response: Response = try await supabase.functions.invoke(
                "integration-connect",
                options: FunctionInvokeOptions(body: Request(provider: provider.rawValue))
            )
            Log.ui.info("IntegrationService.connect opening authorization for \(provider.rawValue)")
            NSWorkspace.shared.open(response.connectLink)
            watchForConnection(provider)
        } catch {
            pending = nil
            lastError = "Couldn't start authorization. Please try again."
            Log.ui.error("IntegrationService.connect failed: \(error.localizedDescription)")
        }
    }

    /// Ends a connection, at the provider and here.
    ///
    /// Optimistic about nothing: the row is only forgotten locally once the
    /// server says the authorization is gone. A button that clears the checkmark
    /// while the grant survives is the worst possible outcome for this action.
    func disconnect(_ provider: IntegrationProvider) async -> Bool {
        guard let supabase else { return false }
        struct Request: Encodable { let provider: String }
        do {
            _ = try await supabase.functions.invoke(
                "integration-disconnect",
                options: FunctionInvokeOptions(body: Request(provider: provider.rawValue)),
                decode: { data, _ in data }
            )
            linked.remove(provider)
            teamByProvider[provider] = nil
            taskTargets = linked
                .filter { $0.taskActions != nil }
                .sorted { $0.rawValue < $1.rawValue }
            lastError = nil
            Log.ui.info("integration disconnected \(provider.rawValue)")
            return true
        } catch {
            lastError = "Couldn't disconnect \(provider.displayName). Please try again."
            Log.ui.error("IntegrationService.disconnect failed: \(error.localizedDescription)")
            return false
        }
    }

    /// Files a draft the user has seen and had the chance to change.
    ///
    /// Takes the draft rather than the item: what a task says is composed and
    /// approved before this is called, and re-deriving anything here would mean
    /// sending something other than what was on screen.
    func file(_ draft: TaskDraft, in provider: IntegrationProvider) async -> ProviderLinkItem? {
        guard let action = provider.taskActions?.create else { return nil }
        return await createTask(
            title: draft.title,
            description: draft.description.isEmpty ? nil : draft.description,
            in: provider,
            action: action
        )
    }

    /// Files a task and returns where it landed.
    ///
    /// Not routed through the chat's tool approval: that gate exists because a
    /// model decided to act. Here the user clicked a specific item, which is the
    /// decision — asking again would be confirming what they just did.
    private func createTask(
        title: String,
        description: String?,
        in provider: IntegrationProvider,
        action: String
    ) async -> ProviderLinkItem? {
        struct FiledTask: Decodable {
            let key: String
            let title: String
            let url: String
        }
        struct Response: Decodable {
            let result: FiledTask?
        }

        var params = ["title": title]
        if let description, !description.isEmpty { params["description"] = description }

        do {
            let data = try await invokeAction(provider: provider, action: action, params: params)
            let body = String(bytes: data, encoding: .utf8) ?? ""
            if let message = Self.failure(in: body) {
                Log.ui.error("IntegrationService.file refused: \(message)")
                return nil
            }
            guard let filed = try? JSONDecoder().decode(Response.self, from: data).result,
                  let url = URL(string: filed.url)
            else { return nil }
            Log.ui.info("IntegrationService.file filed \(filed.key)")
            return ProviderLinkItem(provider: provider, title: filed.key, url: url)
        } catch {
            Log.ui.error("IntegrationService.file failed: \(error.localizedDescription)")
            return nil
        }
    }

    /// Mirrors a tick in Nod onto the task it was filed as.
    ///
    /// The other half of `closedFilings`. With both, a filed item has one state
    /// rather than two that drift: closing it in either place closes it in the
    /// other, which is what lets the status read run unconditionally instead of
    /// tiptoeing around ticks it might undo.
    func setTaskClosed(_ closed: Bool, reference: ProviderLinkItem) async {
        guard let action = reference.provider.taskActions?.update else { return }
        do {
            let data = try await invokeAction(
                provider: reference.provider,
                action: action,
                params: ["key": reference.title, "closed": closed ? "true" : "false"]
            )
            if let message = Self.failure(in: String(bytes: data, encoding: .utf8) ?? "") {
                Log.ui.error("IntegrationService.setTaskClosed refused: \(message)")
                return
            }
            Log.ui.info("IntegrationService.setTaskClosed \(reference.title) closed=\(closed)")
        } catch {
            Log.ui.error("IntegrationService.setTaskClosed failed: \(error.localizedDescription)")
        }
    }

    /// Adds what this meeting said to a task that already exists.
    ///
    /// The other half of filing, and the one that stops a tracker filling with
    /// near-duplicates: a conversation about work already ticketed is an update
    /// to that ticket, not a second one. The note is appended, never swapped in
    /// — a description is somebody's writing, and a meeting has no business
    /// overwriting it.
    func update(_ reference: ProviderLinkItem, note: String) async -> Bool {
        guard let action = reference.provider.taskActions?.update else { return false }
        let trimmed = note.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        do {
            let data = try await invokeAction(
                provider: reference.provider,
                action: action,
                params: ["key": reference.title, "note": trimmed]
            )
            if let message = Self.failure(in: String(bytes: data, encoding: .utf8) ?? "") {
                Log.ui.error("IntegrationService.update refused: \(message)")
                return false
            }
            Log.ui.info("IntegrationService.update appended to \(reference.title)")
            return true
        } catch {
            Log.ui.error("IntegrationService.update failed: \(error.localizedDescription)")
            return false
        }
    }

    /// A task already in the product that says the same thing as this item.
    ///
    /// `external_key` stops the same *row* being filed twice; this is the other
    /// duplicate — two meetings about one commitment, two rows, two tickets. The
    /// tracker is the only place that knows, because the first ticket may have
    /// been typed by hand and never have passed through Nod at all.
    ///
    /// Answers with a candidate, never a decision: `ActionItemDedup.same` is the
    /// same test the app uses for its own cross-meeting flags, and it is trusted
    /// exactly as far — enough to ask, not enough to link on its own. A search
    /// that fails returns nothing, so filing degrades to creating rather than
    /// stopping.
    func existingTask(for item: ActionItem, in provider: IntegrationProvider) async -> TaskMatch? {
        guard let action = provider.taskActions?.search else { return nil }
        let candidates = await taskSearch(query: item.text, in: provider, action: action)
            .filter { ActionItemDedup.same($0.title, item.text) }
        // An open ticket is the one worth linking to. A closed match is still
        // offered — the work may simply be done — but it loses to a live one.
        guard let match = candidates.first(where: { !$0.closed }) ?? candidates.first,
              let url = URL(string: match.url)
        else { return nil }
        return TaskMatch(
            reference: ProviderLinkItem(provider: provider, title: match.key, url: url),
            summary: match.title,
            closed: match.closed
        )
    }

    private func taskSearch(
        query: String,
        in provider: IntegrationProvider,
        action: String
    ) async -> [FoundTask] {
        struct Response: Decodable {
            struct Tasks: Decodable {
                let tasks: [FoundTask]
            }

            let result: Tasks?
        }

        do {
            let data = try await invokeAction(provider: provider, action: action, params: ["query": query])
            if let message = Self.failure(in: String(bytes: data, encoding: .utf8) ?? "") {
                Log.ui.error("IntegrationService.taskSearch refused: \(message)")
                return []
            }
            return (try? JSONDecoder().decode(Response.self, from: data))?.result?.tasks ?? []
        } catch {
            Log.ui.error("IntegrationService.taskSearch failed: \(error.localizedDescription)")
            return []
        }
    }

    private struct FoundTask: Decodable {
        let key: String
        let title: String
        let url: String
        let closed: Bool
    }

    /// Where every filed item stands in the product it was filed in.
    ///
    /// Both directions, which only became safe once `setTaskClosed` existed: a
    /// tick made here is already on its way there, so reading the answer back
    /// can no longer undo it. Before that, mirroring "still open" would have
    /// unticked the box a minute after the user ticked it.
    ///
    /// Reports what the tracker says, not what changed — the caller holds the
    /// local state and is the one that can tell the difference. Items the
    /// tracker didn't answer for are absent rather than assumed open, so a
    /// deleted ticket leaves its item exactly as the user last had it.
    ///
    /// Throttled rather than driven by a timer: the caller is app activation,
    /// which fires on every window focus, and a tracker's answer does not change
    /// between two of those.
    func remoteCompletions(among items: [ActionItem]) async -> [UUID: Bool] {
        let now = Date()
        if let lastStatusRead, now.timeIntervalSince(lastStatusRead) < Self.statusInterval { return [:] }
        await refreshIfNeeded()

        var keyedByProvider: [IntegrationProvider: [String: UUID]] = [:]
        for item in items {
            guard let raw = item.externalProvider,
                  let provider = IntegrationProvider(rawValue: raw),
                  linked.contains(provider),
                  let key = item.externalKey
            else { continue }
            keyedByProvider[provider, default: [:]][key] = item.id
        }
        guard !keyedByProvider.isEmpty else { return [:] }
        lastStatusRead = now

        var states: [UUID: Bool] = [:]
        for (provider, keyed) in keyedByProvider {
            guard let action = provider.taskActions?.readStatus else { continue }
            let keys = Array(keyed.keys)
            for start in stride(from: 0, to: keys.count, by: Self.statusBatch) {
                let batch = Array(keys[start ..< min(start + Self.statusBatch, keys.count)])
                for state in await taskStates(keys: batch, in: provider, action: action) {
                    if let id = keyed[state.key] { states[id] = state.closed }
                }
            }
        }
        return states
    }

    /// Matches `STATUS_LIMIT` in the Linear handler — the batch is what the
    /// provider will accept in one call, not a preference.
    private static let statusBatch = 50
    private static let statusInterval: TimeInterval = 60
    private var lastStatusRead: Date?

    private func taskStates(
        keys: [String],
        in provider: IntegrationProvider,
        action: String
    ) async -> [TaskState] {
        struct Response: Decodable {
            struct Tasks: Decodable {
                let tasks: [TaskState]
            }

            let result: Tasks?
        }

        do {
            let data = try await invokeAction(
                provider: provider,
                action: action,
                params: ["keys": keys.joined(separator: ",")]
            )
            if let message = Self.failure(in: String(bytes: data, encoding: .utf8) ?? "") {
                Log.ui.error("IntegrationService.taskStates refused: \(message)")
                return []
            }
            return (try? JSONDecoder().decode(Response.self, from: data))?.result?.tasks ?? []
        } catch {
            Log.ui.error("IntegrationService.taskStates failed: \(error.localizedDescription)")
            return []
        }
    }

    /// One task's state, in the vocabulary every provider answers in.
    private struct TaskState: Decodable {
        let key: String
        let closed: Bool
    }

    func cancelPending() {
        watch?.cancel()
        watch = nil
        pending = nil
    }

    /// Polls until the provider shows up or the session's own lifetime is spent.
    /// Nango connect links expire in 30 minutes, but a user who wandered off is
    /// better served by the row appearing on the next `refresh()` than by us
    /// polling for half an hour.
    private func watchForConnection(_ provider: IntegrationProvider) {
        watch?.cancel()
        watch = Task { [weak self] in
            for _ in 0 ..< Self.watchAttempts {
                try? await Task.sleep(nanoseconds: Self.watchInterval)
                if Task.isCancelled { return }
                guard let self else { return }
                await refresh()
                if linked.contains(provider) {
                    pending = nil
                    return
                }
            }
            self?.pending = nil
        }
    }

    /// Runs an approved tool call against `integration-action`.
    ///
    /// Never throws: a failure the model can act on — not connected, several
    /// teams, the provider said no — is worth more as a readable result than as
    /// a broken turn. A thrown error would end the agent's turn and lose the
    /// question.
    func run(_ call: ChatToolCall, tool: ChatTool) async -> String {
        do {
            let response = try await invokeAction(
                provider: tool.provider,
                action: tool.action,
                params: call.arguments
            )
            Log.llm.info("tool \(tool.name) returned \(response.count) bytes")
            return String(bytes: response, encoding: .utf8) ?? Self.unreadableResult
        } catch {
            Log.llm.error("tool \(tool.name) failed: \(error.localizedDescription)")
            return #"{"error":{"code":"unreachable","message":"The action could not be run."}}"#
        }
    }

    /// The one door to `integration-action`.
    ///
    /// Handed back raw: the body is whatever the provider returned. The chat
    /// gives it to the model as text; the filing button decodes it. Typing it
    /// here would mean re-encoding a line later for one caller, and a shape
    /// mismatch would throw away a result the other could have used.
    private func invokeAction(
        provider: IntegrationProvider,
        action: String,
        params: [String: String]
    ) async throws -> Data {
        guard let supabase else { throw Unavailable.noClient }
        struct Request: Encodable {
            let provider: String
            let action: String
            let params: [String: String]
        }
        return try await supabase.functions.invoke(
            "integration-action",
            options: FunctionInvokeOptions(
                body: Request(provider: provider.rawValue, action: action, params: params)
            ),
            decode: { data, _ in data }
        )
    }

    private static let unreadableResult = #"{"error":{"code":"unreadable","message":"The action returned something unreadable."}}"#

    /// The message from an error the action returned, if it returned one. The
    /// wire shape is `{"error":{"code","message"}}` — a failed call still comes
    /// back as a readable result, so this is how the trace tells "did nothing"
    /// from "did something".
    static func failure(in result: String) -> String? {
        guard let data = result.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let error = object["error"] as? [String: Any]
        else { return nil }
        return error["message"] as? String ?? "The action failed."
    }

    /// The result for a call the user refused. The model still needs *an* answer
    /// for every call it made — a missing one makes the next request invalid —
    /// and telling it the user declined is what stops it from trying again.
    static func declinedResult() -> String {
        #"{"error":{"code":"declined","message":"The user declined this action. Do not retry it; answer with what you already know."}}"#
    }

    private static let watchAttempts = 60
    private static let watchInterval: UInt64 = 2_000_000_000
}

#if DEBUG
    extension IntegrationService {
        static func preview(linked: Set<IntegrationProvider> = []) -> IntegrationService {
            let service = IntegrationService(supabase: nil)
            service.linked = linked
            service.taskTargets = linked.filter { $0.taskActions != nil }.sorted { $0.rawValue < $1.rawValue }
            service.hasLoaded = true
            return service
        }
    }
#endif
