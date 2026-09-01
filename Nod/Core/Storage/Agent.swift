import Combine
import Foundation
import Supabase

/// A declared record that runs a saved question when its trigger fires —
/// never generated code, and in v1 never anything but reading.
///
/// Wire-compatible with `public.agents`. The only trigger this build speaks is
/// `after_meeting`: the Mac that just recorded a session is awake by
/// definition, so the run needs no schedule and no claim race. Time-triggered
/// agents already exist and are called beats.
struct Agent: Codable, Identifiable, Equatable {
    /// The spec this build knows how to execute. An agent whose row claims a
    /// newer version is refused, not half-run: a half-understood agent still
    /// acts, which is worse than one that waits for the build that speaks it.
    static let supportedSpecVersion = 1

    enum TriggerKind: String, Codable {
        case afterMeeting = "after_meeting"
    }

    enum Speaks: String, Codable {
        case always
        case onChange = "on_change"
    }

    enum Status: String, Codable {
        case active
        case paused
        case dormant
        case archived
    }

    enum Trust: String, Codable {
        case l0, l1, l2, l3
    }

    let id: UUID
    let userID: UUID
    var title: String
    var prompt: String
    let triggerKindRaw: String
    let speaksRaw: String
    let trustRaw: String
    var statusRaw: String
    let originPattern: UUID?
    /// The one proposal type this agent may draft (L2) — the exact shape of
    /// the habit that earned it. Nil for observers and hand-made agents.
    let draftType: String?
    let specVersion: Int
    let createdAt: Date?

    enum CodingKeys: String, CodingKey {
        case id
        case userID = "user_id"
        case title
        case prompt
        case triggerKindRaw = "trigger_kind"
        case speaksRaw = "speaks"
        case trustRaw = "trust"
        case statusRaw = "status"
        case originPattern = "origin_pattern"
        case draftType = "draft_type"
        case specVersion = "spec_version"
        case createdAt = "created_at"
    }

    var triggerKind: TriggerKind? {
        TriggerKind(rawValue: triggerKindRaw)
    }

    var speaks: Speaks {
        Speaks(rawValue: speaksRaw) ?? .onChange
    }

    var status: Status {
        Status(rawValue: statusRaw) ?? .paused
    }

    /// Unknown reads as the lowest rung: a trust level this build doesn't
    /// recognise must never behave as more authority, only as less.
    var trust: Trust {
        Trust(rawValue: trustRaw) ?? .l0
    }

    /// "Linear", never the wire's "linear" — the same name every other surface
    /// shows for the product.
    var draftProviderName: String? {
        draftType.map { key in
            let prefix = String(key.prefix(while: { $0 != "." }))
            return IntegrationProvider(rawValue: prefix)?.displayName ?? prefix
        }
    }

    var draftActionPhrase: String? {
        draftType.flatMap { key in
            key.firstIndex(of: ".").map {
                key[key.index(after: $0)...].replacingOccurrences(of: "_", with: " ")
            }
        }
    }

    /// Whether this build may execute the agent at all: active, a trigger it
    /// recognises, and a spec version it fully understands.
    var isRunnable: Bool {
        status == .active && triggerKind != nil && specVersion == Self.supportedSpecVersion
    }
}

/// A habit the miner counted, waiting for the person's answer.
/// Wire-compatible with `public.pattern_candidates`.
struct PatternCandidate: Codable, Identifiable, Equatable {
    let id: UUID
    let userID: UUID
    /// The habit's shape — for proposal habits, the `provider.action` type.
    let contextKey: String
    let support: Int
    let rejected: Int
    var status: String

    enum CodingKeys: String, CodingKey {
        case id
        case userID = "user_id"
        case contextKey = "context_key"
        case support
        case rejected
        case status
    }

    var isOfferable: Bool {
        status == "candidate" || status == "offered"
    }

    /// "linear.create_issue" → "Linear" — the display name every other
    /// surface uses, falling back to the wire prefix for a product this build
    /// doesn't know.
    var providerName: String {
        let prefix = String(contextKey.prefix(while: { $0 != "." }))
        return IntegrationProvider(rawValue: prefix)?.displayName ?? prefix
    }

