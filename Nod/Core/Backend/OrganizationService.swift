import Foundation
import Supabase

/// Which organizations the signed-in person belongs to, and which one they are
/// currently working in.
///
/// The active context decides what a new recording is stamped with, not what the
/// person can see: their own sessions stay theirs in every context, so switching
/// never hides their work. The server enforces both halves — a context the
/// person is not a member of is rejected at the row, and an organization that
/// has turned off personal recording overrides a personal choice — so nothing
/// here is a permission check. It is a preference the database is free to
/// disagree with.
@MainActor
final class OrganizationService: ObservableObject {
    @Published private(set) var memberships: [OrgMembership] = []
    @Published var teams: [Team] = []
    /// Rosters keyed by team, loaded on demand — a pane showing five teams should
    /// not fetch five rosters nobody expanded.
    @Published var teamMembers: [UUID: [TeamMember]] = [:]
    /// `nil` is the personal context, which is where every account starts and
    /// where an account that never joins anything stays.
    @Published private(set) var activeOrgID: UUID?
    /// Who the signed-in person is, so the member list can tell their own row
    /// apart — you administer an organization, you do not administer yourself.
    @Published private(set) var currentUserID: UUID?
    @Published private(set) var members: [OrgMember] = []
    /// Colleagues this account may address by name — see `org_directory`.
    ///
    /// Separate from `members`, which is the administrator's view and raises for
    /// everyone else. This one carries only what an invitation needs.
    @Published private(set) var directory: [Teammate] = []
    private var hasLoadedDirectory = false
    /// Everybody the organization knows about, including colleagues who have
    /// never installed Nod — imported from whichever tracker or chat the company
    /// connected. This is what an assignment picks from; `directory` is the
    /// narrower "who can I invite to a meeting" list.
    @Published private(set) var people: [Person] = []
    @Published private(set) var pendingInvites: [OrgInvite] = []
    @Published private(set) var isLoading = false
    @Published var lastError: String?

    // `internal` rather than `private` for the three members below: the team
    // surface lives in `OrganizationService+Teams.swift`, and a cross-file
    // extension of our own type cannot reach `private`. Module-wide is the
    // default access level in a single-module app; nothing outside this type
    // has a reason to touch them.
    let supabase: SupabaseClient?
    private var hasLoaded = false
    /// `refresh` redeems a held invite, and redeeming refreshes. The cycle ends
    /// on its own because the token is consumed first, but a guard that depends
    /// on the order of two side effects is a guard waiting to be reordered.
    private var isRedeeming = false

    init(supabase: SupabaseClient?) {
        self.supabase = supabase
    }

    var activeMembership: OrgMembership? {
        guard let activeOrgID else { return nil }
        return memberships.first { $0.id == activeOrgID }
    }

    /// True once the person belongs to anything. Settings uses it to decide
    /// whether the organization pane is worth showing at all — an account with
    /// no memberships has nothing to put in it.
    var belongsToAnyOrganization: Bool {
        !memberships.isEmpty
    }

    func teams(in orgID: UUID) -> [Team] {
        teams.filter { $0.orgID == orgID }
    }

    /// Loaded once per run: an organization's roster changes when somebody joins
    /// or leaves, not between two questions in a chat.
    func refreshDirectoryIfNeeded() async {
        guard let supabase, !hasLoadedDirectory else { return }
        do {
            directory = try await supabase.rpc("org_directory").execute().value
            hasLoadedDirectory = true
        } catch {
            Log.ui.error("org directory failed: \(error.localizedDescription)")
        }
    }

    /// The assignable roster. Reloaded rather than cached with `directory`
    /// because importing a workspace changes it without anybody joining
    /// anything — the whole point of picking a company up from its own tools.
    func refreshPeople() async {
        guard let supabase else { return }
        do {
            people = try await supabase.rpc("org_people").execute().value
            Log.ui.info("org people count=\(people.count)")
        } catch {
            // An older server has no `org_people`. Everything that reads this
            // degrades to an empty list, which is what a personal account sees.
            Log.ui.error("org people failed: \(error.localizedDescription)")
        }
    }

    func refreshIfNeeded() async {
        guard !hasLoaded else { return }
        await refresh()
    }

