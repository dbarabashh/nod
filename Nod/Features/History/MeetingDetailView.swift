import SwiftUI

/// Editable view of a single meeting — title + summary (autosaved on a
/// 1-second debounce) plus a read-only Transcript tab that lazy-loads
/// from `meeting_transcripts` on first open.
///
/// The shell: it owns the editors, the save/delete lifecycle and the transcript
/// fetch, and hands each band of the page to its own view. What those bands do
/// with the meeting — copy it, share it, export it, render it — belongs to them.
struct MeetingDetailView: View {
    let meeting: Meeting
    let onClose: () -> Void

    @EnvironmentObject private var meetingStore: MeetingStore
    @EnvironmentObject private var organizations: OrganizationService
    @EnvironmentObject private var summaryRegeneration: SummaryRegeneration
    @EnvironmentObject private var analytics: ProductAnalytics

    @State private var editableTitle: String = ""
    @State private var editableSummary: String = ""
    /// Edited alongside the markdown, and saved in the same patch — see
    /// `MeetingSummaryTab.correct`.
    @State private var editableRecap: MeetingRecap?
    @State private var isConfirmingRegenerate = false
    @State private var saveState: SaveState = .idle
    @State private var saveTask: Task<Void, Never>?
    /// True while there are pending edits the user has typed but the
    /// debounce hasn't fired yet (or a save is in flight). Used by
    /// `.onDisappear` so a close-mid-typing still flushes the latest
    /// version instead of losing the unwritten characters.
    @State private var isDirty: Bool = false
    /// True while the soft-delete is in-flight, OR after the user
    /// confirmed delete — used to suppress the `.onDisappear` save flush
    /// so we don't undo the delete by saving the local buffer right after.
    @State private var isDeleting: Bool = false
    @State private var isEditingSummary: Bool = false
    @State private var selectedTab: Tab = .summary
    @State private var transcriptLoad: TranscriptLoadState = .idle
    /// Other people's recordings of this same meeting, asked once per open.
    @State private var sameMeetings: [SameMeeting] = []
    @State private var isMerging = false

    enum Tab: Hashable {
        case summary
        case transcript
    }

    private enum SaveState: Equatable {
        case idle
        case saving
        case saved
        case failed(String)
    }

    /// Live meeting from the store — picks up the title + summary that
    /// the end-of-meeting flow writes via `applyGenerated` after the LLM
    /// returns. Falls back to the captured `meeting` value when the store
    /// hasn't loaded yet (deep-link or refresh race).
    private var current: Meeting {
        meetingStore.byID[meeting.id] ?? meeting
    }

    /// The meeting as it stands in the editors. What Copy and Export write out:
    /// the version on screen, not the one last written to the server.
    private var edited: Meeting {
        let title = editableTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        return current.updating(title: title.isEmpty ? nil : title, summary: editableSummary, recap: editableRecap)
    }

    /// True while ContentView's post-meeting Task is still waiting on the
    /// LLM. Drives the loading placeholder in the Summary tab.
    private var isGenerating: Bool {
        meetingStore.generatingSummaryIDs.contains(meeting.id)
    }

    /// True until the generated meeting row and transcript have finished their
    /// first persistence pass.
    private var isFinalizing: Bool {
        meetingStore.finalizingMeetingIDs.contains(meeting.id)
    }

    /// Finished generating but still waiting on the server (durable outbox).
    /// Gated on `!isFinalizing` so the first-pass persistence shows its own
    /// "Finishing…" state, not a sync warning.
    private var isUnsynced: Bool {
        !isFinalizing && meetingStore.unsyncedMeetingIDs.contains(meeting.id)
    }

    /// Partial recap markdown streamed in while the summary generates, or nil
    /// before the first section closes.
    private var streamingSummary: String? {
        let partial = meetingStore.streamingSummaries[meeting.id]
        return (partial?.isEmpty == false) ? partial : nil
    }

