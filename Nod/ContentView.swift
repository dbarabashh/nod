import SwiftUI
import AppKit
import Supabase

/// Behind-window blur for the floating panel's surfaces. SwiftUI's
/// `.ultraThinMaterial` uses `withinWindow` blending by default, which
/// renders as solid black on a `.nonactivatingPanel` that has no own
/// content for it to sample. `.behindWindow` samples the desktop / app
/// underneath the panel, which is what users actually see through it.
private struct PanelMaterial: NSViewRepresentable {
    var material: NSVisualEffectView.Material = .hudWindow

    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = material
        view.blendingMode = .behindWindow
        view.state = .active
        return view
    }

    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {
        nsView.material = material
    }
}

// MARK: - State

/// Compact vs wide panel footprint. Shared by `ContentView` (layout) and
/// `AppDelegate` (initial NSPanel size) so the two can't drift out of sync.
enum PanelWidth {
    static let compact: CGFloat = 320
    static let wide: CGFloat = 640
}

private enum MeetingState: Equatable {
    case idle
    case recording
    case paused

    var statusLabel: String {
        switch self {
        case .idle: return "READY"
        case .recording: return "REC"
        case .paused: return "PAUSED"
        }
    }

    /// Tint for the status label. Paused is the only state that diverges —
    /// the warning (amber) slot so "stopped, not recording" reads at a glance,
    /// matching the menu-bar paused dot. Recording/idle use the muted default.
    var statusTint: Color {
        self == .paused ? Theme.Palette.warning : .white.opacity(0.82)
    }
}

private enum AIResponse: Equatable {
    case none
    case generating(kind: String)
    case ready(kind: String, text: String)
}

// MARK: - Root

struct ContentView: View {
    @EnvironmentObject private var audioCapture: AudioCaptureService
    @EnvironmentObject private var llm: OpenRouterClient
    @EnvironmentObject private var store: TranscriptStore
    @EnvironmentObject private var language: LanguagePreference
    @EnvironmentObject private var consent: ConsentPreference
    @EnvironmentObject private var meetingStore: MeetingStore
    @EnvironmentObject private var auth: AuthService
    @EnvironmentObject private var profileStore: ProfileStore
    @EnvironmentObject private var entityStore: EntityStore
    @EnvironmentObject private var knowledgeStore: KnowledgeStore

    /// Always-on personal context prepended to every LLM system prompt so
    /// recaps and live cards read as if Nod already knows the user. "" when
    /// the profile is empty.
    private var profileContext: String { profileStore.promptContext }
    @ObservedObject private var hotkey = HotkeyManager.shared

    /// Reports the panel's desired width as the layout switches between the
    /// compact single-column state and the wide two-column state. The
    /// AppDelegate resizes the NSPanel so its clickable footprint (and the
    /// transparent dead-zone over apps behind it) shrinks when only the
    /// command column is showing. Optional so the SwiftUI #Preview still
    /// builds with a bare `ContentView()`.
    var onPreferredWidthChange: ((CGFloat) -> Void)? = nil

    @State private var meeting: MeetingState = .idle
    /// What the next recording will be. Chosen while idle; fixed for the
    /// duration of a recording so the recap framing + audio streams stay
    /// consistent from start to stop.
    @State private var selectedKind: SessionKind = .meeting
    @State private var response: AIResponse = .none
    @State private var elapsed: Int = 0
    @State private var micMuted: Bool = false
    /// When meeting is active, the left column shows the full controls by
    /// default. User can tap the chevron in StatusHeader to collapse to the
    /// tiny REC capsule, then tap that to re-expand.
    @State private var expanded: Bool = true
    /// True while the recording-consent modal is on screen; gates startMeeting()
    /// before audio capture begins. See issue #4.
    @State private var showConsentDisclaimer: Bool = false

    // MARK: - Meeting persistence (issue #14)

    /// Wall-clock start of the current recording. Captured in beginRecording
    /// so we can stamp `started_at` accurately when we persist on summary.
    @State private var recordingStartedAt: Date? = nil
    /// In-memory queue of meetings whose insert failed — retried by the
    /// toast button. v1 has no on-disk outbox; if the panel is torn down
    /// (sign-out) before the queue drains, the meetings are lost.
    @State private var pendingMeetingSaves: [Meeting] = []
    @State private var saveErrorToast: String? = nil

    /// The panel widens to two columns only when there's something to show
    /// on the right — a ready response, the consent modal, or the save-error
    /// toast (both centred in the full width). Recording with no open
    /// response stays compact.
    private var isWide: Bool {
        if showConsentDisclaimer { return true }
        if saveErrorToast != nil, !pendingMeetingSaves.isEmpty { return true }
        if case .ready = response { return true }
        return false
    }

    private var contentWidth: CGFloat { isWide ? PanelWidth.wide : PanelWidth.compact }

