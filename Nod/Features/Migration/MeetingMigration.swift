import AppKit
import Combine
import Foundation
import Supabase

enum NewNod {
    static let downloadURL = URL(string: "https://hellonod.app/download")
}

/// Moving to the new Nod: write every meeting this account recorded to one
/// `nod-meetings` file the new app imports, then, once the user has it, offer to
/// erase the cloud copy and the account.
@MainActor
final class MeetingMigration: ObservableObject {
    enum ExportState: Equatable {
        case idle
        case fetchingMeetings
        case fetchingTranscripts(done: Int, total: Int)
        case saving
        case exported(count: Int)
        case outdated
        case failed(String)
    }

    @Published private(set) var exportState: ExportState = .idle
    @Published private(set) var isDeleting = false
    @Published private(set) var deleteError: String?
    @Published private(set) var isBannerDismissed = false

    private let supabase: SupabaseClient
    private let auth: AuthService
    private let meetingStore: MeetingStore
    private let outbox: MeetingOutbox
    private var accountChange: AnyCancellable?
    private var syncChange: AnyCancellable?
    private var listChange: AnyCancellable?
    /// What the saved file holds, and for whom: the delete re-reads the server
    /// and refuses unless it still matches this exactly.
    private var exported: (userID: UUID, meetings: [ArchivedMeeting])?
    private var exportedLocalMeetings: [Meeting]?

    private static let pageSize = 500
    private static let meetingsPerTranscriptQuery = 50

    init(supabase: SupabaseClient, auth: AuthService, meetingStore: MeetingStore, outbox: MeetingOutbox) {
        self.supabase = supabase
        self.auth = auth
        self.meetingStore = meetingStore
        self.outbox = outbox
        accountChange = auth.$session
            .map { $0?.user.id }
            .removeDuplicates()
            .dropFirst()
            .sink { [weak self] _ in self?.reset() }
        syncChange = Publishers.CombineLatest3(
            meetingStore.$unsyncedMeetingIDs,
            meetingStore.$finalizingMeetingIDs,
            meetingStore.$recordingMeetingID
        )
        .sink { [weak self] _ in self?.objectWillChange.send() }
        listChange = meetingStore.$meetings
            .sink { [weak self] meetings in self?.invalidateExport(ifChanged: meetings) }
    }

    /// Meetings still recording, finishing, or waiting in the outbox: the
    /// server does not have them yet, so the export cannot contain them and
    /// deleting the account would lose them.
    var unsyncedCount: Int {
        var pending = meetingStore.unsyncedMeetingIDs.union(meetingStore.finalizingMeetingIDs)
        if let recording = meetingStore.recordingMeetingID { pending.insert(recording) }
        return pending.count
    }

    private func invalidateExport(ifChanged meetings: [Meeting]) {
        guard hasExported, let exportedLocalMeetings, exportedLocalMeetings != meetings else { return }
        markOutdated()
    }

    private func markOutdated() {
        exportState = .outdated
        exported = nil
        exportedLocalMeetings = nil
    }

    private func reset() {
        exportState = .idle
        exported = nil
        exportedLocalMeetings = nil
        deleteError = nil
        isBannerDismissed = false
    }

    var isExporting: Bool {
        switch exportState {
        case .fetchingMeetings, .fetchingTranscripts, .saving: true
        case .idle, .exported, .outdated, .failed: false
        }
    }

    var hasExported: Bool {
        if case .exported = exportState { return true }
        return false
    }

    func dismissBanner() {
        isBannerDismissed = true
    }

    func openDownloadPage() {
        guard let url = NewNod.downloadURL else { return }
        NSWorkspace.shared.open(url)
    }