    func refresh() async {
        guard let supabase, let userID = supabase.auth.currentUser?.id else { return }
        currentUserID = userID
        isLoading = true
        defer { isLoading = false }
        do {
            // Scoped to the caller explicitly. `org_members` is readable by every
            // member of the organization by design — that is what makes a roster
            // a roster — so leaving the filter to row-level security returns one
            // row per colleague, each embedding the same organization.
            let rows: [OrgMembershipRow] = try await supabase
                .from("org_members")
                .select("role, organizations(id, name, slug)")
                .eq("user_id", value: userID.uuidString)
                .eq("status", value: "active")
                .execute()
                .value
            memberships = rows.compactMap(\.membership).sorted { $0.organization.name < $1.organization.name }

            teams = memberships.isEmpty ? [] : try await supabase
                .from("teams")
                .select("id, org_id, name")
                .execute()
                .value

            activeOrgID = try await loadActiveOrgID()
            // With the organization, not on first chat. Everything that names a
            // colleague — the speaker correction, an assignment, the review
            // card — reads this, and none of those wait for somebody to open a
            // conversation first.
            await refreshPeople()
            hasLoaded = true
            lastError = nil
            // A token held from a signed-out click redeems on the first refresh
            // after signing in, which is the moment it became possible.
            await redeemPendingInvite()
            Log.ui.info("organizations memberships=\(memberships.count) teams=\(teams.count)")
        } catch {
            lastError = "Couldn't load your organizations."
            Log.ui.error("OrganizationService.refresh failed: \(error.localizedDescription)")
        }
    }

    func createOrganization(named name: String) async -> Bool {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let supabase, !trimmed.isEmpty else { return false }

        isLoading = true
        defer { isLoading = false }
        do {
            struct Params: Encodable {
                let p_name: String
                let p_slug: String
            }
            // One retry on a taken slug rather than a loop: two people naming an
            // organization the same thing at the same moment is the case worth
            // surviving, and a third collision is a name worth rejecting.
            do {
                _ = try await supabase
                    .rpc("create_organization", params: Params(p_name: trimmed, p_slug: Organization.slug(from: trimmed)))
                    .execute()
            } catch {
                let suffix = String(UUID().uuidString.prefix(4)).lowercased()
                _ = try await supabase
                    .rpc("create_organization", params: Params(p_name: trimmed, p_slug: Organization.slug(from: trimmed, suffix: suffix)))
                    .execute()
            }
            hasLoaded = false
            await refresh()
            lastError = nil
            Log.ui.info("organization created")
            return true
        } catch {
            lastError = "Couldn't create the organization."
            Log.ui.error("OrganizationService.create failed: \(error.localizedDescription)")
            return false
        }
    }

    /// Switches the context new recordings are filed under. `nil` means personal.
    func switchContext(to orgID: UUID?) async {
        guard let supabase, orgID == nil || memberships.contains(where: { $0.id == orgID }) else { return }
        let previous = activeOrgID
        activeOrgID = orgID
        do {
            struct Payload: Encodable {
                let active_org_id: UUID?
            }
            guard let userID = supabase.auth.currentUser?.id else { return }
            try await supabase
                .from("profiles")
                .update(Payload(active_org_id: orgID))
                .eq("user_id", value: userID.uuidString)
                .execute()
            lastError = nil
            Log.ui.info("organization context switched org=\(orgID?.uuidString ?? "personal")")
        } catch {
            activeOrgID = previous
            lastError = "Couldn't switch context."
            Log.ui.error("OrganizationService.switchContext failed: \(error.localizedDescription)")
        }
    }

    /// A token from a `nod://invite` link that arrived before there was anyone to
    /// accept it. Redeeming needs an identity, and the invite is bound to the
    /// address it was sent to, so a signed-out app can only hold it.
    private static let pendingInviteKey = "organization.pendingInvite"

    static func storePendingInvite(_ token: UUID) {
        UserDefaults.standard.set(token.uuidString, forKey: pendingInviteKey)
    }

    /// Kept when there is nobody to redeem it as, cleared once there was.
    ///
    /// Clicking an invite before signing in is the ordinary case, not an error —
    /// the link is what brought the person to the app. Dropping the token on
    /// that first failed attempt stranded an invite that was perfectly valid,
    /// with no way back to it from inside the app.
    func redeemPendingInvite() async {
        guard let raw = UserDefaults.standard.string(forKey: Self.pendingInviteKey),
              let token = UUID(uuidString: raw)
        else { return }
        guard supabase?.auth.currentUser != nil, !isRedeeming else { return }

        isRedeeming = true
        defer { isRedeeming = false }
        UserDefaults.standard.removeObject(forKey: Self.pendingInviteKey)
        await acceptInvite(token: token)
    }

