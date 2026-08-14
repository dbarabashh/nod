import Combine
import Foundation
import Supabase

/// Owns the user's labels and which sessions carry them. Labels group sessions
/// thematically so the library can be filtered and a cross-session question can
/// be scoped to one label's sessions. RLS (`auth.uid() = user_id`) scopes every
/// read/write to the owner.
@MainActor
final class LabelStore: ObservableObject {
    @Published private(set) var labels: [SessionLabel] = []
    /// meetingID → the labels attached to it.
    @Published private(set) var assignments: [UUID: Set<UUID>] = [:]
    /// Which folders are shared, and with whom. Keyed by folder so a row can ask
    /// without scanning.
    @Published private(set) var shares: [UUID: [FolderShare]] = [:]

    private let supabase: SupabaseClient
    private let auth: AuthService
    private static let labelsTable = "labels"
    private static let linksTable = "meeting_labels"

    init(supabase: SupabaseClient, auth: AuthService) {
        self.supabase = supabase
        self.auth = auth
    }

    // MARK: - Reads

    /// Loads all labels and their session links for the signed-in user.
    func refresh() async {
        #if DEBUG
            if DemoMode.isEnabled {
                labels = DemoData.labels
                assignments = DemoData.labelAssignments
                return
            }
        #endif
        guard auth.currentSupabaseSession != nil else { return }
        do {
            // No `user_id` filter: row-level security already returns your folders
            // plus the ones shared with a team you are in, and filtering here
            // would throw the shared ones away before they were ever seen. Which
            // are yours is answered by `isOwn`, not by the query.
            let labels: [SessionLabel] = try await supabase
                .from(Self.labelsTable)
                .select()
                .order("name", ascending: true)
                .execute()
                .value

            struct Link: Decodable { let meeting_id: UUID; let label_id: UUID }
            let links: [Link] = try await supabase
                .from(Self.linksTable)
                .select("meeting_id, label_id")
                .execute()
                .value

            var map: [UUID: Set<UUID>] = [:]
            for link in links {
                map[link.meeting_id, default: []].insert(link.label_id)
            }
            self.labels = labels
            assignments = map
        } catch {
            Log.ui.error("LabelStore.refresh failed: \(error.localizedDescription)")
        }
        await refreshShares()
    }

    /// Labels attached to one session, in display order.
    func labels(for meetingID: UUID) -> [SessionLabel] {
        let ids = assignments[meetingID] ?? []
        return labels.filter { ids.contains($0.id) }
    }

    /// Sessions carrying a label — drives list filtering and chat scoping.
    func meetingIDs(withLabel labelID: UUID) -> Set<UUID> {
        var result: Set<UUID> = []
        for (meetingID, labelIDs) in assignments where labelIDs.contains(labelID) {
            result.insert(meetingID)
        }
        return result
    }

    // MARK: - Label CRUD