    func export() async {
        guard !isExporting else { return }
        guard let userID = supabase.auth.currentUser?.id else {
            exportState = .failed("You're signed out. Sign in again, then export.")
            return
        }
        exportState = .fetchingMeetings
        let localBefore = meetingStore.meetings
        let recordingBefore = meetingStore.recordingMeetingID
        do {
            let meetings = try await fetchArchivedMeetings(userID: userID, showingProgress: true)
            guard supabase.auth.currentUser?.id == userID else {
                exportState = .idle
                return
            }
            guard meetingStore.meetings == localBefore, meetingStore.recordingMeetingID == recordingBefore else {
                markOutdated()
                return
            }
            exportState = .saving
            let archive = MeetingArchive(exportedAt: Date(), meetings: meetings)
            let data = try archive.encoded()
            guard let url = presentSavePanel() else {
                exportState = .idle
                return
            }
            do {
                try data.write(to: url, options: .atomic)
            } catch {
                Log.ui.error("MeetingMigration could not write the file: \(error.localizedDescription)")
                exportState = .failed("Couldn't save the file there. Try another folder.")
                return
            }
            guard supabase.auth.currentUser?.id == userID else {
                exportState = .idle
                return
            }
            Log.ui.info("MeetingMigration exported \(archive.meetings.count) meetings, \(data.count) bytes")
            exported = (userID, meetings)
            exportedLocalMeetings = localBefore
            exportState = .exported(count: archive.meetings.count)
            if meetingStore.meetings != localBefore || meetingStore.recordingMeetingID != recordingBefore {
                markOutdated()
            }
        } catch {
            Log.ui.error("MeetingMigration.export failed: \(error.localizedDescription)")
            exportState = .failed(Self.exportFailure(error))
        }
    }

    /// Why the account may not be deleted yet, or nil when it may. Checked
    /// here as well as by the view: a stale button or a second window must not
    /// be able to erase meetings that never made it into the file.
    nonisolated static func deleteBlocker(state: ExportState, pendingCount: Int) -> String? {
        if pendingCount > 0 {
            return "Some meetings haven't synced yet, so they aren't in your export. Keep Nod open until they sync, then export again."
        }
        switch state {
        case .exported:
            return nil
        case .outdated:
            return "Your meetings changed after the export. Export again before deleting."
        case .idle, .fetchingMeetings, .fetchingTranscripts, .saving, .failed:
            return "Export your meetings first."
        }
    }

    func deleteAccount() async {
        guard !isDeleting else { return }
        isDeleting = true
        deleteError = nil
        defer { isDeleting = false }

        guard let userID = supabase.auth.currentUser?.id, let exported, exported.userID == userID else {
            deleteError = Self.deleteBlocker(state: .idle, pendingCount: 0)
            return
        }
        let waiting = await outbox.pendingCompletedMeetings(for: userID).count
        if let blocker = Self.deleteBlocker(state: exportState, pendingCount: waiting + unsyncedCount) {
            deleteError = blocker
            return
        }
        do {
            let current = try await fetchArchivedMeetings(userID: userID, showingProgress: false)
            guard current == exported.meetings else {
                markOutdated()
                deleteError = Self.deleteBlocker(state: .outdated, pendingCount: 0)
                return
            }
        } catch {
            Log.ui.error("MeetingMigration could not re-check the export: \(error.localizedDescription)")
            deleteError = Self.exportFailure(error)
            return
        }
        do {
            try await auth.deleteAccount()
        } catch {
            Log.ui.error("MeetingMigration.deleteAccount failed: \(error.localizedDescription)")
            deleteError = Self.deleteFailure(error)
        }
    }

    private func fetchArchivedMeetings(userID: UUID, showingProgress: Bool) async throws -> [ArchivedMeeting] {
        let rows = try await fetchMeetings(userID: userID)
        let ids = rows.map(\.id)
        let transcripts = try await fetchTranscripts(for: ids, showingProgress: showingProgress)
        let folders = try await MeetingArchive.folders(
            links: fetchLabelLinks(for: ids),
            labels: fetchLabels(userID: userID),
            ownerID: userID
        )
        return MeetingArchive.make(rows: rows, transcripts: transcripts, folders: folders, exportedAt: Date()).meetings
    }

    /// Keyset paging on `id`, not offsets: a meeting added or trashed while
    /// the export runs cannot shift the pages under it. `(started_at, id)` was
    /// passed over because the cursor would carry a microsecond timestamp
    /// through a URL, where Postgres' `+00:00` reads as a space.
    private func fetchMeetings(userID: UUID) async throws -> [MeetingArchiveRow] {
        var rows: [MeetingArchiveRow] = []
        var cursor: UUID?
        while true {
            var query = supabase
                .from("meetings")
                .select(MeetingArchiveRow.columns)
                .eq("user_id", value: userID.uuidString)
                .is("deleted_at", value: nil)
                .or("origin.is.null,origin.neq.welcome")
            if let cursor {
                query = query.gt("id", value: cursor.uuidString.lowercased())
            }
            let page: [MeetingArchiveRow] = try await query
                .order("id", ascending: true)
                .limit(Self.pageSize)
                .execute()
                .value
            guard let last = page.last else { return rows }
            rows += page
            cursor = last.id
        }
    }