    var body: some View {
        ZStack {
            HStack(alignment: .top, spacing: 12) {
                leftColumn
                    .frame(width: 288, alignment: .topLeading)

                // Present only in the wide state, so the compact layout is
                // just the 288-wide command column and never overflows the
                // 320 window. The window snaps to its new width (see
                // AppDelegate) so content width and window width stay
                // consistent — no frame where the content is wider than the
                // window (which NSHostingController renders as a slide/clip).
                if isWide {
                    responseColumn
                        .frame(width: 308, alignment: .topLeading)
                }
            }
            .padding(16)
            // Fill the window and anchor leading so content lines up at the
            // left edge regardless of the window's current width.
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background(Color.clear)
            // While the consent modal is up, the card sits on top with no
            // backdrop — disable the columns underneath so a click in the
            // gap around the card can't accidentally hit a control.
            .allowsHitTesting(!showConsentDisclaimer)

            if let saveErrorToast, !pendingMeetingSaves.isEmpty {
                VStack {
                    Spacer()
                    SaveErrorToast(
                        message: saveErrorToast,
                        canRetry: true,
                        onRetry: retryPendingSaves,
                        onDismiss: dismissSaveError
                    )
                    .padding(.bottom, 18)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
                .allowsHitTesting(true)
                .zIndex(2)
            }

            if showConsentDisclaimer {
                ConsentDisclaimerView(
                    strings: .english,
                    onCancel: {
                        withAnimation(.easeOut(duration: 0.15)) {
                            showConsentDisclaimer = false
                        }
                    },
                    onAcknowledge: { dontShowAgain in
                        // Always log the legal acknowledgement; "Don't show
                        // again" only controls the local UX gate.
                        consent.acknowledge(persistGate: dontShowAgain)
                        withAnimation(.easeOut(duration: 0.15)) {
                            showConsentDisclaimer = false
                        }
                        beginRecording()
                    }
                )
                .zIndex(1)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .onAppear { onPreferredWidthChange?(contentWidth) }
        .onChange(of: isWide) { _ in onPreferredWidthChange?(contentWidth) }
        .task { await runSecondsTimer() }
        .onReceive(NotificationCenter.default.publisher(for: .nodSuggestHotkey)) { _ in
            // Global hotkey fired. Only act if a meeting is recording and we
            // aren't already generating a Suggest reply (debounce duplicate
            // fast presses).
            guard meeting == .recording, !isGenerating(for: "Suggest reply") else { return }
            generate(kind: "Suggest reply")
        }
    }

    /// Default state during a meeting is collapsed: shows only the REC capsule.
    /// Idle (pre-meeting) state always shows the full pre-meeting card layout.
    @ViewBuilder
    private var leftColumn: some View {
        if meeting != .idle && !expanded {
            CollapsedCapsule(
                meeting: meeting,
                elapsed: elapsedString,
                language: language.current,
                onExpand: {
                    withAnimation(.easeOut(duration: 0.18)) { expanded = true }
                },
                onRecordToggle: toggleRecording,
                onEnd: endMeeting
            )
        } else {
            mainColumn
        }
    }

    private var mainColumn: some View {
        VStack(alignment: .leading, spacing: 12) {
            StatusHeader(
                meeting: meeting,
                elapsed: elapsedString,
                language: language.current,
                level: audioCapture.inputLevel,
                onLanguageSelect: { language.current = $0 },
                onCollapse: meeting != .idle ? {
                    withAnimation(.easeOut(duration: 0.18)) { expanded = false }
                } : nil
            )

            if selectedKind.capturesMic {
                InputDevicePickerRow(audioCapture: audioCapture)
            }

            switch meeting {
            case .idle:
                SessionKindPicker(selection: $selectedKind)
                StartMeetingButton(
                    title: "Start \(selectedKind.title.lowercased())",
                    icon: selectedKind.icon,
                    action: startMeeting
                )

            case .recording, .paused:
                // One primary action (Catch me up — absorbs the old "Recap
                // so far"; they answered the same "summarise what happened"
                // need). The rest are a quieter secondary tier with glyphs
                // that name the action instead of decorative colour dots.
                HeroButton(
                    isGenerating: isGenerating(for: "hero"),
                    enabled: meeting == .recording,
                    action: { generate(kind: "hero") }
                )

                // Reply coaching only makes sense for a two-party meeting —
                // a solo memo or a podcast has no incoming turn to answer.
                if selectedKind.supportsReplyCoaching {
                    SuggestionPill(
                        label: "Suggest reply",
                        icon: "arrowshape.turn.up.left.fill",
                        isGenerating: isGenerating(for: "Suggest reply"),
                        enabled: meeting == .recording,
                        hotkeyHint: hotkey.combo(for: .suggestReply).displayString,
                        action: { generate(kind: "Suggest reply") }
                    )
                }
                SuggestionPill(
                    label: "Key points",
                    icon: "list.bullet",
                    isGenerating: isGenerating(for: "Key points"),
                    enabled: meeting == .recording,
                    action: { generate(kind: "Key points") }
                )
                if selectedKind.supportsReplyCoaching {
                    SuggestionPill(
                        label: "Suggest follow-up questions",
                        icon: "questionmark.bubble.fill",
                        isGenerating: isGenerating(for: "Suggest follow-up questions"),
                        enabled: meeting == .recording,
                        action: { generate(kind: "Suggest follow-up questions") }
                    )
                }
            }

            if meeting != .idle {
                StatusRow(
                    meeting: meeting,
                    micMuted: micMuted,
                    showMic: selectedKind.capturesMic,
                    onRecordToggle: toggleRecording,
                    onMicToggle: toggleMic,
                    onEnd: endMeeting
                )
                .padding(.top, 4)
            }

            Spacer(minLength: 0)
        }
    }

    @ViewBuilder
    private var responseColumn: some View {
        VStack(alignment: .leading, spacing: 12) {
            if case let .ready(kind, text) = response {
                ResponseCard(
                    kind: kind,
                    text: text,
                    onCopy: { latest in copy(latest) },
                    onDismiss: { response = .none },
                    onAIEdit: nil
                )
                // Fade in place — the panel is already widening rightward to
                // make room, so a horizontal slide read as the card "flying in
                // from the left" across the command column.
                .transition(.opacity)
            }
            Spacer(minLength: 0)
        }
        .animation(.easeOut(duration: 0.18), value: response)
    }

    // MARK: - Timers

    private func runSecondsTimer() async {
        while !Task.isCancelled {
            try? await Task.sleep(nanoseconds: 1_000_000_000)
            if meeting == .recording { elapsed += 1 }
        }
    }

    // MARK: - Derived

    private var elapsedString: String {
        String(format: "%02d:%02d", elapsed / 60, elapsed % 60)
    }

    private func isGenerating(for kind: String) -> Bool {
        if case let .generating(k) = response, k == kind { return true }
        return false
    }

    // MARK: - Actions

    private func startMeeting() {
        // Consent gate: show the disclaimer modal before any audio capture
        // on the user's first meeting. See issue #4.
        if !consent.isAccepted {
            withAnimation(.easeOut(duration: 0.15)) {
                showConsentDisclaimer = true
            }
            return
        }
        beginRecording()
    }

    private func beginRecording() {
        Log.ui.info("Start Meeting")
        meeting = .recording
        elapsed = 0
        response = .none
        expanded = true
        // Stamp the wall-clock so the persisted row carries an accurate
        // `started_at` instead of using the summary-ready instant.
        recordingStartedAt = Date()
        // Don't clear pendingMeetingSaves here — a prior failed save would
        // be silently lost if the user starts a new meeting before
        // retrying. The toast stays visible (its content reflects whatever
        // unsaved meetings are still queued); a successful retry empties
        // the queue.
        Task {
            await store.start()
            await audioCapture.start(
                captureMic: selectedKind.capturesMic,
                captureSystem: selectedKind.capturesSystem
            )
        }
    }

    private func endMeeting() {
        let context = store.fullContext
        Log.ui.info("End Meeting — entries=\(store.entries.count) context.len=\(context.count)")
        store.stop()
        Task { await audioCapture.stop() }

        if context.isEmpty {
            cleanupToIdle()
            return
        }

        // Snapshot the recording bookends BEFORE the async work — endedAt
        // marks the user's stop, not the summary-ready instant. Snapshot
        // the transcript entries too so the post-meeting save persists
        // them to `meeting_transcripts` (the Transcript tab in
        // MeetingDetailView reads them back).
        let startedAt = recordingStartedAt ?? Date()
        let endedAt = Date()
        let langCode = language.current.whisperCode
        let transcriptEntries = store.entries

        guard let userID = auth.currentSupabaseSession?.user.id else {
            Log.ui.error("End Meeting skipped — no session")
            cleanupToIdle()
            return
        }

        // Build the draft up front so MeetingDetailView opens on a real
        // row with the timestamps + language populated and only the
        // summary / title visibly loading. The same id flows through the
        // server insert later — id is client-generated for idempotency.
        let draft = Meeting.newCompleted(
            userID: userID,
            startedAt: startedAt,
            endedAt: endedAt,
            summary: "",
            language: langCode,
            kind: selectedKind,
            title: nil
        )
        meetingStore.beginGenerating(draft)

        NotificationCenter.default.post(
            name: .nodOpenMeetingDetail,
            object: nil,
            userInfo: [Notification.nodMeetingIDKey: draft.id]
        )

        // Panel returns to ready BEFORE the LLM call so a "Generating
        // summary…" placeholder doesn't double up — once in the small
        // panel card and once in the detail view. The user only sees
        // the detail-view loading state.
        cleanupToIdle()

        let draftID = draft.id
        Task {
            let (system, user) = PromptLibrary.build(kind: .summary, transcript: context, language: language.current, personalContext: profileContext, sessionKind: draft.kind)
            do {
                let recap = try await llm.completeJSON(system: system, user: user, as: MeetingRecap.self)
                let text = recap.toMarkdown()
                // Title is best-effort — failure here doesn't block
                // persistence; Meeting.displayTitle falls back to a
                // date label.
                let title = await generateMeetingTitle(from: text)
                let updated = draft.updating(title: title, summary: text, recap: recap)
                await MainActor.run {
                    meetingStore.applyGenerated(updated)
                }
                await persistMeeting(
                    meeting: updated,
                    transcriptEntries: transcriptEntries
                )
                // Enrichment — extract the people/projects/topics this
                // session is about so it can surface as "Related" elsewhere.
                // Best-effort, never blocks or fails the save.
                await extractEntities(
                    meetingID: updated.id,
                    userID: userID,
                    transcript: context,
                    summary: text
                )
                // Index the transcript for cross-session search (step 5).
                // Best-effort; runs after the meeting is already saved.
                await knowledgeStore.index(
                    meetingID: updated.id,
                    transcript: context
                )
            } catch {
                Log.ui.error("Meeting summary generation failed: \(error.localizedDescription)")
                await MainActor.run {
                    meetingStore.markGenerationFailed(
                        id: draftID,
                        errorMessage: "⚠️ \(error.localizedDescription)"
                    )
                }
            }
        }
    }

    private func cleanupToIdle() {
        meeting = .idle
        response = .none
        elapsed = 0
        micMuted = false
        store.clear()
    }

    private func toggleRecording() {
        switch meeting {
        case .idle:
            break
        case .recording:
            print("→ Pause")
            meeting = .paused
            audioCapture.pause()
        case .paused:
            print("→ Resume")
            meeting = .recording
            Task { await audioCapture.resume() }
        }
    }

    private func toggleMic() {
        micMuted.toggle()
        audioCapture.setMicMuted(micMuted)
        Log.ui.info(micMuted ? "mic muted" : "mic unmuted")
    }

    private func generate(kind: String) {
        Log.ui.info("user tapped '\(kind)' — context.len=\(store.fullContext.count) entries=\(store.entries.count)")
        response = .generating(kind: kind)
        let requestedKind = kind
        guard let promptKind = PromptKind(rawLabel: kind) else {
            response = .ready(kind: requestedKind, text: "⚠️ Unknown action: \(kind)")
            return
        }
        Task {
            // Suggest reply is real-time — force the latest chunk into the
            // transcript before reading context. Other pills tolerate the 5s
            // staleness.
            if promptKind == .suggestReply {
                await store.flushPending()
            }
            let context = store.recentContext(maxEntries: promptKind.contextWindow ?? .max)
            if context.isEmpty {
                Log.ui.info("⚠️ context is EMPTY — LLM will get only the system prompt")
            }
            let (system, user) = PromptLibrary.build(kind: promptKind, transcript: context, language: language.current, personalContext: profileContext)
            do {
                // Every pill's prompt emits a structured JSON object; decode the
                // matching type and render it to markdown the card already knows
                // how to show (`renderRecapMarkdown`).
                let text: String
                switch promptKind {
                case .hero:
                    text = try await llm.completeJSON(system: system, user: user, as: CatchUp.self).toMarkdown()
                case .smartReply:
                    text = try await llm.completeJSON(system: system, user: user, as: KeyPoints.self).toMarkdown()
                case .followUp:
                    text = try await llm.completeJSON(system: system, user: user, as: FollowUpQuestions.self).toMarkdown()
                case .summary:
                    text = try await llm.completeJSON(system: system, user: user, as: MeetingRecap.self).toMarkdown()
                case .suggestReply:
                    text = try await llm.completeJSON(system: system, user: user, as: SuggestedReply.self).toMarkdown()
                }
                if case let .generating(k) = response, k == requestedKind {
                    response = .ready(kind: requestedKind, text: text)
                    print("→ \(requestedKind) — ready")
                }
            } catch {
                if case let .generating(k) = response, k == requestedKind {
                    response = .ready(kind: requestedKind, text: "⚠️ \(error.localizedDescription)")
                    print("→ \(requestedKind) — failed: \(error.localizedDescription)")
                }
            }
        }
    }

    private func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        print("→ Copied to clipboard")
    }

    // MARK: - Meeting persistence (issue #14)

    /// Fires the Supabase insert for a finalised meeting and best-effort
    /// follows with a transcript bulk-insert. On insert failure the row
    /// is cached in `pendingMeetingSaves` so the retry toast can re-fire
    /// it with the SAME id (idempotency — server allows the duplicate id
    /// because the client always pre-generates the UUID, never relying
    /// on `default gen_random_uuid()`).
    private func persistMeeting(
        meeting: Meeting,
        transcriptEntries: [TranscriptEntry]
    ) async {
        await attemptSave(meeting)
        // If attemptSave failed it queues `meeting` on pendingMeetingSaves —
        // inserting transcripts now would FK-fail (no parent row on the
        // server) and the records would be discarded by the catch below.
        // The retry queue handles the meeting row, but transcripts aren't
        // requeued; rather than silently losing them with a FK-violation
        // error in the log, skip the insert until the meeting actually
        // lands. Net behaviour: transcripts are absent when the very
        // first save fails; the summary (the more valuable artifact) is
        // preserved by the existing retry path.
        if pendingMeetingSaves.contains(where: { $0.id == meeting.id }) {
            Log.ui.info("insertTranscript skipped — meeting save still pending")
            return
        }
        // Transcript best-effort: the summary row is already saved, so a
        // transcript failure shouldn't surface a retry toast — log and
        // move on. The detail view degrades gracefully when transcripts
        // are missing (shows "No transcript saved for this meeting.").
        guard !transcriptEntries.isEmpty else { return }
        let records = transcriptEntries.enumerated().map { idx, entry in
            TranscriptRecord(
                id: entry.id,
                meetingID: meeting.id,
                userID: meeting.userID,
                createdAt: nil,
                source: entry.source.rawValue,
                text: entry.text,
                ts: entry.timestamp,
                idx: idx
            )
        }
        do {
            try await meetingStore.insertTranscript(records)
        } catch {
            Log.ui.error("MeetingStore.insertTranscript failed (non-fatal) — \(error.localizedDescription)")
        }
    }

    /// Best-effort entity extraction — links the saved session to the
    /// people / projects / topics it mentions so "Related sessions" can find
    /// it. Runs after persistence; a failure here never affects the meeting.
    private func extractEntities(
        meetingID: UUID,
        userID: UUID,
        transcript: String,
        summary: String
    ) async {
        guard !transcript.isEmpty else { return }
        let (system, user) = PromptLibrary.buildEntityExtraction(transcript: transcript, summary: summary)
        do {
            let extracted = try await llm.completeJSON(system: system, user: user, as: ExtractedEntities.self)
            guard !extracted.isEmpty else { return }
            try await entityStore.saveExtraction(extracted, meetingID: meetingID, userID: userID)
        } catch {
            Log.ui.error("entity extraction failed (non-fatal): \(error.localizedDescription)")
        }
    }

    /// Best-effort LLM call to produce a short event-style title. Returns
    /// nil on failure (Meeting.displayTitle falls back to a date label).
    private func generateMeetingTitle(from summary: String) async -> String? {
        let (system, user) = PromptLibrary.buildTitle(
            summary: summary,
            language: language.current
        )
        do {
            let raw = try await llm.complete(system: system, user: user)
            return Self.sanitizeTitle(raw)
        } catch {
            Log.ui.error("title generation failed: \(error.localizedDescription)")
            return nil
        }
    }

    /// Models occasionally wrap titles in **bold**, prefix them with
    /// "Title: ", or echo quotes around them despite the prompt's
    /// instructions. Strip the common artefacts before storing.
    private static func sanitizeTitle(_ raw: String) -> String? {
        // 1. Whitespace + first-line only — models sometimes follow with a
        //    blank line + explanation.
        var line = raw
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .components(separatedBy: .newlines)
            .first?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            ?? ""

        // 2. Surrounding quotes / backticks.
        line = line.trimmingCharacters(in: CharacterSet(charactersIn: "\"'`"))

        // 3. Surrounding `**bold**` markers — the LLM sometimes emits the
        //    title in bold despite the no-markdown rule.
        if line.hasPrefix("**") && line.hasSuffix("**") && line.count > 4 {
            line.removeFirst(2)
            line.removeLast(2)
            line = line.trimmingCharacters(in: .whitespacesAndNewlines)
        }

        // 4. Leading "Title:" / "Заголовок:" / "Тема:" / "Назва:" prefixes
        //    (case-insensitive).
        for prefix in ["title:", "заголовок:", "тема:", "назва:"] {
            if line.lowercased().hasPrefix(prefix) {
                line = String(line.dropFirst(prefix.count))
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                break
            }
        }

        // 5. Trailing punctuation that doesn't belong in a title.
        while let last = line.last, ".!?;,".contains(last) {
            line.removeLast()
        }
        line = line.trimmingCharacters(in: .whitespacesAndNewlines)

        // Cap at 120 chars — enough headroom for Ukrainian/Russian/Polish
        // 7-word titles whose roots are longer than English equivalents.
        guard !line.isEmpty, line.count <= 120 else {
            Log.ui.info("title rejected (empty or too long): \(line.prefix(40))…")
            return nil
        }
        return line
    }

    private func attemptSave(_ meeting: Meeting) async {
        do {
            try await meetingStore.insert(meeting)
            pendingMeetingSaves.removeAll { $0.id == meeting.id }
            if pendingMeetingSaves.isEmpty {
                saveErrorToast = nil
            }
        } catch {
            Log.ui.error("MeetingStore.insert failed — \(error.localizedDescription)")
            // Queue the failed save so the retry toast can re-fire it.
            // The panel is always on screen (idle or recording) so the
            // toast is visible regardless of state — the previous
            // `meeting != .idle` gate silenced this branch once we
            // started running persistence after returning the panel to
            // idle for the open-detail handoff.
            if !pendingMeetingSaves.contains(where: { $0.id == meeting.id }) {
                pendingMeetingSaves.append(meeting)
            }
            saveErrorToast = "Couldn't save meeting — \(error.localizedDescription)"
        }
    }

    fileprivate func retryPendingSaves() {
        let queued = pendingMeetingSaves
        Task {
            for meeting in queued {
                await attemptSave(meeting)
            }
        }
    }

    fileprivate func dismissSaveError() {
        saveErrorToast = nil
        // Toast hidden; the queue itself stays so a future save error will
        // resurface the latest message. The toast re-appears the moment
        // `saveErrorToast` is set again by a fresh failure.
    }
}

// MARK: - Input Device Picker

private struct InputDevicePickerRow: View {
    @ObservedObject var audioCapture: AudioCaptureService
    @State private var devices: [AudioInputDevice] = []

    var body: some View {
        Menu {
            Button(action: { audioCapture.preferredInputUID = nil; refresh() }) {
                Label("System Default", systemImage: audioCapture.preferredInputUID == nil ? "checkmark" : "")
            }
            Divider()
            ForEach(devices) { device in
                Button(action: { audioCapture.preferredInputUID = device.uid; refresh() }) {
                    HStack {
                        Text(device.name + (device.isDefault ? "  (default)" : ""))
                        Spacer()
                        if device.uid == audioCapture.preferredInputUID {
                            Image(systemName: "checkmark")
                        }
                    }
                }
            }
            Divider()
            Button("Refresh", action: refresh)
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "mic.fill")
                    .font(.system(size: 10))
                    .foregroundColor(.white.opacity(0.55))
                Text(currentLabel)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(.white.opacity(0.75))
                    .lineLimit(1)
                Image(systemName: "chevron.down")
                    .font(.system(size: 8, weight: .semibold))
                    .foregroundColor(.white.opacity(0.55))
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(
                Capsule(style: .continuous)
                    .fill(Color.white.opacity(0.06))
                    .overlay(Capsule().stroke(Color.white.opacity(0.10), lineWidth: 0.5))
            )
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .onAppear(perform: refresh)
    }

    private var currentLabel: String {
        if let uid = audioCapture.preferredInputUID,
           let dev = devices.first(where: { $0.uid == uid }) {
            return dev.name
        }
        if let def = devices.first(where: { $0.isDefault }) {
            return "\(def.name) (default)"
        }
        return "Choose input…"
    }

    private func refresh() {
        devices = AudioDeviceCatalog.inputDevices()
    }
}

// MARK: - Status Header

private struct StatusHeader: View {
    let meeting: MeetingState
    let elapsed: String
    let language: AppLanguage
    /// Live mic peak (0…1) — drives the recording level meter so the user
    /// has continuous proof audio is being heard, not just a pulsing dot.
    var level: Float = 0
    let onLanguageSelect: (AppLanguage) -> Void
    var onCollapse: (() -> Void)? = nil
    @State private var pulsing = false

    var body: some View {
        HStack(spacing: 8) {
            indicator
            // Only label active states (REC/PAUSED) — idle is the default,
            // and the Start button beneath is its own affordance. "READY"
            // is shouty and didn't carry information the user couldn't
            // infer from the rest of the panel.
            if meeting != .idle {
                Text(meeting.statusLabel)
                    .font(.system(size: 11, weight: .semibold))
                    .tracking(0.5)
                    .foregroundColor(meeting.statusTint)
                Text(elapsed)
                    .font(.system(size: 11, weight: .medium, design: .monospaced))
                    .foregroundColor(.white.opacity(0.50))
                if meeting == .recording {
                    LevelMeter(level: level)
                }
            }
            Spacer(minLength: 0)
            // Selectable mid-meeting: the pipeline resolves the language per
            // chunk at flush time (TranscriptStore wires `currentWhisperCode()`
            // into both transcribers), so a change takes effect on the next
            // ~5s chunk. Locking it forced a full End-meeting just to fix a
            // wrong pick, with no other recovery path.
            LanguagePicker(current: language, onSelect: onLanguageSelect)
            if let onCollapse {
                PanelIconButton(
                    systemName: "chevron.up",
                    help: "Collapse",
                    action: onCollapse
                )
            }
        }
        .padding(.leading, 12)
        .padding(.trailing, 6)
        .padding(.vertical, 7)
        // Matches the StartMeetingButton's treatment — frosted material +
        // subtle white-stroke border, no heavy black overlay — so the two
        // pills sit together as a coherent Raycast-style command surface.
        // The border goes amber while paused so the "stopped" state reads
        // even at a glance, without relying on the small label alone.
        .background(
            PanelMaterial()
                .clipShape(Capsule(style: .continuous))
                .overlay(Capsule().stroke(
                    meeting == .paused ? Theme.Palette.warning.opacity(0.55) : Color.white.opacity(0.12),
                    lineWidth: meeting == .paused ? 1 : 0.5
                ))
        )
        .onAppear { pulsing = true }
    }

    @ViewBuilder private var indicator: some View {
        switch meeting {
        case .idle:
            // Green = ready/available (Nod is alive, waiting to record).
            // Grey read as "off" which contradicted reality.
            Circle()
                .fill(Color(red: 0.40, green: 0.85, blue: 0.55))
                .frame(width: 8, height: 8)
                .shadow(color: Color(red: 0.40, green: 0.85, blue: 0.55).opacity(0.55), radius: 3, x: 0, y: 0)
        case .recording:
            Circle()
                .fill(Color(red: 0.95, green: 0.25, blue: 0.30))
                .frame(width: 8, height: 8)
                .opacity(pulsing ? 0.4 : 1.0)
                .animation(.easeInOut(duration: 1.0).repeatForever(autoreverses: true), value: pulsing)
        case .paused:
            Image(systemName: "pause.fill")
                .font(.system(size: 9, weight: .bold))
                .foregroundColor(Theme.Palette.warning)
                .frame(width: 8, height: 8)
        }
    }

}

/// Compact 4-bar input meter. Bars light progressively with the live mic
/// peak so a glance confirms audio is flowing. Purely a display — no state,
/// redrawn by its `level` input (~10×/sec from the audio tap).
private struct LevelMeter: View {
    let level: Float
    private static let thresholds: [Float] = [0.02, 0.06, 0.14, 0.30]

    var body: some View {
        HStack(spacing: 2) {
            ForEach(Self.thresholds, id: \.self) { threshold in
                Capsule()
                    .fill(Color.white.opacity(level >= threshold ? 0.85 : 0.18))
                    .frame(width: 2.5, height: 9)
            }
        }
        .animation(.easeOut(duration: 0.12), value: level)
        .help("Microphone level")
    }
}

/// Small circular icon button shared by the panel's chrome — the
/// collapse chevron in `StatusHeader` and the pause / end / expand
/// controls in `CollapsedCapsule`. Single source of truth so collapse
/// and expand stay visually identical.
private struct PanelIconButton: View {
    let systemName: String
    var tint: Color = .white.opacity(0.6)
    var fill: Color = Color.white.opacity(0.10)
    let help: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 10, weight: .bold))
                .foregroundColor(tint)
                .frame(width: 22, height: 22)
                .background(Circle().fill(fill))
        }
        .buttonStyle(.plain)
        .help(help)
    }
}

