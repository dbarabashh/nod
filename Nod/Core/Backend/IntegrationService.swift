import AppKit
import Foundation
import Supabase

/// Outbound integrations: which providers the user has linked, and starting the
/// authorization when they haven't.
///
/// Authorization runs in the browser, not in the app — `integration-connect`
/// mints a Connect token and we open the link it returns. The result comes back
/// out of band: the broker signs nothing, so `integration-reconcile` is what
/// reads the outcome from the broker and writes `integration_connections`. After
/// opening the browser the only way to learn the outcome is to ask it and watch
/// the table.
@MainActor
final class IntegrationService: ObservableObject {
    @Published private(set) var linked: Set<IntegrationProvider> = []
    /// Products authorized from the catalogue that Nod has no adapters for,
    /// by the broker's own slug.
    ///
    /// A separate set rather than more cases on `IntegrationProvider`: that type
    /// carries a bundled mark, capability copy and the actions a chat may offer,
    /// none of which exist for a product nobody has written an adapter for. What
    /// these have is a grant, and the only things that can be done with one are
    /// to show it and to end it.
    @Published private(set) var linkedApps: Set<String> = []
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
    /// Reports linking and unlinking. Assigned by the composition root after
    /// the analytics client exists — this service is built before it — and nil
    /// in a preview, the same way `supabase` is.
    var analytics: ProductAnalytics?
    private var watch: Task<Void, Never>?
    /// Whether the first read has landed. Published because the home screen's
    /// "connect your tools" card must not appear in the gap before it: the set
    /// starts empty, so an unguarded check flashes an empty state at somebody
    /// who connected four products last month.
    @Published private(set) var hasLoaded = false

    /// When the links were last read, for `refreshIfNeeded`.
    private var loadedAt: Date?

    private enum Unavailable: Error {
        case noClient
    }

    init(supabase: SupabaseClient?) {
        self.supabase = supabase
    }

    deinit {
        watch?.cancel()
    }

    /// Loads the links, and reloads them once the last answer has gone stale.
    ///
    /// This was once per launch, and a connection that landed outside the
    /// two-minute window `watchForConnection` polls for stayed invisible until
    /// the app was quit: Settings said connected, the chat offered nothing, and
    /// nothing in between ever asked again. That window is missed by an
    /// authorization the person finished slowly, by one they finished on
    /// another device, and by a broker webhook that was simply late.
    ///
    /// A staleness check rather than a notification: `didBecomeActive` is the
    /// obvious hook and the wrong one here, because the panel is
    /// non-activating and this app can go a whole session without ever becoming
    /// active — the same reason `ScreenContextService` had to poll for its
    /// Accessibility grant.
    func refreshIfNeeded() async {
        guard Self.isStale(loadedAt: loadedAt, now: Date()) else { return }
        await refresh()
    }

    /// Long enough that opening the chat repeatedly costs one query a minute,
    /// short enough that somebody who just connected something and came back to
    /// the window does not think it failed.
    static let freshness: TimeInterval = 60

    static func isStale(loadedAt: Date?, now: Date) -> Bool {
        guard let loadedAt else { return true }
        return now.timeIntervalSince(loadedAt) >= freshness
    }

    /// What a chat may offer the model this turn. Both chats ask the same
    /// question and must get the same answer — the catalogue has to match
    /// between the prompt that describes it, the request that carries it, and
    /// the match that checks a call against it.
    ///
    /// Usable rather than linked: a product the organization switched off is
    /// absent from the mention picker, and offering the model tools for it
    /// meant the policy held everywhere a person could see it and nowhere the
    /// model could act.
    func chatTools() async -> [ChatTool] {
        await refreshIfNeeded()
        return ChatTools.definitions(for: linked.filter(isUsable))
    }