    var actionPhrase: String {
        guard let dot = contextKey.firstIndex(of: ".") else { return contextKey }
        return contextKey[contextKey.index(after: dot)...].replacingOccurrences(of: "_", with: " ")
    }

    /// The card's evidence line: "6 approved · 0 rejected".
    var evidenceLabel: String {
        "\(support) approved · \(rejected) rejected"
    }
}

/// Owns the user's agents and pattern candidates, and runs the after-meeting
/// trigger. The runs go through a dedicated unattended chat store — the same
/// arrangement beats use, and for the same reason: an agent answering as a
/// meeting ends must not clear a conversation somebody is typing into, and
/// `unattended` is what keeps every mutating tool off its table.
@MainActor
final class AgentStore: ObservableObject {
    @Published private(set) var agents: [Agent] = []
    @Published private(set) var candidates: [PatternCandidate] = []
    /// An agent that has earned the offer of standing authority: its drafts
    /// keep being approved untouched and nothing was rejected. Shown in the
    /// recap beside the pattern card, dismissable per Mac.
    @Published private(set) var grantOffer: (agent: Agent, approvals: Int)?

    /// The standing-grant terms, stated once: passed to the server when
    /// granting and interpolated into the card that offers it, so the copy
    /// cannot drift from what is actually minted.
    static let grantDays = 90
    static let grantPerWeek = 5
    /// Untouched approvals before the offer appears.
    static let grantOfferApprovals = 3

    private var snoozedGrantOffers: Set<UUID> {
        get {
            Set((UserDefaults.standard.stringArray(forKey: "agents.grantOffer.snoozed") ?? [])
                .compactMap(UUID.init(uuidString:)))
        }
        set {
            UserDefaults.standard.set(newValue.map(\.uuidString).sorted(), forKey: "agents.grantOffer.snoozed")
        }
    }

    private let supabase: SupabaseClient
    private let chat: KnowledgeChatStore
    private let threads: KnowledgeThreadStore
    private let llm: LLMProxyClient
    private let proposals: ActionProposalStore

    init(
        supabase: SupabaseClient,
        chat: KnowledgeChatStore,
        threads: KnowledgeThreadStore,
        llm: LLMProxyClient,
        proposals: ActionProposalStore
    ) {
        self.supabase = supabase
        self.chat = chat
        self.threads = threads
        self.llm = llm
        self.proposals = proposals
    }

    /// The one candidate a recap may show. One, not a list: two suggestions on
    /// one card teach the user to dismiss the card.
    var offerableCandidate: PatternCandidate? {
        candidates.first(where: \.isOfferable)
    }

    func refresh() async {
        do {
            agents = try await supabase
                .from("agents")
                .select()
                .neq("status", value: "archived")
                .order("created_at", ascending: false)
                .execute()
                .value
        } catch {
            Log.ui.error("agents refresh failed: \(error.localizedDescription)")
        }
    }

    /// "Grant": mints the standing authority server-side — one provider, one
    /// action, five a week, ninety days — and the agent starts filing.
    func grantStanding(_ agent: Agent) async {
        struct Params: Encodable {
            let p_agent: String
            let p_days: Int
            let p_per_week: Int
        }
        do {
            try await supabase
                .rpc(
                    "grant_agent_authority",
                    params: Params(p_agent: agent.id.uuidString, p_days: Self.grantDays, p_per_week: Self.grantPerWeek)
                )
                .execute()
            grantOffer = nil
            await refresh()
            Log.ui.info("standing grant issued to \(agent.title)")
        } catch {
            Log.ui.error("grant failed: \(error.localizedDescription)")
        }
    }

    /// "Keep asking": the offer stops appearing on this Mac. The agent keeps
    /// drafting exactly as before — declining autonomy costs nothing.
    func declineStanding(_ agent: Agent) {
        snoozedGrantOffers.insert(agent.id)
        grantOffer = nil
    }

