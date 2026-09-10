import AppKit
import CryptoKit
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
    /// The teams this person is actually in, which is narrower than `teams` —
    /// that one carries every team in the organization so the sharing menu can
    /// offer them. Only membership is a subscription right: the
    /// `realtime.messages` policy checks `team_members`, so listening on a
    /// `team:` topic for a team you can merely see is refused.
    @Published private(set) var myTeamIDs: Set<UUID> = []
    /// Rosters keyed by team, loaded on demand — a pane showing five teams should
    /// not fetch five rosters nobody expanded.
    @Published var teamMembers: [UUID: [TeamMember]] = [:]
    /// `nil` is the personal context, which is where every account starts and
    /// where an account that never joins anything stays.
    @Published private(set) var activeOrgID: UUID?
    /// Who the signed-in person is, so the member list can tell their own row
    /// apart — you administer an organization, you do not administer yourself.
    @Published private(set) var currentUserID: UUID?
    @Published private(set) var members: [OrgMember] = [] {
        didSet { rebuildRoster() }
    }

    /// The one roster the People page renders, whichever RPC filled it.
    @Published private(set) var roster: [RosterEntry] = []
    /// Colleagues this account may address by name — see `org_directory`.
    ///
    /// Separate from `members`, which is the administrator's view and raises for
    /// everyone else. This one carries only what an invitation needs.
    @Published private(set) var directory: [Teammate] = [] {
        didSet { rebuildRoster() }
    }

    private var hasLoadedDirectory = false
    /// Everybody the organization knows about, including colleagues who have
    /// never installed Nod — imported from whichever tracker or chat the company
    /// connected. This is what an assignment picks from; `directory` is the
    /// narrower "who can I invite to a meeting" list.
    @Published private(set) var people: [Person] = []
    /// What the active organization is paying for. Nil until the Billing page
    /// asks, and nil again for an organization that has bought nothing.
    @Published private(set) var billing: OrgBilling?
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

    /// Counts invitations. Set by the composition root.
    var analytics: ProductAnalytics?

    init(supabase: SupabaseClient?) {
        self.supabase = supabase
    }

    var activeMembership: OrgMembership? {
        guard let activeOrgID else { return nil }
        return memberships.first { $0.id == activeOrgID }
    }

    private func rebuildRoster() {
        roster = Self.rosterEntries(members: members, directory: directory)
    }

    func teams(in orgID: UUID) -> [Team] {
        teams.filter { $0.orgID == orgID }
    }

    /// What to call the person something belongs to, when that is not the
    /// person looking at it. Nil on your own: there "Me" is exactly right, and
    /// naming yourself would be strange.
    func nameOfOwner(_ userID: UUID) -> String? {
        guard let viewer = currentUserID, viewer != userID else { return nil }
        return directory.first { $0.userID == userID }?.name
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

    /// The caller's memberships, with the organization each one is in.
    ///
    /// Asked for the logo first and again without it if the column isn't there.
    /// Sandbox and production keep their own migration histories and diverge on
    /// purpose, so a build can meet a database that predates a column it knows
    /// about — and losing every organization over an unknown column is a far
    /// worse answer than drawing the monogram for a while.
    private func membershipRows(of userID: UUID, from supabase: SupabaseClient) async throws -> [OrgMembershipRow] {
        func rows(_ columns: String) async throws -> [OrgMembershipRow] {
            try await supabase
                .from("org_members")
                .select("role, organizations(\(columns))")
                .eq("user_id", value: userID.uuidString)
                .eq("status", value: "active")
                .execute()
                .value
        }
        guard hasLogoColumn else { return try await rows("id, name, slug") }
        do {
            return try await rows("id, name, slug, logo_path")
        } catch {
            Log.ui.info("organizations have no logo_path yet; drawing monograms")
            hasLogoColumn = false
            return try await rows("id, name, slug")
        }
    }

    /// Its own `do/catch` rather than a line inside `refresh`'s. This decides
    /// which `team:` topics the access channel subscribes to, and the poke most
    /// likely to arrive alongside a failure is "you were removed from a team" —
    /// exactly when keeping the old set means re-subscribing to a topic the
    /// policy now refuses, and retrying that join forever.
    private func refreshMyTeamIDs(of userID: UUID, from supabase: SupabaseClient) async {
        guard !memberships.isEmpty else {
            myTeamIDs = []
            return
        }
        struct TeamMembershipRow: Decodable { let team_id: UUID }
        do {
            let rows: [TeamMembershipRow] = try await supabase
                .from("team_members")
                .select("team_id")
                .eq("user_id", value: userID.uuidString)
                .execute()
                .value
            myTeamIDs = Set(rows.map(\.team_id))
        } catch {
            // Narrowed, not kept: listening on nothing costs a poke that the
            // next refresh recovers; listening on a team you have left is a
            // channel stuck retrying a join it will never be granted.
            myTeamIDs = []
            Log.ui.error("OrganizationService team memberships failed: \(error.localizedDescription)")
        }
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
            let rows = try await membershipRows(of: userID, from: supabase)
            memberships = rows.compactMap(\.membership).sorted { $0.organization.name < $1.organization.name }

            teams = memberships.isEmpty ? [] : try await supabase
                .from("teams")
                .select("id, org_id, name")
                .execute()
                .value

            await refreshMyTeamIDs(of: userID, from: supabase)

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
        guard orgID == nil || memberships.contains(where: { $0.id == orgID }) else { return }
        let previous = activeOrgID
        activeOrgID = orgID
        guard await writeContext(orgID) else {
            activeOrgID = previous
            return
        }
        // Both rosters are scoped to the active context by the server, so the
        // ones in hand answer for the organization we just left. The cached
        // directory in particular survived every switch and every sign-out,
        // which meant a chat that had once loaded an empty roster never got
        // another one.
        hasLoadedDirectory = false
        directory = []
        async let roster: Void = refreshDirectoryIfNeeded()
        async let assignable: Void = refreshPeople()
        _ = await (roster, assignable)
    }

    private func writeContext(_ orgID: UUID?) async -> Bool {
        guard let supabase else { return false }
        do {
            struct Payload: Encodable {
                let active_org_id: UUID?
            }
            guard let userID = supabase.auth.currentUser?.id else { return false }
            try await supabase
                .from("profiles")
                .update(Payload(active_org_id: orgID))
                .eq("user_id", value: userID.uuidString)
                .execute()
            lastError = nil
            Log.ui.info("organization context set org=\(orgID?.uuidString ?? "personal")")
            return true
        } catch {
            lastError = "Couldn't switch context."
            Log.ui.error("OrganizationService.writeContext failed: \(error.localizedDescription)")
            return false
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
            analytics?.record(.inviteAccepted)
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
            analytics?.record(.teamMemberInvited, properties: .init(outcome: result.emailed ? .success : .empty))
            return true
        } catch {
            // The RPC writes its refusals for the person doing the inviting —
            // "that person is already a member", "only an owner can invite an
            // owner" — and `org-invite` passes them through untouched. Replacing
            // them with something generic here would throw away the only part of
            // the message that tells them what to do next.
            lastError = ServerError.functionMessage(error) ?? "Couldn't create that invite."
            Log.ui.error("OrganizationService.invite failed: \(error.localizedDescription)")
            return false
        }
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

    /// The Billing page's one read. Everything on it — the seat holders and the
    /// pooled hours — is derived server-side, because a client may not read
    /// `usage_events` across other people or ask who holds a seat.
    func loadBilling(in orgID: UUID) async {
        guard let supabase else { return }
        do {
            struct Params: Encodable { let p_org_id: UUID }
            let overview: OrgBilling = try await supabase
                .rpc("org_billing_overview", params: Params(p_org_id: orgID))
                .execute()
                .value
            billing = overview
            lastError = nil
        } catch {
            lastError = ServerError.rpcMessage(error) ?? "Couldn't read the workspace's billing."
            Log.ui.error("OrganizationService.loadBilling failed: \(error.localizedDescription)")
        }
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
            lastError = ServerError.rpcMessage(error) ?? "Couldn't change that role."
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
            lastError = ServerError.rpcMessage(error) ?? "Couldn't remove that person."
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
            lastError = ServerError.rpcMessage(error) ?? "Couldn't delete that organization."
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
            lastError = ServerError.rpcMessage(error) ?? "Couldn't leave that organization."
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
        myTeamIDs = []
        members = []
        pendingInvites = []
        teamMembers = [:]
        directory = []
        currentUserID = nil
        activeOrgID = nil
        hasLoaded = false
        hasLoadedDirectory = false
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

    // MARK: - The organization's mark

    /// The bucket is public, so the mark is a plain URL: it sits beside the name
    /// wherever the name is shown, and a signed link would expire mid-sidebar.
    func logoURL(for organization: Organization) -> URL? {
        guard let supabase, let path = organization.logoPath, !path.isEmpty else { return nil }
        return try? supabase.storage.from(Self.logoBucket).getPublicURL(path: path)
    }

    /// Uploads a square PNG and points the organization at it.
    ///
    /// Two writes, in this order on purpose: the object first, the row second.
    /// A row pointing at an object that failed to upload draws a broken image
    /// for everyone in the organization, while an object nothing points at is
    /// invisible and reclaimed by the next attempt.
    func setLogo(_ image: NSImage, for orgID: UUID) async -> Bool {
        guard let supabase else { return false }
        guard let png = Self.square(image, side: Self.logoSide) else {
            lastError = "That image couldn't be read."
            return false
        }
        let previous = memberships.first { $0.id == orgID }?.organization.logoPath
        let path = Self.logoPath(for: orgID, content: png)
        guard path != previous else {
            lastError = nil
            return true
        }
        do {
            _ = try await supabase.storage
                .from(Self.logoBucket)
                .upload(path, data: png, options: FileOptions(contentType: "image/png", upsert: true))
            struct Params: Encodable {
                let p_org: UUID
                let p_path: String
            }
            _ = try await supabase.rpc("set_org_logo", params: Params(p_org: orgID, p_path: path)).execute()
            // Last, and unchecked: the row already points at the new object, so
            // a failure here leaves storage to reclaim rather than a colleague
            // looking at a logo that no longer exists.
            if let previous, !previous.isEmpty {
                _ = try? await supabase.storage.from(Self.logoBucket).remove(paths: [previous])
            }
            lastError = nil
            await refresh()
            return true
        } catch {
            Log.ui.error("OrganizationService.setLogo failed: \(error.localizedDescription)")
            lastError = "Couldn't upload that image."
            return false
        }
    }

    /// Clears the mark and removes the object behind it. The row is cleared
    /// first here — the opposite order to setting one — because what is drawn is
    /// what matters, and an object left behind is storage to reclaim rather than
    /// a broken image.
    func removeLogo(for orgID: UUID) async {
        guard let supabase else { return }
        do {
            struct Params: Encodable {
                let p_org: UUID
                let p_path: String?
            }
            let previous = memberships.first { $0.id == orgID }?.organization.logoPath
            _ = try await supabase.rpc("set_org_logo", params: Params(p_org: orgID, p_path: nil)).execute()
            if let previous, !previous.isEmpty {
                _ = try? await supabase.storage.from(Self.logoBucket).remove(paths: [previous])
            }
            lastError = nil
            await refresh()
        } catch {
            Log.ui.error("OrganizationService.removeLogo failed: \(error.localizedDescription)")
            lastError = "Couldn't remove that image."
        }
    }

    /// Cleared the first time the database says otherwise, so the fallback is
    /// paid once per launch rather than on every refresh.
    private var hasLogoColumn = true

    /// Named for what it holds, so replacing a logo is a different object at a
    /// different URL.
    ///
    /// The old name was a fixed `logo.png`, which meant a *replacement* left
    /// every viewer's `URLSession` cache and the CDN in front of it serving the
    /// picture that had just been thrown away — a poke telling them to re-read
    /// the row could not help, because the row still said the same thing. The
    /// bucket's policies match on the first path segment alone, so the rest of
    /// the name is ours to choose.
    nonisolated static func logoPath(for orgID: UUID, content: Data) -> String {
        let digest = SHA256.hash(data: content).prefix(8).map { String(format: "%02x", $0) }.joined()
        return "\(orgID.uuidString.lowercased())/\(digest).png"
    }

    private static let logoBucket = "org-logos"
    /// Drawn at 32pt at most, so this is twice the biggest Retina size it needs
    /// — enough that nobody uploads a 4MB photograph of their office wall.
    private static let logoSide: CGFloat = 256

    /// Centre-cropped to a square and redrawn at `side`, because the tile it
    /// goes into is square: letting the server keep a 4000×3000 original would
    /// mean every client downloads it to draw 32 points of it.
    private static func square(_ image: NSImage, side: CGFloat) -> Data? {
        let source = image.size
        guard source.width > 0, source.height > 0 else { return nil }
        let scale = max(side / source.width, side / source.height)
        let scaled = NSSize(width: source.width * scale, height: source.height * scale)
        let origin = NSPoint(x: (side - scaled.width) / 2, y: (side - scaled.height) / 2)

        let canvas = NSImage(size: NSSize(width: side, height: side))
        canvas.lockFocus()
        NSGraphicsContext.current?.imageInterpolation = .high
        image.draw(in: NSRect(origin: origin, size: scaled))
        canvas.unlockFocus()

        guard let tiff = canvas.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiff)
        else { return nil }
        return bitmap.representation(using: .png, properties: [:])
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