    /// Drops what the previous account had connected.
    ///
    /// `hasLoaded` with it, for the reason `refreshIfNeeded` exists: left true,
    /// the next person to sign in is offered the last one's Linear in the
    /// mention picker and in every live lookup, and no fetch of their own ever
    /// runs.
    func clear() {
        linked = []
        linkedApps = []
        taskTargets = []
        teamByProvider = [:]
        blockedByOrganization = []
        pending = nil
        lastError = nil
        hasLoaded = false
        loadedAt = nil
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
            await reportLinkChanges()
            linkedApps = Set(rows.map(\.provider).filter { IntegrationProvider(rawValue: $0) == nil })
            teamByProvider = rows.reduce(into: [:]) { table, row in
                guard let provider = IntegrationProvider(rawValue: row.provider), let teamID = row.teamID else { return }
                table[provider] = teamID
            }
            blockedByOrganization = await loadBlockedProviders()
            taskTargets = filingTargets()
            hasLoaded = true
            loadedAt = Date()
            lastError = nil
            Log.ui.info("integrations linked=\(linked.map(\.rawValue).sorted().joined(separator: ","))")
        } catch {
            lastError = "Couldn't load your integrations."
            Log.ui.error("IntegrationService.refresh failed: \(error.localizedDescription)")
        }
    }

    /// Reports what changed since the last time this account was looked at, in
    /// both directions, and remembers the new set.
    ///
    /// Against a stored snapshot rather than the previous in-memory value, for
    /// two reasons the in-memory version got wrong. A connection finishes in a
    /// browser and lands through a webhook — if the app was closed while that
    /// happened, the next launch saw it as part of its own baseline and never
    /// counted it. And a grant revoked at Slack or Google rather than here just
    /// stopped appearing, so adoption could only ever rise: the graph went up
    /// monotonically while people were leaving.
    ///
    /// Keyed by account. The same Mac carries more than one, and the last one's
    /// products are not this one's news.
    ///
    /// A user with no snapshot is establishing a baseline, not connecting nine
    /// things at once — the first look is silent.
    private func reportLinkChanges() async {
        guard let userID = try? await supabase?.auth.session.user.id else { return }
        let key = "integrations.known.\(userID.uuidString)"
        let current = Set(linked.map(\.rawValue))
        defer { UserDefaults.standard.set(Array(current).sorted(), forKey: key) }

        guard let stored = UserDefaults.standard.stringArray(forKey: key) else { return }
        let change = Self.linkChanges(known: Set(stored), current: current)
        change.connected.forEach { reportLink(.integrationConnected, $0) }
        change.revoked.forEach { reportLink(.integrationRevoked, $0) }
    }

    /// What moved between two sets of linked products. Sorted, so the events a
    /// single reconcile emits arrive in a stable order rather than a hash one.
    nonisolated static func linkChanges(
        known: Set<String>,
        current: Set<String>
    ) -> (connected: [String], revoked: [String]) {
        (current.subtracting(known).sorted(), known.subtracting(current).sorted())
    }

    private func reportLink(_ event: ProductAnalytics.Event, _ provider: String) {
        analytics?.record(event, properties: .init(surface: .settings, provider: provider))
    }

    /// Whether Nod may act in a product on this account's behalf: the person
    /// linked it, and the organization has not switched it off.
    ///
    /// Both halves, always. The connection is the individual's decision and the
    /// policy is the company's, and neither substitutes for the other.
    func isUsable(_ provider: IntegrationProvider) -> Bool {
        linked.contains(provider) && !blockedByOrganization.contains(provider)
    }

    /// Every product Nod may act in right now.
    ///
    /// The plural of `isUsable`, stated once because more than one surface
    /// draws it and they have to draw the same list: a row of marks under a
    /// composer and the placeholder above it disagreed about whether there was
    /// anything to name.
    var usable: [IntegrationProvider] {
        IntegrationProvider.allCases.filter(isUsable)
    }

    /// Every usable product that can serve a capability.
    ///
    /// The question the rest of the app asks — "somewhere to file this", "some­
    /// where to talk about this" — rather than "is Slack connected". A company
    /// on Teams or Telegram answers the same question with a different product,
    /// and nothing above this line should have to know which.
    /// Where an action item can actually be filed.
    ///
    /// Asked of `taskActions`, not of the `.tasks` capability: a tracker Nod can
    /// only read serves that capability and has nowhere to put anything. The
    /// disconnect path already derived it this way, and the two answers
    /// disagreed the moment a read-only tracker existed.
    private func filingTargets() -> [IntegrationProvider] {
        linked
            .filter { isUsable($0) && $0.taskActions != nil }
            .sorted { $0.rawValue < $1.rawValue }
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
            taskTargets = filingTargets()
            lastError = nil
            Log.ui.info("integration policy provider=\(provider.rawValue) allowed=\(allowed)")
        } catch {
            lastError = "Couldn't change that for your organization."
            Log.ui.error("IntegrationService.setAllowed failed: \(error.localizedDescription)")
        }
    }

    /// What the caller's organizations have turned off.
    ///
    /// A server answer rather than a client derivation. Reading the policy rows
    /// directly worked, but only because this leant on that table's row-level
    /// security to supply the membership half of the rule — two predicates
    /// maintained apart, and a tool drawn as available that the server then
    /// refuses is the failure this whole check exists to prevent. The rule now
    /// lives once, in `my_blocked_providers`.
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
        }
        do {
            let rows: [Row] = try await supabase
                .rpc("my_blocked_providers")
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
            taskTargets = filingTargets()
            lastError = nil
            await reportLinkChanges()
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
    func file(
        _ draft: TaskDraft,
        in provider: IntegrationProvider,
        extra: [String: String] = [:]
    ) async -> ProviderLinkItem? {
        guard let action = provider.taskActions?.create else { return nil }
        return await createTask(
            title: draft.title,
            description: draft.description.isEmpty ? nil : draft.description,
            in: provider,
            action: action,
            extra: extra
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
        action: String,
        extra: [String: String] = [:]
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
        params.merge(extra) { current, _ in current }

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
    /// `alsoMatching` is a second phrasing of the same work — the drafted
    /// title, usually — because the ticket that already exists was created
    /// from the draft's words, not the transcript's, and searching only the
    /// transcript's is how the twin slips past.
    func existingTask(
        for item: ActionItem,
        in provider: IntegrationProvider,
        alsoMatching phrasing: String? = nil
    ) async -> TaskMatch? {
        guard let action = provider.taskActions?.search else { return nil }
        var found = await taskSearch(query: item.text, in: provider, action: action)
        if let phrasing, !phrasing.isEmpty, !ActionItemDedup.same(phrasing, item.text) {
            let more = await taskSearch(query: phrasing, in: provider, action: action)
            found += more.filter { candidate in !found.contains(where: { $0.key == candidate.key }) }
        }
        let candidates = found
            .filter { candidate in
                ActionItemDedup.same(candidate.title, item.text) ||
                    (phrasing.map { ActionItemDedup.same(candidate.title, $0) } ?? false)
            }
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
    /// A connect link is short-lived, but a user who wandered off is better
    /// served by the row appearing on the next `refresh()` than by us polling
    /// for half an hour.
    ///
    /// Reconciles before each read rather than waiting to be told. The broker's
    /// connection webhook carries no signature, so it can never be the thing we
    /// trust — and a flow that waited for it would leave the person staring at
    /// "Connecting…" whenever it was slow or dropped.
    private func watchForConnection(_ provider: IntegrationProvider) {
        watch?.cancel()
        watch = Task { [weak self] in
            for _ in 0 ..< Self.watchAttempts {
                try? await Task.sleep(nanoseconds: Self.watchInterval)
                if Task.isCancelled { return }
                guard let self else { return }
                await reconcile()
                await refresh()
                if linked.contains(provider) {
                    pending = nil
                    return
                }
            }
            self?.pending = nil
        }
    }

    /// Asks the server to re-read what the broker holds for this account.
    ///
    /// Silent on failure by design: it runs on a timer beside `refresh()`, and a
    /// broker that did not answer this second is not something to tell the user
    /// about — the next tick asks again.
    private func reconcile() async {
        guard let supabase else { return }
        do {
            try await supabase.functions.invoke("integration-reconcile")
        } catch {
            Log.ui.debug("integration reconcile failed: \(error.localizedDescription)")
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