    /// Creates a label, or returns the existing one if the name is already
    /// taken (case-insensitive) — the unique index makes create idempotent.
    @discardableResult
    func create(name: String, color: String) async throws -> SessionLabel? {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        if let existing = labels.first(where: { $0.name.localizedCaseInsensitiveCompare(trimmed) == .orderedSame }) {
            return existing
        }
        #if DEBUG
            if DemoMode.isEnabled {
                let local = SessionLabel(id: UUID(), userID: UUID(), name: trimmed, color: color, createdAt: nil)
                labels.append(local)
                labels.sort { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
                return local
            }
        #endif
        guard let userID = auth.currentSupabaseSession?.user.id else { return nil }
        let draft = SessionLabel(id: UUID(), userID: userID, name: trimmed, color: color, createdAt: nil)
        let saved: SessionLabel = try await supabase
            .from(Self.labelsTable)
            .insert(draft)
            .select()
            .single()
            .execute()
            .value
        labels.append(saved)
        labels.sort { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        return saved
    }

    /// Renames and/or recolours a label. A name that collides with another
    /// label (case-insensitive) is ignored — the unique index would reject it —
    /// but the colour still applies, so recolouring never silently fails.
    func update(_ labelID: UUID, name: String, color: String) async throws {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let current = labels.first(where: { $0.id == labelID }) else { return }
        let collides = labels.contains {
            $0.id != labelID && $0.name.localizedCaseInsensitiveCompare(trimmed) == .orderedSame
        }
        let finalName = (trimmed.isEmpty || collides) ? current.name : trimmed
        #if DEBUG
            if DemoMode.isEnabled {
                if let idx = labels.firstIndex(where: { $0.id == labelID }) {
                    labels[idx] = SessionLabel(
                        id: current.id,
                        userID: current.userID,
                        name: finalName,
                        color: color,
                        createdAt: current.createdAt
                    )
                    labels.sort { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
                }
                return
            }
        #endif
        try await supabase
            .from(Self.labelsTable)
            .update(["name": finalName, "color": color])
            .eq("id", value: labelID.uuidString)
            .execute()
        if let idx = labels.firstIndex(where: { $0.id == labelID }) {
            labels[idx] = SessionLabel(id: current.id, userID: current.userID, name: finalName, color: color, createdAt: current.createdAt)
            labels.sort { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        }
    }

    /// Deletes a label. `meeting_labels` rows cascade server-side.
    func delete(_ labelID: UUID) async throws {
        #if DEBUG
            if DemoMode.isEnabled {
                labels.removeAll { $0.id == labelID }
                for (meetingID, ids) in assignments where ids.contains(labelID) {
                    assignments[meetingID]?.remove(labelID)
                }
                return
            }
        #endif
        try await supabase
            .from(Self.labelsTable)
            .delete()
            .eq("id", value: labelID.uuidString)
            .execute()
        labels.removeAll { $0.id == labelID }
        for (meetingID, ids) in assignments where ids.contains(labelID) {
            assignments[meetingID]?.remove(labelID)
        }
    }

    // MARK: - Assignment

    /// Sets the exact set of labels on a session, inserting/deleting only the
    /// links that changed.
    func setLabels(_ desired: Set<UUID>, for meetingID: UUID) async throws {
        #if DEBUG
            if DemoMode.isEnabled {
                assignments[meetingID] = desired.isEmpty ? nil : desired
                return
            }
        #endif
        guard let userID = auth.currentSupabaseSession?.user.id else { return }
        let current = assignments[meetingID] ?? []
        let added = desired.subtracting(current)
        let removed = current.subtracting(desired)
        guard !added.isEmpty || !removed.isEmpty else { return }

        if !added.isEmpty {
            struct LinkInsert: Encodable {
                let meeting_id: UUID
                let label_id: UUID
                let user_id: UUID
            }
            let rows = added.map { LinkInsert(meeting_id: meetingID, label_id: $0, user_id: userID) }
            try await supabase
                .from(Self.linksTable)
                .upsert(rows, onConflict: "meeting_id,label_id")
                .execute()
        }
        if !removed.isEmpty {
            try await supabase
                .from(Self.linksTable)
                .delete()
                .eq("meeting_id", value: meetingID.uuidString)
                .in("label_id", values: removed.map(\.uuidString))
                .execute()
        }
        assignments[meetingID] = desired.isEmpty ? nil : desired
    }

    // ── Sharing ─────────────────────────────────────────────────────────────

    func refreshShares() async {
        do {
            let rows: [FolderShare] = try await supabase
                .from("folder_shares")
                .select("id, label_id, team_id, org_id")
                .execute()
                .value
            shares = Dictionary(grouping: rows, by: \.labelID)
        } catch {
            Log.ui.error("LabelStore.refreshShares failed: \(error.localizedDescription)")
        }
    }

    /// Whether this folder is yours. Someone else's folder can be read once they
    /// share it, and read is all — renaming, deleting or re-sharing it belongs to
    /// the person who made it, and the server refuses the rest anyway.
    func isOwn(_ label: SessionLabel) -> Bool {
        label.userID == auth.currentSupabaseSession?.user.id
    }

    func isShared(_ labelID: UUID) -> Bool {
        !(shares[labelID]?.isEmpty ?? true)
    }

    /// Hands a folder to a team, or to the whole organization. The server checks
    /// that the folder is yours and that you belong to the audience — sharing
    /// into a team you are not in would be publishing to strangers.
    func share(_ labelID: UUID, withTeam teamID: UUID?, org orgID: UUID?) async {
        do {
            struct Params: Encodable {
                let p_label: UUID
                let p_team: UUID?
                let p_org: UUID?
            }
            _ = try await supabase
                .rpc("share_folder", params: Params(p_label: labelID, p_team: teamID, p_org: orgID))
                .execute()
            await refreshShares()
            Log.ui.info("folder shared")
        } catch {
            Log.ui.error("LabelStore.share failed: \(error.localizedDescription)")
        }
    }

    func unshare(_ share: FolderShare) async {
        do {
            struct Params: Encodable {
                let p_share: UUID
            }
            _ = try await supabase.rpc("unshare_folder", params: Params(p_share: share.id)).execute()
            await refreshShares()
            Log.ui.info("folder unshared")
        } catch {
            Log.ui.error("LabelStore.unshare failed: \(error.localizedDescription)")
        }
    }

    func clear() {
        shares = [:]
        labels = []
        assignments = [:]
    }
}