    /// Outcomes feeding back: an agent whose last three decided drafts were
    /// all rejected drops a level — l3 loses its grant, l2 stops drafting.
    /// And an l2 agent whose drafts keep landing untouched earns the offer of
    /// standing authority. Both are arithmetic over rows the user already
    /// decided; no model opinion is consulted.
    private func enforceOutcomes() async {
        struct Decided: Decodable {
            let raisedByAgent: UUID
            let status: String

            enum CodingKeys: String, CodingKey {
                case raisedByAgent = "raised_by_agent"
                case status
            }
        }
        let drafting = agents.filter { $0.status == .active && $0.draftType != nil }
        guard !drafting.isEmpty else {
            grantOffer = nil
            return
        }
        do {
            // One query for every agent's recent decisions, grouped locally —
            // never a round trip per agent.
            let decided: [Decided] = try await supabase
                .from("action_proposals")
                .select("raised_by_agent, status")
                .in("raised_by_agent", values: drafting.map(\.id.uuidString))
                .in("status", values: ["approved", "completed", "rejected"])
                .order("decided_at", ascending: false)
                .limit(5 * drafting.count)
                .execute()
                .value
            let byAgent = Dictionary(grouping: decided, by: \.raisedByAgent)
            var offer: (agent: Agent, approvals: Int)?
            var demoted = false
            for agent in drafting {
                let recent = (byAgent[agent.id] ?? []).prefix(5)
                let lastThree = recent.prefix(3)
                if lastThree.count == 3, lastThree.allSatisfy({ $0.status == "rejected" }) {
                    if agent.trust == .l3 {
                        struct Params: Encodable {
                            let p_agent: String
                        }
                        try await supabase
                            .rpc("revoke_agent_grant", params: Params(p_agent: agent.id.uuidString))
                            .execute()
                        demoted = true
                    } else if agent.trust == .l2 {
                        await setTrust("l1", for: agent.id)
                    }
                    Log.ui.info("agent \(agent.title) demoted — last three drafts rejected")
                    continue
                }
                let approvals = recent.filter { $0.status != "rejected" }.count
                let rejections = recent.count - approvals
                if agent.trust == .l2, approvals >= Self.grantOfferApprovals, rejections == 0,
                   !snoozedGrantOffers.contains(agent.id), offer == nil {
                    offer = (agent, approvals)
                }
            }
            grantOffer = offer
            // `setTrust` refreshes itself; the grant revocation is the one
            // server-side change here that doesn't.
            if demoted {
                await refresh()
            }
        } catch {
            Log.ui.debug("agent outcomes skipped: \(error.localizedDescription)")
        }
    }

    /// Re-mines this user's habits and reloads what is worth offering. Called
    /// after a meeting lands — the only moment support can have grown.
    func refreshCandidates() async {
        do {
            let _: [PatternCandidate] = try await supabase.rpc("mine_my_patterns").execute().value
            candidates = try await supabase
                .from("pattern_candidates")
                .select()
                .in("status", values: ["candidate", "offered"])
                .order("support", ascending: false)
                .execute()
                .value
        } catch {
            Log.ui.debug("pattern mining skipped: \(error.localizedDescription)")
        }
    }

    /// "Try it": the candidate becomes an L1 observing agent — trigger, read,
    /// write a thread, nothing else. The prompt is written here, in words the
    /// user can read and later edit; accepting a card never creates anything
    /// the person couldn't have typed themselves.
    private struct CandidateAnswer: Encodable {
        let p_candidate: String
        let p_accept: Bool
    }

    /// "Try it": one server transaction from habit to agent — the candidate is
    /// marked accepted and the agent created together, so a failure between
    /// the two cannot strand an accepted habit with no agent behind it. The
    /// trust level and draft type are the server's call, made beside the
    /// constraint that enforces them; the prompt is written here, in words the
    /// user can read and later edit.
    func accept(_ candidate: PatternCandidate) async {
        struct Params: Encodable {
            let p_candidate: String
            let p_title: String
            let p_prompt: String
        }
        let title = "After-session brief · \(candidate.providerName)"
        let prompt = "Review the session that just ended. List what was decided, "
            + "the \(candidate.actionPhrase) work it produced, and anything left without an owner, "
            + "so I can file the rest quickly."
        do {
            try await supabase
                .rpc(
                    "accept_pattern_into_agent",
                    params: Params(p_candidate: candidate.id.uuidString, p_title: title, p_prompt: prompt)
                )
                .execute()
            Log.ui.info("agent created from pattern \(candidate.contextKey)")
            await refresh()
            candidates.removeAll { $0.id == candidate.id }
        } catch {
            Log.ui.error("agent creation failed: \(error.localizedDescription)")
        }
    }