    var body: some View {
        ScrollView(.vertical, showsIndicators: true) {
            VStack(alignment: .leading, spacing: 18) {
                MeetingDetailHeader(
                    title: $editableTitle,
                    isGenerating: isGenerating,
                    isFinalizing: isFinalizing,
                    isDeleting: isDeleting,
                    onClose: onClose,
                    onDelete: deleteMeeting,
                    onTitleEdited: scheduleSave
                )
                if !isFinalizing { MeetingFoldersRow(meetingID: meeting.id) }
                if !sameMeetings.isEmpty, !isFinalizing {
                    SameMeetingBanner(
                        candidates: sameMeetings,
                        canRead: { $0.isMine || meetingStore.byID[$0.meetingID] != nil },
                        isMerging: isMerging,
                        onMerge: mergeInto,
                        onDismiss: { sameMeetings = [] }
                    )
                }
                MeetingDetailMetadata(meeting: current, isUnsynced: isUnsynced)
                MeetingDetailTabBar(selection: $selectedTab)
                subToolbar
                Divider().overlay(Theme.Palette.border)
                content
                if selectedTab == .summary, !isFinalizing {
                    ActionItemsView(meeting: meeting)
                    RelatedSessionsView(meeting: meeting)
                }
            }
            .padding(.horizontal, 28)
            .padding(.vertical, 22)
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
        .tooltipContainer()
        .background(Color.clear)
        .navigationTitle("")
        .confirmationDialog(
            "Rebuild this summary?",
            isPresented: $isConfirmingRegenerate,
            titleVisibility: .visible
        ) {
            Button("Rebuild", role: .destructive) { rebuildSummary() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("It is written again from the transcript, and replaces what is here — including any lines corrected by hand.")
        }
        .onAppear {
            seedEditors(from: current)
            recordSummaryViewedIfRendered()
            Task { sameMeetings = await meetingStore.sameMeetingCandidates(for: meeting.id) }
        }
        .onChange(of: selectedTab) { tab in
            if tab == .transcript, !isFinalizing, case .idle = transcriptLoad {
                Task { await loadTranscript() }
            }
            if tab == .transcript {
                analytics.recordMeetingInteraction(
                    .transcriptViewed,
                    contentType: .transcript,
                    meeting: current,
                    outcome: .viewed,
                    oncePerSession: "transcript:\(meeting.id.uuidString)"
                )
            } else {
                recordSummaryViewedIfRendered()
            }
        }
        .onChange(of: isGenerating) { generating in
            // Generation transition is the ONLY moment we sync
            // current.summary/title into the editors. A body-level
            // `.onChange(of: current.summary)` would also fire after
            // every autosave round-trip and clobber typing the user
            // did during the server PATCH (`abc` saved, user typed
            // `def` during the 300ms roundtrip → onChange overwrites
            // `abcdef` with the stale `abc`).
            guard !generating else { return }
            if editableSummary != current.summary || editableRecap != current.recap {
                editableSummary = current.summary
                editableRecap = current.recap
            }
            let liveTitle = current.title ?? ""
            if editableTitle != liveTitle {
                editableTitle = liveTitle
            }
            recordSummaryViewedIfRendered()
        }
        .onChange(of: isFinalizing) { finalizing in
            if finalizing {
                if selectedTab == .transcript { transcriptLoad = .idle }
                return
            }
            if selectedTab == .transcript, shouldLoadTranscriptAfterFinalizing {
                Task { await loadTranscript() }
            }
            recordSummaryViewedIfRendered()
        }
        .onDisappear(perform: flushPendingSaveOnDisappear)
    }

    /// The save indicator rides beside the summary toolbar rather than inside
    /// it: it reports on the editors, which the toolbar never touches.
    @ViewBuilder
    private var subToolbar: some View {
        let toolbar = MeetingDetailToolbar(
            meeting: edited,
            tab: selectedTab,
            isEditingSummary: $isEditingSummary,
            isFinalizing: isFinalizing,
            isGenerating: isGenerating,
            transcript: transcriptLoad,
            hostName: hostName
        )
        if selectedTab == .summary {
            HStack(spacing: 12) {
                toolbar
                if !isFinalizing {
                    saveIndicator
                        .fixedSize()
                }
            }
            .padding(.vertical, 2)
        } else {
            toolbar
        }
    }

    @ViewBuilder
    private var content: some View {
        switch selectedTab {
        case .summary:
            MeetingSummaryTab(
                meeting: current,
                summary: $editableSummary,
                recap: editableRecap,
                onCorrect: correct,
                isGenerating: isGenerating,
                isEditing: isEditingSummary,
                isFinalizing: isFinalizing,
                isUnsynced: isUnsynced,
                streamingPartial: streamingSummary,
                onEdited: scheduleSave,
                onRegenerate: regenerateSummary
            )
            // Under the recap, not over it: what the meeting was is the thing
            // the user came to read, and what to do about it follows from it.
            ProposalReviewList(meetingID: meeting.id)
        case .transcript:
            MeetingTranscriptTab(
                state: transcriptLoad,
                isFinalizing: isFinalizing,
                speakerNames: current.speakerNames,
                hostName: hostName,
                selfSpeaker: current.selfSpeaker,
                isResolvingRemoteSpeakers: meetingStore.resolvingSpeakerIDs.contains(meeting.id),
                people: correctablePeople,
                canCorrectSpeakers: !meetingStore.isSharedWithMe(current),
                onConfirmSpeaker: confirmSpeaker,
                onRetry: { Task { await loadTranscript() } }
            )
        }
    }

    @ViewBuilder
    private var saveIndicator: some View {
        switch saveState {
        case .idle:
            EmptyView()
        case .saving:
            HStack(spacing: 4) {
                ProgressView()
                    .progressViewStyle(.circular)
                    .controlSize(.mini)
                    .tint(Theme.Palette.muted)
                Text("Saving…")
                    .font(.system(size: 11, weight: .regular))
                    .foregroundStyle(Theme.Palette.muted)
            }
        case .saved:
            HStack(spacing: 4) {
                Image("nc-circle-check")
                    .icon(11)
                    .foregroundStyle(Theme.Palette.success)
                Text("Saved")
                    .font(.system(size: 11, weight: .regular))
                    .foregroundStyle(Theme.Palette.muted)
            }
        case let .failed(detail):
            HStack(spacing: 4) {
                Image("nc-triangle-warning")
                    .icon(11)
                    .foregroundStyle(Theme.Palette.warning)
                Text("Couldn't save")
                    .font(.system(size: 11, weight: .regular))
                    .foregroundStyle(Theme.Palette.warning)
                    .help(detail)
            }
        }
    }

    // MARK: - Transcript

    private var shouldLoadTranscriptAfterFinalizing: Bool {
        switch transcriptLoad {
        case .idle:
            true
        case let .loaded(records):
            records.isEmpty
        case .loading, .failed:
            false
        }
    }

    private func loadTranscript() async {
        guard !isFinalizing else { return }
        transcriptLoad = .loading
        do {
            let records = try await meetingStore.fetchTranscript(meetingID: meeting.id)
            transcriptLoad = .loaded(records)
        } catch {
            Log.ui.error("MeetingDetailView fetchTranscript failed: \(error.localizedDescription)")
            transcriptLoad = .failed(error.localizedDescription)
        }
    }

    private var hostName: String? {
        organizations.nameOfOwner(current.userID)
    }

    /// Who a voice in this recording may be attributed to.
    ///
    /// Everybody the organization knows about, including colleagues who have
    /// never installed Nod — a contractor in the company's tracker speaks in
    /// meetings too. Empty on a personal account, where the correction becomes
    /// typing the name.
    private var correctablePeople: [Person] {
        organizations.people
    }

    private func confirmSpeaker(cluster: Int, person: Person?, typedName: String?) {
        Task {
            let saved = await meetingStore.confirmSpeaker(
                cluster: cluster,
                personID: person?.personID,
                name: person?.name ?? typedName,
                for: meeting.id
            )
            if !saved {
                saveState = .failed("Couldn't save who was speaking.")
            }
        }
    }

    private func mergeInto(_ candidate: SameMeeting) {
        guard !isMerging else { return }
        isMerging = true
        Task {
            defer { isMerging = false }
            do {
                try await meetingStore.merge(meeting.id, into: candidate.meetingID)
                sameMeetings = []
                onClose()
            } catch {
                Log.ui.error("merge failed: \(error.localizedDescription)")
                saveState = .failed(error.localizedDescription)
            }
        }
    }

    /// Asked first when there is something to lose. Rebuilding writes a recap
    /// from the transcript, which is exactly what a correction is not — and a
    /// name somebody fixed by hand coming back is worse than the misspelling,
    /// because the second time they stop trusting the fix.
    private func regenerateSummary() {
        guard editableRecap?.isEmpty != false else {
            isConfirmingRegenerate = true
            return
        }
        rebuildSummary()
    }

    private func rebuildSummary() {
        Task {
            guard let updated = await summaryRegeneration.run(for: current) else { return }
            seedEditors(from: updated)
            // A rebuilt meeting has a typed recap, and the toolbar hides Done
            // once it does — left on, the raw-markdown box would have no way out.
            isEditingSummary = false
        }
    }

    /// One correction, applied to both halves.
    ///
    /// `summary` is re-rendered rather than patched: it is the markdown view of
    /// `recap_json`, and the two are read by different screens — the notch, the
    /// chat's grounding prompt and the share viewer take the markdown, action
    /// items take the JSON. Editing one and leaving the other is how a meeting
    /// starts saying two different things about itself.
    private func correct(_ edited: MeetingRecap) {
        editableRecap = edited
        editableSummary = edited.toMarkdown()
        scheduleSave()
    }

    /// The editors hold what is on screen; this is the one place the meeting
    /// fills them. Kept together because the summary and the recap are one
    /// fact in two columns: seeding either without the other leaves the next
    /// autosave writing a stale half back.
    private func seedEditors(from meeting: Meeting) {
        editableTitle = meeting.title ?? ""
        editableSummary = meeting.summary
        editableRecap = meeting.recap
    }

    // MARK: - Autosave (debounced)

    private func scheduleSave() {
        // The meeting isn't on the server yet during generation — a
        // PATCH would 404. The detail view also disables every input
        // path that could trigger this, so reaching here while
        // generating means SwiftUI fired .onChange for an internal sync
        // we don't want persisted.
        guard !isFinalizing else { return }
        saveTask?.cancel()
        isDirty = true
        saveTask = Task {
            try? await Task.sleep(nanoseconds: 1_000_000_000)
            guard !Task.isCancelled else { return }
            saveState = .saving
            await performSave()
        }
    }

    private func performSave() async {
        guard !isFinalizing else { return }
        do {
            // From `edited`, which is built off `current` rather than the
            // captured `meeting`: the latter is a snapshot from when the view
            // opened, so saving after a generation (or a manual regeneration)
            // would write its stale nil recap back over the structured state.
            try await meetingStore.update(edited)
            saveState = .saved
            isDirty = false
        } catch {
            Log.ui.error("MeetingDetailView save failed: \(error.localizedDescription)")
            saveState = .failed(error.localizedDescription)
        }
    }

    private func flushPendingSaveOnDisappear() {
        saveTask?.cancel()
        guard isDirty, !isDeleting, !isFinalizing else { return }
        Task { await performSave() }
    }

    // MARK: - Delete

    private func deleteMeeting() {
        guard !isFinalizing else { return }
        isDeleting = true
        saveTask?.cancel()
        let snapshot = meeting
        Task {
            do {
                try await meetingStore.softDelete(snapshot)
                await MainActor.run { onClose() }
            } catch {
                Log.ui.error("MeetingDetailView delete failed: \(error.localizedDescription)")
                await MainActor.run {
                    isDeleting = false
                    saveState = .failed(error.localizedDescription)
                }
            }
        }
    }

    private func recordSummaryViewedIfRendered() {
        guard selectedTab == .summary,
              !isGenerating,
              !isFinalizing,
              !current.lacksRecap
        else { return }
        analytics.recordMeetingInteraction(
            .summaryViewed,
            contentType: .summary,
            meeting: current,
            outcome: .viewed,
            oncePerSession: "summary:\(meeting.id.uuidString)"
        )
    }
}