private struct CollapsedCapsule: View {
    let meeting: MeetingState
    let elapsed: String
    let language: AppLanguage
    let onExpand: () -> Void
    let onRecordToggle: () -> Void
    let onEnd: () -> Void
    @State private var pulsing = false

    var body: some View {
        HStack(spacing: 6) {
            indicator
            Text(meeting.statusLabel)
                .font(.system(size: 11, weight: .semibold))
                .foregroundColor(meeting.statusTint)
            Text(elapsed)
                .font(.system(size: 11, weight: .medium, design: .monospaced))
                .foregroundColor(.white.opacity(0.55))
            Text(language.chipLabel)
                .font(.system(size: 10, weight: .bold, design: .rounded))
                .tracking(0.5)
                .foregroundColor(.white.opacity(0.65))
                .padding(.horizontal, 5)
                .padding(.vertical, 1)
                .background(
                    Capsule(style: .continuous)
                        .fill(Color.white.opacity(0.10))
                )

            Spacer(minLength: 6)

            PanelIconButton(
                systemName: meeting == .paused ? "play.fill" : "pause.fill",
                tint: meeting == .paused
                    ? Color(red: 0.62, green: 0.90, blue: 0.72)
                    : .white.opacity(0.80),
                help: meeting == .paused ? "Resume" : "Pause",
                action: onRecordToggle
            )
            PanelIconButton(
                systemName: "stop.fill",
                tint: Color(red: 0.95, green: 0.45, blue: 0.50),
                fill: Color(red: 0.55, green: 0.18, blue: 0.22).opacity(0.40),
                help: "End meeting",
                action: onEnd
            )
            PanelIconButton(
                systemName: "chevron.down",
                help: "Expand",
                action: onExpand
            )
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        // Pin to the same width as the expanded column (suggestion pills /
        // StatusHeader) so collapsing and expanding doesn't resize the
        // top control.
        .frame(width: 246)
        .background(
            ZStack {
                PanelMaterial()
                Color.black.opacity(0.18)
            }
            .clipShape(Capsule(style: .continuous))
            .overlay(Capsule().stroke(Color.white.opacity(0.10), lineWidth: 0.5))
        )
        .shadow(color: Color.black.opacity(0.25), radius: 6, x: 0, y: 3)
        .onAppear { pulsing = true }
    }

    @ViewBuilder private var indicator: some View {
        switch meeting {
        case .recording:
            Circle()
                .fill(Color(red: 0.95, green: 0.25, blue: 0.30))
                .frame(width: 8, height: 8)
                .opacity(pulsing ? 0.4 : 1.0)
                .animation(.easeInOut(duration: 1.0).repeatForever(autoreverses: true), value: pulsing)
        case .paused:
            Image(systemName: "pause.fill")
                .font(.system(size: 9, weight: .bold))
                .foregroundColor(Theme.Palette.warning)
                .frame(width: 8, height: 8)
        case .idle:
            // Shouldn't render in idle — leftColumn guards this — but safe fallback.
            Circle().fill(Color.white.opacity(0.3)).frame(width: 8, height: 8)
        }
    }
}

private struct LanguagePicker: View {
    let current: AppLanguage
    let onSelect: (AppLanguage) -> Void

