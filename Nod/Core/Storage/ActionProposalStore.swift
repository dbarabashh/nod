import Foundation
import Supabase

/// The proposals waiting on the user, and the two answers they can be given.
///
/// Deliberately thin. Deciding what to propose lives in `ProposalDrafting`,
/// which is pure; carrying one out lives in `proposal-execute`, on the server.
/// What is left here is the round trip and the list a view renders.
@MainActor
final class ActionProposalStore: ObservableObject {
    @Published private(set) var proposals: [ActionProposal] = []
    @Published private(set) var isLoading = false
    @Published var lastError: String?

    /// Optional so a preview can hold a store with rows and no network, the
    /// same arrangement `OrganizationService` and `IntegrationService` use.
    private let supabase: SupabaseClient?
    private static let tableName = "action_proposals"

    init(supabase: SupabaseClient?) {
        self.supabase = supabase
    }

    /// Everything still awaiting a decision, newest first. Completed and
    /// rejected rows are left on the server — they are the audit trail, not a
    /// work list.
    var awaitingDecision: [ActionProposal] {
        proposals.filter(\.isAwaitingDecision)
    }

    func proposals(forMeeting meetingID: UUID) -> [ActionProposal] {
        proposals.filter { $0.meetingID == meetingID }
    }

    func refresh() async {
        guard let supabase else { return }
        isLoading = true
        defer { isLoading = false }
        do {
            proposals = try await supabase
                .from(Self.tableName)
                .select()
                .in("status", values: ActionProposal.Status.unsettled.map(\.rawValue))
                .order("created_at", ascending: false)
                .execute()
                .value
            lastError = nil
        } catch {
            lastError = "Couldn't load what's waiting for you."
            Log.ui.error("ActionProposalStore.refresh failed: \(error.localizedDescription)")
        }
    }

    /// Raises what a finished meeting is offering to do.
    ///
    /// Best-effort, and silent on conflict: the dedup index means a meeting
    /// finalized twice — a retry, a relaunch replay — proposes the same work
    /// once. That is the whole reason the constraint is in the database rather
    /// than in a check here.
    func raise(_ drafts: [ProposalDraft], meetingID: UUID, userID: UUID, agentID: UUID? = nil) async {
        guard let supabase, !drafts.isEmpty else { return }
        struct Row: Encodable {
            let userID: UUID
            let meetingID: UUID
            let actionItemID: UUID?
            let type: String
            let status: String
            let parameters: [String: String]
            let confidence: Double
            let confidenceParts: [String: Double]
            let evidenceIdx: Int?
            let raisedByAgent: UUID?

            enum CodingKeys: String, CodingKey {
                case userID = "user_id"
                case meetingID = "meeting_id"
                case actionItemID = "action_item_id"
                case type
                case status
                case parameters
                case confidence
                case confidenceParts = "confidence_parts"
                case evidenceIdx = "evidence_idx"
                case raisedByAgent = "raised_by_agent"
            }
        }

        let rows = drafts.map {
            Row(
                userID: userID,
                meetingID: meetingID,
                actionItemID: $0.actionItemID,
                type: $0.type,
                status: $0.status.rawValue,
                parameters: $0.parameters,
                confidence: $0.confidence.overall,
                confidenceParts: $0.confidence.stored,
                evidenceIdx: $0.evidenceIdx,
                raisedByAgent: agentID
            )
        }
        do {
            try await supabase
                .from(Self.tableName)
                .upsert(rows, onConflict: "meeting_id,type,md5(parameters::text)", ignoreDuplicates: true)
                .execute()
            Log.ui.info("proposals raised count=\(rows.count) meeting=\(meetingID.uuidString)")
            await refresh()
        } catch {
            // Nothing the user asked for has failed — the meeting, its recap and
            // its to-dos are all saved. Only the offer to act on them is missing.
            Log.ui.error("ActionProposalStore.raise failed: \(error.localizedDescription)")
        }
    }