    @discardableResult
    func acceptInvite(token: UUID) async -> Bool {
        guard let supabase else { return false }
        isLoading = true
        defer { isLoading = false }
        do {
            struct Params: Encodable {
                let p_token: UUID
            }
            let orgID: UUID = try await supabase
                .rpc("accept_org_invite", params: Params(p_token: token))
                .execute()
                .value
            hasLoaded = false
            await refresh()
            await switchContext(to: orgID)
            lastError = nil
            Log.ui.info("organization invite accepted")
            return true
        } catch {
            lastError = "That invite couldn't be used. It may have expired, or been sent to a different address."
            Log.ui.error("OrganizationService.acceptInvite failed: \(error.localizedDescription)")
            return false
        }
    }

    /// Creates the invite and asks the server to email it. The link comes back
    /// either way — a send that didn't happen is a reason to hand the link over
    /// yourself, not to lose the invite.
    @discardableResult
    func invite(email: String, role: OrgRole = .member, to orgID: UUID) async -> Bool {
        guard let supabase else { return false }
        let trimmed = email.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard trimmed.contains("@") else {
            lastError = "That doesn't look like an email address."
            return false
        }
        isLoading = true
        defer { isLoading = false }
        do {
            struct Body: Encodable {
                let orgId: String
                let email: String
                let role: String
            }
            struct Result: Decodable {
                let inviteUrl: String
                let emailed: Bool
            }
            let result: Result = try await supabase.functions.invoke(
                "org-invite",
                options: FunctionInvokeOptions(body: Body(orgId: orgID.uuidString, email: trimmed, role: role.rawValue))
            )
            lastError = result.emailed ? nil : "Invite created, but the email couldn't be sent — copy the link instead."
            await loadMembers(in: orgID)
            Log.ui.info("organization invite created emailed=\(result.emailed)")
            return true
        } catch {
            // The RPC writes its refusals for the person doing the inviting —
            // "that person is already a member", "only an owner can invite an
            // owner" — and `org-invite` passes them through untouched. Replacing
            // them with something generic here would throw away the only part of
            // the message that tells them what to do next.
            lastError = Self.serverMessage(error) ?? "Couldn't create that invite."
            Log.ui.error("OrganizationService.invite failed: \(error.localizedDescription)")
            return false
        }
    }

    /// The database writes its refusals for the person reading them — "an
    /// organization must keep at least one owner" — so they are shown rather than
    /// flattened into a generic failure.
    static func rpcMessage(_ error: Error) -> String? {
        guard let postgrest = error as? PostgrestError else { return nil }
        let message = postgrest.message
        guard !message.isEmpty else { return nil }
        return message.prefix(1).uppercased() + message.dropFirst() + "."
    }

    private static func serverMessage(_ error: Error) -> String? {
        guard let functionError = error as? FunctionsError,
              case let .httpError(_, data) = functionError else { return nil }
        struct Body: Decodable {
            let error: String?
        }
        let message = try? JSONDecoder().decode(Body.self, from: data).error
        guard let message, !message.isEmpty else { return nil }
        return message.prefix(1).uppercased() + message.dropFirst() + "."
    }

    func loadMembers(in orgID: UUID) async {
        guard let supabase else { return }
        do {
            struct Params: Encodable {
                let p_org: UUID
            }
            members = try await supabase
                .rpc("list_org_members", params: Params(p_org: orgID))
                .execute()
                .value
            pendingInvites = try await supabase
                .from("org_invites")
                .select("id, email, role, token, expires_at")
                .eq("org_id", value: orgID.uuidString)
                .is("accepted_at", value: nil)
                .is("revoked_at", value: nil)
                .execute()
                .value
        } catch {
            Log.ui.error("OrganizationService.loadMembers failed: \(error.localizedDescription)")
        }
    }

    /// Roles this caller may hand out. Only an owner creates another owner —
    /// an administrator who could would be an owner with extra steps, and the
    /// server refuses it, so the picker should not offer it either.
    func grantableRoles(as role: OrgRole) -> [OrgRole] {
        role == .owner ? OrgRole.allCases : [.member, .admin]
    }

    func setRole(_ role: OrgRole, for member: OrgMember, in orgID: UUID) async {
        guard let supabase else { return }
        do {
            struct Params: Encodable {
                let p_org: UUID
                let p_user: UUID
                let p_role: String
            }
            _ = try await supabase
                .rpc("set_org_member_role", params: Params(p_org: orgID, p_user: member.userID, p_role: role.rawValue))
                .execute()
            lastError = nil
            await loadMembers(in: orgID)
            Log.ui.info("organization role changed")
        } catch {
            lastError = Self.rpcMessage(error) ?? "Couldn't change that role."
            Log.ui.error("OrganizationService.setRole failed: \(error.localizedDescription)")
        }
    }