    var body: some View {
        // Custom-styled `Menu` wrapping a real `Picker` so the chip keeps
        // its visual treatment (2-letter chipLabel + chevron) but SwiftUI
        // owns selection semantics — VoiceOver announces the selected
        // language, and the menu plays nicely with the non-activating
        // floating panel where a hand-rolled menu sometimes ate the
        // first click waiting for key-window status.
        Menu {
            Picker("Language", selection: Binding(
                get: { current },
                set: { onSelect($0) }
            )) {
                ForEach(AppLanguage.allCases, id: \.self) { lang in
                    Text(lang.nativeName).tag(lang)
                }
            }
            .pickerStyle(.inline)
            .labelsHidden()
        } label: {
            HStack(spacing: 3) {
                Text(current.chipLabel)
                    .font(.system(size: 10, weight: .semibold, design: .monospaced))
                    .tracking(0.5)
                Image(systemName: "chevron.down")
                    .font(.system(size: 7, weight: .bold))
                    .opacity(0.65)
            }
            .foregroundColor(.white.opacity(0.78))
            // Bumped padding so the chip is closer to Apple HIG's 44pt hit
            // target — visually still compact thanks to the small font.
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .contentShape(Capsule())
            .background(
                Capsule(style: .continuous)
                    .fill(Color.white.opacity(0.06))
                    .overlay(Capsule().stroke(Color.white.opacity(0.12), lineWidth: 0.5))
            )
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Switch language — applies to everything transcribed and generated from here on")
    }
}

/// Raycast-style command pill. Frosted dark capsule, neutral mic glyph,
/// "Start meeting" label. The glyph is deliberately NOT a red record dot —
/// red is reserved for the active REC state, and a red dot on the *start*
/// affordance reads for a beat as "already recording".
/// No kbd-shortcut badge — `.keyboardShortcut` on a `.nonactivatingPanel`
/// doesn't fire because the panel rarely becomes key; showing a hint for a
/// non-functional shortcut is worse than no hint.
private struct StartMeetingButton: View {
    var title: String = "Start meeting"
    var icon: String = "mic.fill"
    let action: () -> Void
    @State private var hovered = false
    @State private var pressed = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: icon)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(.white.opacity(0.92))

