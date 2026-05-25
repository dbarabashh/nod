import SwiftUI
import Supabase

// MARK: - State

private enum MeetingState: Equatable {
    case idle
    case recording
    case paused
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

    @State private var meeting: MeetingState = .idle
    @State private var response: AIResponse = .none
    @State private var elapsed: Int = 0
    @State private var micMuted: Bool = false
    @State private var isSummarizing: Bool = false
    /// When meeting is active, the left column collapses by default to just a
    /// tiny REC capsule. User taps to expand to the full controls.
    @State private var expanded: Bool = false
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

    var body: some View {
        ZStack {
            HStack(alignment: .top, spacing: 12) {
                leftColumn
                    .frame(width: 288, alignment: .topLeading)

                responseColumn
                    .frame(width: 308, alignment: .topLeading)
            }
            .padding(16)
            .frame(width: 640, height: 560, alignment: .topLeading)
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
                .frame(width: 640, height: 560, alignment: .bottom)
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
        .frame(width: 640, height: 560, alignment: .topLeading)
        .task { await runSecondsTimer() }
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
                onTap: {
                    withAnimation(.easeOut(duration: 0.18)) { expanded = true }
                }
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
                onLanguageSelect: { language.current = $0 },
                onCollapse: meeting != .idle ? {
                    withAnimation(.easeOut(duration: 0.18)) { expanded = false }
                } : nil
            )

            InputDevicePickerRow(audioCapture: audioCapture)

            switch meeting {
            case .idle:
                StartMeetingButton(action: startMeeting)

            case .recording, .paused:
                HeroButton(
                    isGenerating: isGenerating(for: "hero"),
                    enabled: meeting == .recording,
                    action: { generate(kind: "hero") }
                )

                SuggestionPill(
                    label: "Suggest reply",
                    dotColor: DesignTokens.Palette.sunsetOrange,
                    isGenerating: isGenerating(for: "Suggest reply"),
                    enabled: meeting == .recording,
                    action: { generate(kind: "Suggest reply") }
                )
                SuggestionPill(
                    label: "Key points",
                    dotColor: DesignTokens.Palette.skyBlue,
                    isGenerating: isGenerating(for: "Key points"),
                    enabled: meeting == .recording,
                    action: { generate(kind: "Key points") }
                )
                SuggestionPill(
                    label: "Suggest follow-up questions",
                    dotColor: DesignTokens.Palette.fuchsiaFlare,
                    isGenerating: isGenerating(for: "Suggest follow-up questions"),
                    enabled: meeting == .recording,
                    action: { generate(kind: "Suggest follow-up questions") }
                )
                SuggestionPill(
                    label: "Recap so far",
                    dotColor: DesignTokens.Palette.vividGreen,
                    isGenerating: isGenerating(for: "Recap so far"),
                    enabled: meeting == .recording,
                    action: { generate(kind: "Recap so far") }
                )
            }

            if meeting != .idle {
                StatusRow(
                    meeting: meeting,
                    micMuted: micMuted,
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
                    onDismiss: {
                        if isSummarizing {
                            cleanupToIdle()
                        } else {
                            response = .none
                        }
                    },
                    // Only the meeting-recap card gets the AI-edit input — the
                    // mid-call hero/key-points cards are short and ephemeral,
                    // editing them is overkill.
                    onAIEdit: kind == "Meeting Summary" ? aiEditSummary : nil
                )
                .transition(.opacity.combined(with: .move(edge: .leading)))
            } else if case let .generating(kind) = response, kind == "Meeting Summary" {
                ResponseCard(
                    kind: "Meeting Summary",
                    text: "Generating summary…",
                    onCopy: { _ in },
                    onDismiss: { cleanupToIdle() }
                )
                .transition(.opacity.combined(with: .move(edge: .leading)))
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
        expanded = false
        isSummarizing = false
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
            await audioCapture.start()
        }
    }