    private func fetchTranscripts(
        for meetingIDs: [UUID],
        showingProgress: Bool
    ) async throws -> [UUID: [TranscriptArchiveRow]] {
        var byMeeting: [UUID: [TranscriptArchiveRow]] = [:]
        var done = 0
        if showingProgress { exportState = .fetchingTranscripts(done: 0, total: meetingIDs.count) }
        for start in stride(from: 0, to: meetingIDs.count, by: Self.meetingsPerTranscriptQuery) {
            let batch = Array(meetingIDs[start ..< min(start + Self.meetingsPerTranscriptQuery, meetingIDs.count)])
            var fetched = 0
            while true {
                let page: [TranscriptArchiveRow] = try await supabase
                    .from("meeting_transcripts")
                    .select(TranscriptArchiveRow.columns)
                    .in("meeting_id", values: batch.map(\.uuidString))
                    .order("meeting_id", ascending: true)
                    .order("idx", ascending: true)
                    .range(from: fetched, to: fetched + Self.pageSize - 1)
                    .execute()
                    .value
                guard !page.isEmpty else { break }
                fetched += page.count
                for row in page {
                    byMeeting[row.meetingID, default: []].append(row)
                }
            }
            done += batch.count
            if showingProgress { exportState = .fetchingTranscripts(done: done, total: meetingIDs.count) }
        }
        return byMeeting
    }

    private func fetchLabels(userID: UUID) async throws -> [LabelArchiveRow] {
        var labels: [LabelArchiveRow] = []
        while true {
            let page: [LabelArchiveRow] = try await supabase
                .from("labels")
                .select(LabelArchiveRow.columns)
                .eq("user_id", value: userID.uuidString)
                .order("id", ascending: true)
                .range(from: labels.count, to: labels.count + Self.pageSize - 1)
                .execute()
                .value
            guard !page.isEmpty else { return labels }
            labels += page
        }
    }

    private func fetchLabelLinks(for meetingIDs: [UUID]) async throws -> [MeetingLabelArchiveRow] {
        var links: [MeetingLabelArchiveRow] = []
        for start in stride(from: 0, to: meetingIDs.count, by: Self.meetingsPerTranscriptQuery) {
            let batch = Array(meetingIDs[start ..< min(start + Self.meetingsPerTranscriptQuery, meetingIDs.count)])
            var fetched = 0
            while true {
                let page: [MeetingLabelArchiveRow] = try await supabase
                    .from("meeting_labels")
                    .select(MeetingLabelArchiveRow.columns)
                    .in("meeting_id", values: batch.map(\.uuidString))
                    .order("meeting_id", ascending: true)
                    .order("label_id", ascending: true)
                    .range(from: fetched, to: fetched + Self.pageSize - 1)
                    .execute()
                    .value
                guard !page.isEmpty else { break }
                fetched += page.count
                links += page
            }
        }
        return links
    }

    private func presentSavePanel() -> URL? {
        let panel = NSSavePanel()
        panel.title = "Export meetings for the new Nod"
        panel.nameFieldStringValue = "nod-meetings.json"
        panel.allowedContentTypes = [.json]
        panel.isExtensionHidden = false
        panel.directoryURL = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
        return panel.runModal() == .OK ? panel.url : nil
    }

    private static func exportFailure(_ error: Error) -> String {
        if error is URLError {
            return "Couldn't reach Nod. Check your internet connection and try again."
        }
        return "Couldn't export your meetings. Please try again."
    }

    private static func deleteFailure(_ error: Error) -> String {
        if ServerError.functionCode(error) == "org_has_member_data" {
            return "An organization you created still holds meetings from people who have left it, so it can't be removed automatically. Email dmytro@hellonod.app and we'll finish deleting your account."
        }
        if error is URLError {
            return "Couldn't reach Nod. Check your internet connection and try again."
        }
        return "Couldn't delete your account. Please try again."
    }
}