                Text(title)
                    .font(.system(size: 13.5, weight: .medium))
                    .foregroundColor(.white.opacity(0.92))
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 9)
            .frame(maxWidth: .infinity, minHeight: 38)
            .background(
                ZStack {
                    PanelMaterial()
                    Color.white.opacity(hovered ? 0.06 : 0.02)
                }
                .clipShape(Capsule(style: .continuous))
                .overlay(
                    Capsule(style: .continuous)
                        .stroke(Color.white.opacity(0.12), lineWidth: 0.5)
                )
            )
            .scaleEffect(pressed ? 0.985 : 1.0)
            .animation(.easeOut(duration: 0.10), value: pressed)
            .animation(.easeOut(duration: 0.12), value: hovered)
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .onHover { hovered = $0 }
        .simultaneousGesture(
            DragGesture(minimumDistance: 0)
                .onChanged { _ in pressed = true }
                .onEnded { _ in pressed = false }
        )
    }
}

/// Three-way segmented control for what the next recording is. Icon-over-
/// caption segments so the labels fit the compact panel width. The selection
/// drives audio-stream choice, the recap framing, and which live cards show.
private struct SessionKindPicker: View {
    @Binding var selection: SessionKind

    var body: some View {
        HStack(spacing: 4) {
            ForEach(SessionKind.allCases) { kind in
                segment(kind)
            }
        }
        .padding(3)
        .background(
            RoundedRectangle(cornerRadius: 11, style: .continuous)
                .fill(Color.white.opacity(0.04))
                .overlay(
                    RoundedRectangle(cornerRadius: 11, style: .continuous)
                        .stroke(Color.white.opacity(0.08), lineWidth: 0.5)
                )
        )
    }