    func dismiss(_ candidate: PatternCandidate) async {
        do {
            try await supabase
                .rpc("answer_pattern_candidate", params: CandidateAnswer(p_candidate: candidate.id.uuidString, p_accept: false))
                .execute()
            candidates.removeAll { $0.id == candidate.id }
        } catch {
            Log.ui.error("pattern dismissal failed: \(error.localizedDescription)")
        }
    }

    // MARK: - The after-meeting trigger

    /// Runs every runnable after-meeting agent for the session that just
    /// finished. Serial on purpose, exactly as beats are: each run is a whole
    /// grounded turn, and two at once on a machine somebody is working on is a
    /// fan, not a feature.
    ///
    /// `producedWork` is the on-change gate: a session that yielded no action
    /// items changed nothing worth speaking about, and the run is recorded as
    /// skipped rather than spent.
    func runAfterMeeting(meeting: Meeting, producedWork: Bool, itemTitles: [String] = []) async {
        await refresh()
        let due = agents.filter { $0.isRunnable && $0.triggerKind == .afterMeeting }
        guard !due.isEmpty else { return }
        defer { Task { await enforceOutcomes() } }
        for agent in due {
            if agent.speaks == .onChange, !producedWork {
                _ = await record(agent: agent, meeting: meeting.id, status: "gate_skipped")
                continue
            }
            // The unique (agent, meeting) index makes this the idempotence
            // gate: a re-enrichment that reaches here again gets a conflict,
            // not a second run.
            guard await record(agent: agent, meeting: meeting.id, status: "started") else {
                continue
            }
            chat.startNewThread()
            let dated = meeting.displayTitle(dateFormatter: Meeting.shortDateFormatter)
            await chat.ask("For the session that just ended (\(dated)):\n\(agent.prompt)")
            if let threadID = chat.threadID {
                await threads.rename(threadID: threadID, title: agent.title)
                await finish(agent: agent, meeting: meeting.id, status: "done", threadID: threadID, error: nil)
                Log.ui.info("agent ran \(agent.title)")
                await draftFollowUps(for: agent, meeting: meeting, itemTitles: itemTitles)
            } else {
                await finish(
                    agent: agent,
                    meeting: meeting.id,
                    status: "failed",
                    threadID: nil,
                    error: chat.failure?.message ?? "The answer could not be saved."
                )
            }
        }
    }