    private func endMeeting() {
        if isSummarizing {
            // User dismissing the summary screen → finalize and reset to idle.
            cleanupToIdle()
            return
        }

        let context = store.fullContext
        Log.ui.info("End Meeting — entries=\(store.entries.count) context.len=\(context.count)")
        store.stop()
        Task { await audioCapture.stop() }

        if context.isEmpty {
            cleanupToIdle()
            return
        }

        // Stay in .paused visually while the summary card renders.
        isSummarizing = true
        meeting = .paused
        response = .generating(kind: "Meeting Summary")
        // Snapshot the recording bookends BEFORE the async work — endedAt
        // marks the user's stop, not the summary-ready instant. We do NOT
        // snapshot the transcript for persistence — it lives only in
        // `store` for the summary LLM call and is then dropped.
        let startedAt = recordingStartedAt ?? Date()
        let endedAt = Date()
        let langCode = language.current.whisperCode

        Task {
            let (system, user) = PromptLibrary.build(kind: .summary, transcript: context, language: language.current)
            do {
                let text = try await llm.complete(system: system, user: user)
                await MainActor.run {
                    if case let .generating(k) = response, k == "Meeting Summary" {
                        response = .ready(kind: "Meeting Summary", text: text)
                    }
                }
                // Generate a calendar-event-style title for HistoryView so
                // rows read as the meeting's topic, not "Meeting on
                // 23 May 2026, 19:23". Best-effort: failure here doesn't
                // block persistence — Meeting.title is optional and
                // `displayTitle` falls back to a date label.
                let title = await generateMeetingTitle(from: text)
                // Persist the meeting now that we have a summary + title +
                // bookend timestamps. Transcript is intentionally NOT
                // persisted — see Meeting.swift for the rationale.
                await persistMeeting(
                    startedAt: startedAt,
                    endedAt: endedAt,
                    summary: text,
                    language: langCode,
                    title: title
                )
            } catch {
                await MainActor.run {
                    if case let .generating(k) = response, k == "Meeting Summary" {
                        response = .ready(kind: "Meeting Summary", text: "⚠️ \(error.localizedDescription)")
                    }
                }
            }
        }
    }