    private func segment(_ kind: SessionKind) -> some View {
        let isSelected = selection == kind
        return Button {
            withAnimation(.easeOut(duration: 0.14)) { selection = kind }
        } label: {
            VStack(spacing: 4) {
                Image(systemName: kind.icon)
                    .font(.system(size: 12, weight: .semibold))
                Text(kind.title)
                    .font(.system(size: 10, weight: .medium))
                    .lineLimit(1)
                    .minimumScaleFactor(0.85)
            }
            .foregroundColor(isSelected ? .white : .white.opacity(0.55))
            .frame(maxWidth: .infinity)
            .padding(.vertical, 7)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(isSelected ? Color.white.opacity(0.10) : .clear)
                    .overlay(
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .stroke(isSelected ? Color.white.opacity(0.14) : .clear, lineWidth: 0.5)
                    )
            )
            .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        }
        .buttonStyle(.plain)
        .help(helpText(kind))
    }

    private func helpText(_ kind: SessionKind) -> String {
        switch kind {
        case .meeting:   return "Record both sides of a call — your mic and the other participants."
        case .voiceNote: return "Capture your own voice only — think out loud, get it summarized."
        case .media:     return "Transcribe what's playing on your Mac — a video, podcast, or talk."
        }
    }
}

// MARK: - Transcript

private struct TranscriptBubble: View {
    let transcript: String
    let paused: Bool
    let onClose: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            RecordingIcon(paused: paused)

            Text(transcript)
                .font(.system(size: 14, weight: .regular))
                .foregroundColor(Color(red: 0.18, green: 0.22, blue: 0.36))
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)

            CloseButton(action: onClose)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(lightFrostedBubble(cornerRadius: 18))
        .shadow(color: Color.black.opacity(0.18), radius: 10, x: 0, y: 4)
    }
}

private struct RecordingIcon: View {
    let paused: Bool
    @State private var pulsing = false

    var body: some View {
        RoundedRectangle(cornerRadius: 6, style: .continuous)
            .fill(Color(red: 0.12, green: 0.13, blue: 0.16))
            .frame(width: 28, height: 28)
            .overlay(content)
            .onAppear { pulsing = true }
    }

    @ViewBuilder private var content: some View {
        if paused {
            Image(systemName: "pause.fill")
                .font(.system(size: 11, weight: .bold))
                .foregroundColor(.white.opacity(0.7))
        } else {
            Circle()
                .fill(Color(red: 0.95, green: 0.25, blue: 0.30))
                .frame(width: 8, height: 8)
                .opacity(pulsing ? 0.4 : 1.0)
                .animation(.easeInOut(duration: 1.0).repeatForever(autoreverses: true), value: pulsing)
        }
    }
}

private struct CloseButton: View {
    let action: () -> Void

    var body: some View {
        Button(action: {
            print("→ Close bubble")
            action()
        }) {
            ZStack {
                Circle().fill(Color.black.opacity(0.08))
                Image(systemName: "xmark")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundColor(Color.black.opacity(0.55))
            }
            .frame(width: 18, height: 18)
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Hero

private struct HeroButton: View {
    let isGenerating: Bool
    let enabled: Bool
    let action: () -> Void
    @State private var shimmering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                if isGenerating {
                    ProgressView()
                        .controlSize(.small)
                        .progressViewStyle(.circular)
                        .tint(Theme.Palette.ink)
                        .frame(width: 14, height: 14)
                } else {
                    Image(systemName: "sparkles")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundColor(DesignTokens.Palette.electricBlue)
                        .opacity(shimmering ? 0.65 : 1.0)
                        .animation(.easeInOut(duration: 1.4).repeatForever(autoreverses: true), value: shimmering)
                }

                Text(isGenerating ? "Recalling…" : "Catch me up")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(Theme.Palette.ink)

                Spacer(minLength: 0)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 9)
            // Match SuggestionPill width for a tidy stacked-pill column.
            .frame(width: 246, alignment: .leading)
            .background(
                ZStack {
                    PanelMaterial()
                    Capsule(style: .continuous)
                        .fill(Theme.Gradients.buttonBrand)
                        .opacity(0.20)
                }
                .clipShape(Capsule(style: .continuous))
                .overlay(
                    Capsule(style: .continuous)
                        .stroke(DesignTokens.Shadow.insetSubtle2, lineWidth: 0.6)
                )
            )
            .shadow(color: DesignTokens.Palette.magentaBurst.opacity(0.35), radius: 10, x: 0, y: 4)
            .opacity(enabled ? 1.0 : 0.55)
        }
        .buttonStyle(.plain)
        .disabled(!enabled || isGenerating)
        .onAppear { shimmering = true }
    }
}

// MARK: - Suggestion pill

private struct SuggestionPill: View {
    let label: String
    let icon: String
    let isGenerating: Bool
    let enabled: Bool
    var hotkeyHint: String? = nil
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                if isGenerating {
                    ProgressView()
                        .controlSize(.mini)
                        .progressViewStyle(.circular)
                        .tint(Theme.Palette.ink)
                        .frame(width: 12, height: 12)
                } else {
                    Image(systemName: icon)
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundColor(.white.opacity(0.55))
                        .frame(width: 12)
                }

                Text(label)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(.white.opacity(0.88))
                    .lineLimit(1)