    /// L2's whole act: follow-ups the brief surfaced, printed into the same
    /// review queue every proposal has always landed in. A `proposed` row
    /// changes nothing anywhere — it becomes an action only through the same
    /// approve and the same server-side re-check as a pipeline draft. The
    /// agent may draft exactly one type: the shape of the habit that earned
    /// it, checked here and constrained by the schema.
    private func draftFollowUps(for agent: Agent, meeting: Meeting, itemTitles: [String]) async {
        guard agent.trust == .l2 || agent.trust == .l3, let type = agent.draftType else { return }
        guard let brief = chat.messages.last(where: { $0.role == .assistant })?.content,
              !brief.isEmpty else { return }
        let (system, user) = PromptLibrary.buildAgentDrafts(
            brief: brief,
            meetingTitle: meeting.displayTitle(dateFormatter: Meeting.shortDateFormatter),
            existingTitles: itemTitles
        )
        do {
            let result = try await llm.completeJSON(system: system, user: user, as: PromptLibrary.AgentDraftsResult.self)
            let drafts = result.drafts.prefix(3).compactMap { draft -> ProposalDraft? in
                let title = draft.title.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !title.isEmpty else { return nil }
                var parameters = ["title": String(title.prefix(ProposalDrafting.titleLimit))]
                if let details = draft.details?.trimmingCharacters(in: .whitespacesAndNewlines), !details.isEmpty {
                    parameters["description"] = details
                }
                // Live-pass trust, deliberately: the draft came out of one
                // model reading of a brief, so it lands as `proposed` and is
                // never auto-ready.
                return ProposalDraft(
                    type: type,
                    parameters: parameters,
                    confidence: ProposalConfidence(semantic: ProposalDrafting.semanticConfidence(for: .live)),
                    actionItemID: nil,
                    evidenceIdx: nil
                )
            }
            guard !drafts.isEmpty else { return }
            await proposals.raise(Array(drafts), meetingID: meeting.id, userID: agent.userID, agentID: agent.id)
            Log.ui.info("agent \(agent.title) drafted \(drafts.count) follow-up(s)")
            if agent.trust == .l3 {
                await fileUnderGrant(agent: agent, meetingID: meeting.id)
            }
        } catch {
            Log.ui.error("agent drafting failed (non-fatal): \(error.localizedDescription)")
        }
    }

    /// The standing half of L3: for each draft this agent just raised, ask the
    /// server to approve it under the grant, then run the same execute path an
    /// approved card takes. The server is the gate — an expired or spent grant
    /// refuses, the agent drops back to asking, and the drafts stay on the
    /// review card exactly as an L2 agent's would.
    private func fileUnderGrant(agent: Agent, meetingID: UUID) async {
        let drafts = proposals.proposals(forMeeting: meetingID)
            .filter { $0.raisedByAgent == agent.id && $0.status == .proposed }
        for draft in drafts {
            switch await proposals.autoApprove(draft) {
            case .approved:
                _ = await proposals.execute(draft)
            case .authorityLapsed:
                // Recertification happening: authority lapsed, so the agent
                // goes back to asking. The grant offer reappears on merit, and
                // renewing it is the same explicit act the first grant was.
                await setTrust("l2", for: agent.id)
                Log.ui.info("agent \(agent.title) grant lapsed — back to asking")
                return
            case .refused:
                continue
            }
        }
    }

    private func setTrust(_ trust: String, for agentID: UUID) async {
        do {
            try await supabase
                .from("agents")
                .update(["trust": trust])
                .eq("id", value: agentID.uuidString)
                .execute()
            await refresh()
        } catch {
            Log.ui.error("agent trust change failed: \(error.localizedDescription)")
        }
    }

    /// Inserts the run row. False when the row already exists — this agent
    /// already answered this meeting — or when the insert failed outright;
    /// either way the caller must not run.
    private func record(agent: Agent, meeting: UUID, status: String) async -> Bool {
        struct Row: Encodable {
            let agent_id: String
            let user_id: String
            let meeting_id: String
            let status: String
        }
        do {
            try await supabase
                .from("agent_runs")
                .insert(Row(
                    agent_id: agent.id.uuidString,
                    user_id: agent.userID.uuidString,
                    meeting_id: meeting.uuidString,
                    status: status
                ))
                .execute()
            return true
        } catch {
            Log.ui.debug("agent run not recorded (already ran, or offline): \(error.localizedDescription)")
            return false
        }
    }

    private static let finishedAtFormatter = ISO8601DateFormatter()

    private func finish(agent: Agent, meeting: UUID, status: String, threadID: UUID?, error: String?) async {
        struct Patch: Encodable {
            let status: String
            let thread_id: String?
            let error: String?
            let finished_at: String
        }
        do {
            try await supabase
                .from("agent_runs")
                .update(Patch(
                    status: status,
                    thread_id: threadID?.uuidString,
                    error: error,
                    finished_at: Self.finishedAtFormatter.string(from: Date())
                ))
                .eq("agent_id", value: agent.id.uuidString)
                .eq("meeting_id", value: meeting.uuidString)
                .execute()
        } catch {
            Log.ui.debug("agent run finish not recorded: \(error.localizedDescription)")
        }
    }
}