    /// Says yes, with whatever the user changed.
    ///
    /// The edited parameters travel with the approval rather than as a separate
    /// save, because they are one act: a person read it, fixed it, and approved
    /// what they fixed. Two calls would let an approval refer to a version
    /// nobody approved.
    func approve(_ proposal: ActionProposal, parameters: [String: String]? = nil) async -> Bool {
        struct Params: Encodable {
            let p_proposal: UUID
            let p_parameters: [String: String]?
        }
        return await decide(proposal, becoming: .approved, parameters: parameters) { supabase in
            _ = try await supabase
                .rpc("approve_proposal", params: Params(p_proposal: proposal.id, p_parameters: parameters))
                .execute()
        }
    }

    func reject(_ proposal: ActionProposal) async -> Bool {
        struct Params: Encodable {
            let p_proposal: UUID
        }
        return await decide(proposal, becoming: .rejected) { supabase in
            _ = try await supabase
                .rpc("reject_proposal", params: Params(p_proposal: proposal.id))
                .execute()
        }
    }

    /// What the server said when asked to approve with nobody watching.
    enum AutoApproval {
        case approved
        /// The standing authority lapsed or was spent — the agent goes back to
        /// asking, which is the whole design of an expiry.
        case authorityLapsed
        case refused
    }

    /// Asks the server to approve an agent's draft under its standing grant.
    /// The server re-checks everything at the moment of use and answers with a
    /// verdict word — never an exception to parse prose out of.
    func autoApprove(_ proposal: ActionProposal) async -> AutoApproval {
        guard let supabase else { return .refused }
        struct Params: Encodable {
            let p_proposal: String
        }
        do {
            let verdict: String = try await supabase
                .rpc("agent_approve_proposal", params: Params(p_proposal: proposal.id.uuidString))
                .execute()
                .value
            switch verdict {
            case "approved":
                apply(.approved, to: proposal.id)
                return .approved
            case "grant_expired", "grant_budget_spent":
                Log.ui.info("auto-approve declined: \(verdict)")
                return .authorityLapsed
            default:
                Log.ui.info("auto-approve declined: \(verdict)")
                return .refused
            }
        } catch {
            Log.ui.error("auto-approve failed: \(error.localizedDescription)")
            return .refused
        }
    }

    /// Carries out something already approved.
    ///
    /// Split from `approve` because they are different acts with different
    /// failure modes: saying yes is a decision that has landed once the row
    /// says so, and running it can fail for reasons — a revoked connection, a
    /// Linear team that no longer exists — that have nothing to do with the
    /// decision. A proposal left `approved` by a crash between the two is
    /// exactly why `unsettled` still loads it.
    ///
    /// The server decides everything that matters here. This sends an id.
    @discardableResult
    func execute(_ proposal: ActionProposal) async -> Bool {
        guard let supabase else { return false }
        struct Request: Encodable { let proposal_id: UUID }
        struct Result: Decodable {
            struct Value: Decodable {
                let key: String?
                let title: String?
                let url: String?
            }

            struct Failure: Decodable {
                let code: String
                let message: String
            }

            let result: Value?
            let error: Failure?
        }

        apply(.executing, to: proposal.id)
        do {
            let response: Result = try await supabase.functions.invoke(
                "proposal-execute",
                options: FunctionInvokeOptions(body: Request(proposal_id: proposal.id))
            )
            if let failure = response.error {
                apply(.failed, to: proposal.id, failure: failure.message)
                lastError = failure.message
                Log.ui.error("proposal execution refused: \(failure.code)")
                return false
            }
            if let idx = proposals.firstIndex(where: { $0.id == proposal.id }) {
                proposals[idx].status = .completed
                proposals[idx].externalProvider = proposal.provider?.rawValue
                proposals[idx].externalKey = response.result?.key
                proposals[idx].externalURL = response.result?.url
            }
            lastError = nil
            Log.ui.info("proposal executed type=\(proposal.type)")
            return true
        } catch {
            // The row is left `failed` locally and re-read on the next refresh.
            // The server is the one that knows whether the provider was reached,
            // and a transport error here says nothing about that.
            apply(.failed, to: proposal.id, failure: "Couldn't reach Nod to run this.")
            lastError = "Couldn't run that action."
            Log.ui.error("ActionProposalStore.execute failed: \(error.localizedDescription)")
            return false
        }
    }