    func removeMember(_ member: OrgMember, in orgID: UUID) async {
        guard let supabase else { return }
        do {
            struct Params: Encodable {
                let p_org: UUID
                let p_user: UUID
            }
            _ = try await supabase
                .rpc("remove_org_member", params: Params(p_org: orgID, p_user: member.userID))
                .execute()
            lastError = nil
            hasLoaded = false
            await refresh()
            await loadMembers(in: orgID)
            Log.ui.info("organization member removed")
        } catch {
            lastError = Self.rpcMessage(error) ?? "Couldn't remove that person."
            Log.ui.error("OrganizationService.removeMember failed: \(error.localizedDescription)")
        }
    }

    /// Ends the organization for everyone in it. The only way out for a sole
    /// owner, who cannot be removed from their own organization and should not
    /// be offered a button that says otherwise.
    func deleteOrganization(_ orgID: UUID) async {
        guard let supabase else { return }
        isLoading = true
        defer { isLoading = false }
        do {
            struct Params: Encodable {
                let p_org: UUID
            }
            _ = try await supabase.rpc("delete_organization", params: Params(p_org: orgID)).execute()
            members = []
            pendingInvites = []
            hasLoaded = false
            await refresh()
            lastError = nil
            Log.ui.info("organization deleted")
        } catch {
            lastError = Self.rpcMessage(error) ?? "Couldn't delete that organization."
            Log.ui.error("OrganizationService.deleteOrganization failed: \(error.localizedDescription)")
        }
    }

    /// Leaving is the member's own act. Joining takes a second and used to be
    /// undoable only by asking an administrator — an obligation that runs both
    /// ways should be endable by the person carrying it.
    func leaveOrganization(_ orgID: UUID) async {
        guard let supabase else { return }
        isLoading = true
        defer { isLoading = false }
        do {
            struct Params: Encodable {
                let p_org: UUID
            }
            _ = try await supabase.rpc("leave_organization", params: Params(p_org: orgID)).execute()
            members = []
            pendingInvites = []
            teamMembers = [:]
            hasLoaded = false
            await refresh()
            lastError = nil
            Log.ui.info("left organization")
        } catch {
            lastError = Self.rpcMessage(error) ?? "Couldn't leave that organization."
            Log.ui.error("OrganizationService.leaveOrganization failed: \(error.localizedDescription)")
        }
    }

    /// True when leaving would strand the organization. The server refuses it
    /// anyway, with a message that says what to do instead — this only keeps the
    /// interface from offering the one exit that cannot work.
    func isSoleOwner(of orgID: UUID) -> Bool {
        guard memberships.first(where: { $0.id == orgID })?.role == .owner else { return false }
        return members.filter { $0.isActive && $0.role == .owner }.count <= 1
    }

    func revokeInvite(_ invite: OrgInvite, in orgID: UUID) async {
        guard let supabase else { return }
        do {
            struct Params: Encodable {
                let p_invite: UUID
            }
            _ = try await supabase.rpc("revoke_org_invite", params: Params(p_invite: invite.id)).execute()
            await loadMembers(in: orgID)
        } catch {
            lastError = "Couldn't revoke that invite."
            Log.ui.error("OrganizationService.revokeInvite failed: \(error.localizedDescription)")
        }
    }

    func clear() {
        people = []
        memberships = []
        teams = []
        members = []
        pendingInvites = []
        teamMembers = [:]
        currentUserID = nil
        activeOrgID = nil
        hasLoaded = false
        lastError = nil
    }

    private func loadActiveOrgID() async throws -> UUID? {
        struct Row: Decodable {
            let active_org_id: UUID?
        }
        guard let supabase, let userID = supabase.auth.currentUser?.id else { return nil }
        let rows: [Row] = try await supabase
            .from("profiles")
            .select("active_org_id")
            .eq("user_id", value: userID.uuidString)
            .limit(1)
            .execute()
            .value
        let stored = rows.first?.active_org_id
        // A context the person no longer belongs to is not an error worth
        // showing — being removed from an organization is a normal event, and
        // the honest answer is that they are back in their own space.
        return memberships.contains(where: { $0.id == stored }) ? stored : nil
    }
}

#if DEBUG
    extension OrganizationService {
        /// Seeds the published state directly so previews can show a populated
        /// pane without a network client. Same-file access keeps `hasLoaded`
        /// private everywhere else.
        static func preview(memberships: [OrgMembership], activeOrgID: UUID? = nil, teams: [Team] = []) -> OrganizationService {
            let service = OrganizationService(supabase: nil)
            service.memberships = memberships
            service.teams = teams
            service.activeOrgID = activeOrgID
            service.hasLoaded = true
            return service
        }
    }
#endif