                Spacer(minLength: 0)

                if let hotkeyHint {
                    Text(hotkeyHint)
                        .font(.system(size: 10.5, weight: .semibold, design: .monospaced))
                        .foregroundColor(Theme.Palette.ink.opacity(0.50))
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1)
                        .background(
                            Capsule(style: .continuous)
                                .fill(Color.white.opacity(0.10))
                                .overlay(Capsule().stroke(Color.white.opacity(0.15), lineWidth: 0.5))
                        )
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 7)
            // Width sized to the longest label ("Suggest follow-up questions").
            // Flatter, lighter treatment than the HeroButton — these are the
            // secondary tier, so no gradient / drop shadow, just a faint
            // translucent fill that reads as "also available".
            .frame(width: 246, alignment: .leading)
            .background(
                ZStack {
                    PanelMaterial()
                    Color.white.opacity(0.04)
                }
                .clipShape(Capsule(style: .continuous))
                .overlay(
                    Capsule(style: .continuous)
                        .stroke(Theme.Palette.border, lineWidth: 0.5)
                )
            )
            .opacity(enabled ? 1.0 : 0.55)
        }
        .buttonStyle(.plain)
        .disabled(!enabled || isGenerating)
    }
}

// MARK: - Response card

private struct ResponseCard: View {
    let kind: String
    let text: String
    let onCopy: (String) -> Void
    let onDismiss: () -> Void
    /// (currentText, instruction) → updated text. Wired in ContentView via
    /// PromptLibrary.buildSummaryEdit + llm.complete.
    var onAIEdit: ((String, String) async throws -> String)? = nil

    /// Working buffer the TextEditor binds to. Seeded from `text` and kept in
    /// sync if a fresh response arrives (e.g. switching from "Catch me up" to
    /// "Meeting recap" without dismissing the card).
    @State private var editableText: String = ""
    @State private var aiInstruction: String = ""
    @State private var isApplyingEdit: Bool = false
    @State private var editError: String? = nil
    @FocusState private var instructionFocused: Bool
    /// True when the editable recap is shown as rendered markdown; false
    /// when the user has tapped Edit to switch to the raw TextEditor.
    /// Defaults to true so the user sees `**Topics covered**` as bold
    /// instead of literal asterisks the moment the recap lands.
    @State private var isPreviewingRecap: Bool = true

    /// Edit affordances are only enabled for the end-of-meeting recap. Mid-call
    /// cards ("Catch me up", "Key points", …) are read-only — they're
    /// ephemeral and editing them adds noise without value. Caller signals
    /// "this card is persistent + editable" by passing `onAIEdit`.
    private var isEditable: Bool { onAIEdit != nil }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "sparkles")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundColor(Color(red: 0.62, green: 0.82, blue: 1.0))
                Text(kindLabel)
                    .font(.system(size: 11, weight: .bold))
                    .foregroundColor(.white.opacity(0.85))
                    .textCase(.uppercase)
                Spacer(minLength: 0)
                if isEditable {
                    Button(action: { isPreviewingRecap.toggle() }) {
                        Image(systemName: isPreviewingRecap ? "square.and.pencil" : "eye")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundColor(.white.opacity(0.65))
                            .frame(width: 22, height: 18)
                            .background(Capsule().fill(Color.white.opacity(0.08)))
                    }
                    .buttonStyle(.plain)
                    .help(isPreviewingRecap ? "Edit raw markdown" : "Preview formatted")
                    .disabled(isApplyingEdit)
                }
                Button(action: {
                    print("→ Dismiss response")
                    onDismiss()
                }) {
                    Image(systemName: "xmark")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundColor(.white.opacity(0.55))
                        .frame(width: 18, height: 18)
                        .background(Circle().fill(Color.white.opacity(0.08)))
                }
                .buttonStyle(.plain)
            }

            if isEditable {
                // Editable buffer with view / edit toggle. Default view
                // renders markdown so `**Topics covered**` is bold. Tap
                // the pencil icon up top to flip to raw TextEditor for
                // direct edits; "eye" icon flips back. The AI-edit input
                // below works in either mode and updates the same buffer.
                //
                // Editor is disabled while an AI edit is in flight so
                // user keystrokes can't race the async response —
                // without this the LLM's returned text would silently
                // overwrite anything they typed during the await.
                Group {
                    if isPreviewingRecap {
                        ScrollView(.vertical, showsIndicators: true) {
                            Text(renderRecapMarkdown(editableText))
                                .font(.system(size: 13, weight: .regular))
                                .foregroundColor(.white.opacity(0.92))
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .fixedSize(horizontal: false, vertical: true)
                                .padding(.horizontal, 8)
                                .padding(.vertical, 6)
                        }
                    } else {
                        TextEditor(text: $editableText)
                            .font(.system(size: 13, weight: .regular))
                            .foregroundColor(.white.opacity(0.92))
                            .scrollContentBackground(.hidden)
                    }
                }
                .background(Color.white.opacity(0.04))
                .overlay(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .stroke(Color.white.opacity(0.10), lineWidth: 0.5)
                )
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                .frame(minHeight: 180, maxHeight: 320)
                .disabled(isApplyingEdit && !isPreviewingRecap)
                .opacity(isApplyingEdit ? 0.6 : 1.0)

                if let editError {
                    Text(editError)
                        .font(.system(size: 11, weight: .regular))
                        .foregroundColor(Color(red: 0.95, green: 0.55, blue: 0.55))
                        .fixedSize(horizontal: false, vertical: true)
                }

                aiEditRow
            } else {
                // Mid-call responses ("Catch me up", "Key points", …) are
                // ephemeral — read-only rendered markdown. Wrapped in a
                // bounded ScrollView so long replies stay scrollable inside
                // the card instead of overflowing the floating panel.
                ScrollView(.vertical, showsIndicators: true) {
                    Text(renderRecapMarkdown(editableText))
                        .font(.system(size: 13, weight: .regular))
                        .foregroundColor(.white.opacity(0.92))
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .textSelection(.enabled)
                }
                .frame(maxHeight: 320)
            }

            HStack(spacing: 8) {
                Spacer(minLength: 0)
                MiniAction(label: "Copy", icon: "doc.on.doc") {
                    onCopy(editableText)
                }
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            ZStack {
                PanelMaterial()
                Color.black.opacity(0.18)
            }
            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .stroke(Color.white.opacity(0.14), lineWidth: 0.5)
            )
        )
        .shadow(color: Color.black.opacity(0.30), radius: 12, x: 0, y: 6)
        .onAppear {
            // Seed the editor with whatever the LLM just produced. Subsequent
            // user edits live in @State and aren't overwritten unless a brand
            // new response arrives.
            if editableText.isEmpty { editableText = text }
        }
        .onChange(of: text) { new in
            // A fresh LLM response landed (e.g. user re-asked) — sync the
            // editor buffer to the new source text. Leave `aiInstruction` and
            // `editError` alone: if the user was mid-typing an instruction
            // when an unrelated parent rebuild flowed a (possibly identical)
            // text through, wiping their input is silent data loss.
            // (macOS 13 onChange signature — single closure arg.)
            editableText = new
        }
    }

    /// Chat-style input row: type instruction, ⏎ or send button to apply.
    private var aiEditRow: some View {
        HStack(spacing: 6) {
            Image(systemName: "wand.and.stars")
                .font(.system(size: 11, weight: .semibold))
                .foregroundColor(.white.opacity(0.55))

            TextField("Ask AI to edit…", text: $aiInstruction, axis: .horizontal)
                .textFieldStyle(.plain)
                .font(.system(size: 12, weight: .regular))
                .foregroundColor(.white.opacity(0.92))
                .focused($instructionFocused)
                .disabled(isApplyingEdit)
                .onSubmit(applyAIEdit)

            Button(action: applyAIEdit) {
                if isApplyingEdit {
                    ProgressView()
                        .controlSize(.mini)
                        .progressViewStyle(.circular)
                        .tint(.white)
                        .frame(width: 14, height: 14)
                } else {
                    Image(systemName: "arrow.up.circle.fill")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundColor(canSubmitEdit ? Color(red: 0.62, green: 0.82, blue: 1.0) : .white.opacity(0.25))
                }
            }
            .buttonStyle(.plain)
            .disabled(!canSubmitEdit)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(
            Capsule(style: .continuous)
                .fill(Color.white.opacity(0.06))
                .overlay(Capsule().stroke(Color.white.opacity(0.10), lineWidth: 0.5))
        )
    }

    private var canSubmitEdit: Bool {
        !isApplyingEdit
            && !aiInstruction.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && onAIEdit != nil
    }

    private func applyAIEdit() {
        guard canSubmitEdit, let onAIEdit else { return }
        let snapshot = editableText
        let instruction = aiInstruction.trimmingCharacters(in: .whitespacesAndNewlines)
        isApplyingEdit = true
        editError = nil
        Task {
            do {
                let updated = try await onAIEdit(snapshot, instruction)
                await MainActor.run {
                    editableText = updated
                    aiInstruction = ""
                    isApplyingEdit = false
                }
            } catch {
                await MainActor.run {
                    editError = "Edit failed: \(error.localizedDescription)"
                    isApplyingEdit = false
                }
            }
        }
    }

    private var kindLabel: String {
        switch kind {
        case "hero": return "Catch me up"
        case "Meeting Summary": return "Meeting recap"
        default: return kind
        }
    }

}