    private func apply(_ status: ActionProposal.Status, to id: UUID, failure: String? = nil) {
        guard let idx = proposals.firstIndex(where: { $0.id == id }) else { return }
        proposals[idx].status = status
        proposals[idx].failureMessage = failure
    }

    /// Settles something the proposal was missing, without deciding it.
    ///
    /// Naming an owner Nod could not resolve raises the proposal out of
    /// `needs_review` and leaves it exactly there — waiting for the same person
    /// to say yes or no, now that it is worth saying yes to.
    func assign(_ proposal: ActionProposal, parameters: [String: String]) async -> Bool {
        guard let supabase else { return false }
        struct Params: Encodable {
            let p_proposal: UUID
            let p_parameters: [String: String]
            let p_confidence: Double
            let p_status: String
        }
        // Re-measured, not nudged: the owner claim is now the user's own answer,
        // which is what `PersonResolver` scores a confirmed pick at.
        var confidence = ProposalConfidence(stored: proposal.confidenceParts ?? [:])
        confidence.record(.owner, PersonResolver.confirmedConfidence)

        do {
            _ = try await supabase
                .rpc("edit_proposal", params: Params(
                    p_proposal: proposal.id,
                    p_parameters: parameters,
                    p_confidence: confidence.overall,
                    p_status: confidence.status.rawValue
                ))
                .execute()
            if let idx = proposals.firstIndex(where: { $0.id == proposal.id }) {
                proposals[idx].parameters = parameters
                proposals[idx].confidence = confidence.overall
                proposals[idx].confidenceParts = confidence.stored
                proposals[idx].status = confidence.status
            }
            lastError = nil
            return true
        } catch {
            lastError = OrganizationService.rpcMessage(error) ?? "Couldn't save that."
            Log.ui.error("ActionProposalStore.assign failed: \(error.localizedDescription)")
            return false
        }
    }

    /// Runs one decision RPC and mirrors the result locally.
    ///
    /// The call itself is the caller's, because approving carries edited
    /// parameters and rejecting carries nothing — one function taking both and
    /// branching on the function's own name was a type the compiler could have
    /// checked, written as a string it could not.
    private func decide(
        _ proposal: ActionProposal,
        becoming status: ActionProposal.Status,
        parameters: [String: String]? = nil,
        call: (SupabaseClient) async throws -> Void
    ) async -> Bool {
        guard let supabase else { return false }
        do {
            try await call(supabase)
            if let idx = proposals.firstIndex(where: { $0.id == proposal.id }) {
                proposals[idx].status = status
                if let parameters { proposals[idx].parameters = parameters }
            }
            lastError = nil
            Log.ui.info("proposal \(status.rawValue) type=\(proposal.type)")
            return true
        } catch {
            lastError = OrganizationService.rpcMessage(error) ?? "Couldn't save that decision."
            Log.ui.error("ActionProposalStore decision failed: \(error.localizedDescription)")
            return false
        }
    }

    func clear() {
        proposals = []
        lastError = nil
    }
}

extension ActionProposal.Status {
    /// The states a person still has to answer for.
    static let awaiting: [ActionProposal.Status] = [.proposed, .needsReview, .ready]

    /// Everything that is still somebody's problem — including `approved`, which
    /// is where a proposal is stranded if the app quit between saying yes and
    /// the action running, and `failed`, which is worth showing so it can be
    /// tried again.
    static let unsettled: [ActionProposal.Status] = awaiting + [.approved, .executing, .failed]
}