    private func cleanupToIdle() {
        isSummarizing = false
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
        print(micMuted ? "→ Mic muted" : "→ Mic unmuted")
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
            let context = store.fullContext
            if context.isEmpty {
                Log.ui.info("⚠️ context is EMPTY — LLM will get only the system prompt")
            }
            let (system, user) = PromptLibrary.build(kind: promptKind, transcript: context, language: language.current)
            do {
                let text = try await llm.complete(system: system, user: user)
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

    /// Called from ResponseCard's "Ask AI to edit" input when the user submits
    /// an instruction. Hands the current recap + instruction to the LLM and
    /// returns the rewritten text for the card to display.
    private func aiEditSummary(currentText: String, instruction: String) async throws -> String {
        Log.ui.info("AI summary edit instruction: \(instruction)")
        let (system, user) = PromptLibrary.buildSummaryEdit(
            currentSummary: currentText,
            instruction: instruction,
            language: language.current
        )
        return try await llm.complete(system: system, user: user)
    }

    // MARK: - Meeting persistence (issue #14)

    /// Builds the Meeting and fires the Supabase insert. On failure caches
    /// the row in @State so the retry toast can re-fire it with the SAME id
    /// (idempotency from the client side — server allows duplicate ids
    /// because of `default gen_random_uuid()` only when client omits id; we
    /// always send our pre-generated id).
    private func persistMeeting(
        startedAt: Date,
        endedAt: Date,
        summary: String,
        language: String,
        title: String?
    ) async {
        // Read the SDK's cached session directly — it's updated atomically
        // when sign-in lands and during refresh, while AuthService.$session
        // lags by a publisher microtask. Without this, persistMeeting can
        // race a fresh sign-in and silently drop a meeting that should
        // have saved fine.
        guard let userID = auth.currentSupabaseSession?.user.id else {
            Log.ui.error("MeetingStore.insert skipped — no session")
            return
        }
        let meeting = Meeting.newCompleted(
            userID: userID,
            startedAt: startedAt,
            endedAt: endedAt,
            summary: summary,
            language: language,
            title: title
        )
        await attemptSave(meeting)
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
            // Always queue the failed save so it survives until the user
            // explicitly retries (or the panel is torn down — v1 has no
            // on-disk outbox). Only the visible toast is gated on whether
            // the user is still looking at the post-meeting card —
            // surfacing a toast over the idle UI is confusing.
            if !pendingMeetingSaves.contains(where: { $0.id == meeting.id }) {
                pendingMeetingSaves.append(meeting)
            }
            if self.meeting != .idle || self.response != .none {
                saveErrorToast = "Couldn't save meeting — \(error.localizedDescription)"
            } else {
                Log.ui.info("save failed after dismiss — queued silently: \(meeting.id)")
            }
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
                Text(label)
                    .font(.system(size: 11, weight: .semibold))
                    .tracking(0.5)
                    .foregroundColor(.white.opacity(0.82))
                Text(elapsed)
                    .font(.system(size: 11, weight: .medium, design: .monospaced))
                    .foregroundColor(.white.opacity(0.50))
            }
            Spacer(minLength: 0)
            LanguagePicker(current: language, onSelect: onLanguageSelect, enabled: meeting == .idle)
            if let onCollapse {
                Button(action: onCollapse) {
                    Image(systemName: "chevron.up")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundColor(.white.opacity(0.6))
                        .frame(width: 16, height: 16)
                }
                .buttonStyle(.plain)
                .help("Collapse")
            }
        }
        .padding(.leading, 12)
        .padding(.trailing, 6)
        .padding(.vertical, 7)
        // Matches the StartMeetingButton's treatment — frosted material +
        // subtle white-stroke border, no heavy black overlay — so the two
        // pills sit together as a coherent Raycast-style command surface.
        .background(
            Capsule(style: .continuous)
                .fill(.ultraThinMaterial)
                .overlay(Capsule().stroke(Color.white.opacity(0.12), lineWidth: 0.5))
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
                .foregroundColor(.white.opacity(0.7))
                .frame(width: 8, height: 8)
        }
    }

    private var label: String {
        switch meeting {
        case .idle: return "READY"
        case .recording: return "REC"
        case .paused: return "PAUSED"
        }
    }
}

private struct CollapsedCapsule: View {
    let meeting: MeetingState
    let elapsed: String
    let language: AppLanguage
    let onTap: () -> Void
    @State private var pulsing = false

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: 8) {
                indicator
                Text(label)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(.white.opacity(0.85))
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
                Image(systemName: "chevron.down")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundColor(.white.opacity(0.6))
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            .background(
                Capsule(style: .continuous)
                    .fill(.ultraThinMaterial)
                    .overlay(Capsule().fill(Color.black.opacity(0.35)))
                    .overlay(Capsule().stroke(Color.white.opacity(0.10), lineWidth: 0.5))
            )
            .shadow(color: Color.black.opacity(0.25), radius: 6, x: 0, y: 3)
        }
        .buttonStyle(.plain)
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
                .foregroundColor(.white.opacity(0.7))
                .frame(width: 8, height: 8)
        case .idle:
            // Shouldn't render in idle — leftColumn guards this — but safe fallback.
            Circle().fill(Color.white.opacity(0.3)).frame(width: 8, height: 8)
        }
    }

    private var label: String {
        switch meeting {
        case .idle: return "READY"
        case .recording: return "REC"
        case .paused: return "PAUSED"
        }
    }
}

private struct LanguagePicker: View {
    let current: AppLanguage
    let onSelect: (AppLanguage) -> Void
    var enabled: Bool = true

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
            .foregroundColor(.white.opacity(enabled ? 0.78 : 0.40))
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
        .disabled(!enabled)
        .help(enabled
              ? "Switch language — affects transcription and AI responses"
              : "Language is locked during a meeting — end the meeting to change it")
    }
}