private struct MiniAction: View {
    let label: String
    let icon: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 4) {
                Image(systemName: icon)
                    .font(.system(size: 10, weight: .semibold))
                Text(label)
                    .font(.system(size: 11, weight: .semibold))
            }
            .foregroundColor(.white.opacity(0.85))
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(
                Capsule(style: .continuous)
                    .fill(Color.white.opacity(0.1))
                    .overlay(
                        Capsule(style: .continuous)
                            .stroke(Color.white.opacity(0.15), lineWidth: 0.5)
                    )
            )
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Status Row

private struct StatusRow: View {
    let meeting: MeetingState
    let micMuted: Bool
    var showMic: Bool = true
    let onRecordToggle: () -> Void
    let onMicToggle: () -> Void
    let onEnd: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            StatusIcon(action: onRecordToggle) {
                Image(systemName: meeting == .paused ? "play.fill" : "pause.fill")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(meeting == .paused
                        ? Color(red: 0.62, green: 0.90, blue: 0.72)
                        : .white.opacity(0.85))
            }

            if showMic {
                StatusIcon(action: onMicToggle) {
                    Image(systemName: micMuted ? "mic.slash.fill" : "mic.fill")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundColor(micMuted
                            ? Color(red: 0.95, green: 0.55, blue: 0.55)
                            : .white.opacity(0.85))
                }
            }

            Spacer(minLength: 0)

            Button(action: onEnd) {
                HStack(spacing: 5) {
                    Image(systemName: "stop.fill")
                        .font(.system(size: 10, weight: .bold))
                    Text("End")
                        .font(.system(size: 12, weight: .semibold))
                }
                .foregroundColor(Color(red: 0.95, green: 0.45, blue: 0.50))
                .padding(.horizontal, 12)
                .padding(.vertical, 7)
                .background(
                    Capsule(style: .continuous)
                        .fill(Color(red: 0.55, green: 0.18, blue: 0.22).opacity(0.4))
                        .overlay(
                            Capsule(style: .continuous)
                                .stroke(Color(red: 0.95, green: 0.45, blue: 0.50).opacity(0.4), lineWidth: 0.5)
                        )
                )
            }
            .buttonStyle(.plain)
        }
    }
}

private struct StatusIcon<Content: View>: View {
    let action: () -> Void
    @ViewBuilder var content: Content

    var body: some View {
        Button(action: action) {
            ZStack {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(Color(red: 0.16, green: 0.17, blue: 0.22))
                content
            }
            .frame(width: 32, height: 32)
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .stroke(Color.white.opacity(0.08), lineWidth: 0.5)
            )
            .shadow(color: Color.black.opacity(0.25), radius: 4, x: 0, y: 2)
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Shared

private func lightFrostedBubble(cornerRadius: CGFloat) -> some View {
    RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        .fill(.ultraThinMaterial)
        .overlay(
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .fill(Color.white.opacity(0.55))
        )
        .overlay(
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .stroke(Color.white.opacity(0.4), lineWidth: 0.5)
        )
}

private struct SaveErrorToast: View {
    let message: String
    let canRetry: Bool
    let onRetry: () -> Void
    let onDismiss: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(Theme.Palette.warning)

            Text(message)
                .font(.system(size: 12, weight: .regular))
                .foregroundStyle(Theme.Palette.ink)
                .lineLimit(2)

            Spacer(minLength: 8)

            if canRetry {
                Button(action: onRetry) {
                    Text("Retry")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(Theme.Palette.ink)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 5)
                        .background(Capsule(style: .continuous).fill(Theme.Gradients.buttonBrand))
                }
                .buttonStyle(.plain)
            }

            Button(action: onDismiss) {
                Image(systemName: "xmark")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundColor(Theme.Palette.muted)
                    .frame(width: 18, height: 18)
                    .background(Circle().fill(Color.white.opacity(0.08)))
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .frame(maxWidth: 480)
        .background(
            ZStack {
                PanelMaterial()
                Theme.Palette.bgSoft.opacity(0.50)
            }
            .clipShape(Capsule(style: .continuous))
            .overlay(Capsule().stroke(Theme.Palette.borderStrong, lineWidth: 0.5))
        )
        .shadow(color: Color.black.opacity(0.35), radius: 14, x: 0, y: 6)
    }
}

#Preview {
    let llm = OpenRouterClient()
    let language = LanguagePreference()
    // Use a dedicated UserDefaults suite so previewing the Acknowledge flow
    // doesn't taint the developer's installed app's consent state.
    let previewDefaults = UserDefaults(suiteName: "nod.preview.consent") ?? .standard
    let supabase = SupabaseClient(
        supabaseURL: SupabaseConfig.url,
        supabaseKey: SupabaseConfig.anonKey,
        options: SupabaseClientOptions(
            auth: SupabaseClientOptions.AuthOptions(emitLocalSessionAsInitialSession: true)
        )
    )
    let auth = AuthService(client: supabase)
    return ContentView()
        .environmentObject(AudioCaptureService())
        .environmentObject(llm)
        .environmentObject(TranscriptStore(client: llm, language: language))
        .environmentObject(language)
        .environmentObject(ConsentPreference(defaults: previewDefaults))
        .environmentObject(MeetingStore(supabase: supabase))
        .environmentObject(auth)
        .background(Color.gray.opacity(0.3))
}