/// Raycast-style command pill. Frosted dark capsule, red record dot left,
/// "Start meeting" label. No kbd-shortcut badge — `.keyboardShortcut` on a
/// `.nonactivatingPanel` doesn't fire because the panel rarely becomes key;
/// showing a hint for a non-functional shortcut is worse than no hint.
/// Re-add a kbd badge once a real global hotkey is wired
/// (RegisterEventHotKey or NSEvent.addGlobalMonitorForEvents).
private struct StartMeetingButton: View {
    let action: () -> Void
    @State private var hovered = false
    @State private var pressed = false

    private static let red = Color(red: 0.95, green: 0.30, blue: 0.35)

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Circle()
                    .fill(Self.red)
                    .frame(width: 8, height: 8)
                    .shadow(color: Self.red.opacity(0.55), radius: 4, x: 0, y: 0)

                Text("Start meeting")
                    .font(.system(size: 13.5, weight: .medium))
                    .foregroundColor(.white.opacity(0.92))
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 9)
            .frame(maxWidth: .infinity, minHeight: 38)
            .background(
                Capsule(style: .continuous)
                    .fill(.ultraThinMaterial)
                    .overlay(
                        Capsule(style: .continuous)
                            .fill(Color.white.opacity(hovered ? 0.06 : 0.02))
                    )
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
                Capsule(style: .continuous)
                    .fill(.ultraThinMaterial)
                    .overlay(
                        Capsule(style: .continuous)
                            .fill(Theme.Gradients.buttonBrand)
                            .opacity(0.55)
                    )
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
    var trailingEmoji: String? = nil
    let dotColor: Color
    let isGenerating: Bool
    let enabled: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                if isGenerating {
                    ProgressView()
                        .controlSize(.mini)
                        .progressViewStyle(.circular)
                        .tint(Theme.Palette.ink)
                        .frame(width: 8, height: 8)
                } else {
                    Circle()
                        .fill(dotColor)
                        .frame(width: 8, height: 8)
                }

                HStack(spacing: 4) {
                    Text(label)
                        .font(.system(size: 12.5, weight: .semibold))
                        .foregroundColor(Theme.Palette.ink)
                        .lineLimit(1)
                    if let trailingEmoji {
                        Text(trailingEmoji)
                            .font(.system(size: 12))
                    }
                }

                Spacer(minLength: 0)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 7)
            // Width sized to the longest label ("Suggest follow-up questions")
            // at the new compact 12.5pt font — keeps all three pills uniform
            // without truncating the longest one.
            .frame(width: 246, alignment: .leading)
            .background(
                Capsule(style: .continuous)
                    .fill(.ultraThinMaterial)
                    .overlay(
                        Capsule(style: .continuous)
                            .fill(Theme.Palette.bgSoft.opacity(0.55))
                    )
                    .overlay(
                        Capsule(style: .continuous)
                            .stroke(Theme.Palette.border, lineWidth: 0.5)
                    )
            )
            .shadow(color: Color.black.opacity(0.18), radius: 6, x: 0, y: 2)
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
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(.ultraThinMaterial)
                .overlay(
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .fill(
                            LinearGradient(
                                colors: [
                                    Color(red: 0.12, green: 0.18, blue: 0.35).opacity(0.85),
                                    Color(red: 0.10, green: 0.13, blue: 0.25).opacity(0.85)
                                ],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            )
                        )
                )
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

            StatusIcon(action: onMicToggle) {
                Image(systemName: micMuted ? "mic.slash.fill" : "mic.fill")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(micMuted
                        ? Color(red: 0.95, green: 0.55, blue: 0.55)
                        : .white.opacity(0.85))
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
            Capsule(style: .continuous)
                .fill(.ultraThinMaterial)
                .overlay(Capsule().fill(Theme.Palette.bgSoft.opacity(0.75)))
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
    let supabase = SupabaseClient(supabaseURL: SupabaseConfig.url, supabaseKey: SupabaseConfig.anonKey)
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
