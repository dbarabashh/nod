import SwiftUI

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

            if showConsentDisclaimer {
                ConsentDisclaimerView(
                    strings: ConsentStrings.forLanguageCode(language.current.whisperCode),
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
                onLanguageToggle: { language.toggle() },
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
                    label: "Key points",
                    dotColor: Color(red: 0.62, green: 0.78, blue: 0.95),
                    isGenerating: isGenerating(for: "Key points"),
                    enabled: meeting == .recording,
                    action: { generate(kind: "Key points") }
                )
                SuggestionPill(
                    label: "Suggest follow-up questions",
                    dotColor: Color(red: 0.78, green: 0.70, blue: 0.95),
                    isGenerating: isGenerating(for: "Suggest follow-up questions"),
                    enabled: meeting == .recording,
                    action: { generate(kind: "Suggest follow-up questions") }
                )
                SuggestionPill(
                    label: "Recap so far",
                    trailingEmoji: "📝",
                    dotColor: Color(red: 0.62, green: 0.90, blue: 0.72),
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
                    onCopy: { copy(text) },
                    onDismiss: {
                        if isSummarizing {
                            cleanupToIdle()
                        } else {
                            response = .none
                        }
                    }
                )
                .transition(.opacity.combined(with: .move(edge: .leading)))
            } else if case let .generating(kind) = response, kind == "Meeting Summary" {
                ResponseCard(
                    kind: "Meeting Summary",
                    text: "Generating summary…",
                    onCopy: {},
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
        Task {
            let (system, user) = PromptLibrary.build(kind: .summary, transcript: context, language: language.current)
            do {
                let text = try await llm.complete(system: system, user: user)
                await MainActor.run {
                    if case let .generating(k) = response, k == "Meeting Summary" {
                        response = .ready(kind: "Meeting Summary", text: text)
                    }
                }
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
        let context = store.fullContext
        if context.isEmpty {
            Log.ui.info("⚠️ context is EMPTY — LLM will get only the system prompt")
        }
        Task {
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
    let onLanguageToggle: () -> Void
    var onCollapse: (() -> Void)? = nil
    @State private var pulsing = false

    var body: some View {
        HStack(spacing: 8) {
            indicator
            Text(label)
                .font(.system(size: 12, weight: .semibold))
                .foregroundColor(.white.opacity(0.85))
            if meeting != .idle {
                Text(elapsed)
                    .font(.system(size: 12, weight: .medium, design: .monospaced))
                    .foregroundColor(.white.opacity(0.55))
            }
            Spacer(minLength: 0)
            LanguageToggle(language: language, action: onLanguageToggle)
            if let onCollapse {
                Button(action: onCollapse) {
                    Image(systemName: "chevron.up")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundColor(.white.opacity(0.7))
                        .frame(width: 16, height: 16)
                }
                .buttonStyle(.plain)
                .help("Collapse")
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(
            Capsule(style: .continuous)
                .fill(.ultraThinMaterial)
                .overlay(Capsule().fill(Color.black.opacity(0.25)))
                .overlay(Capsule().stroke(Color.white.opacity(0.10), lineWidth: 0.5))
        )
        .onAppear { pulsing = true }
    }

    @ViewBuilder private var indicator: some View {
        switch meeting {
        case .idle:
            Circle()
                .fill(Color.white.opacity(0.35))
                .frame(width: 8, height: 8)
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

private struct LanguageToggle: View {
    let language: AppLanguage
    let action: () -> Void

    var body: some View {
        Button(action: {
            print("→ language tap")
            action()
        }) {
            Text(language.chipLabel)
                .font(.system(size: 10, weight: .bold, design: .rounded))
                .tracking(0.5)
                .foregroundColor(.white.opacity(0.85))
                .padding(.horizontal, 7)
                .padding(.vertical, 3)
                .background(
                    Capsule(style: .continuous)
                        .fill(Color.white.opacity(0.12))
                        .overlay(Capsule().stroke(Color.white.opacity(0.18), lineWidth: 0.5))
                )
        }
        .buttonStyle(.plain)
        .help("Switch language — affects transcription and AI responses")
    }
}

private struct StartMeetingButton: View {
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: "record.circle.fill")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundColor(Color(red: 0.95, green: 0.45, blue: 0.50))

                Text("Start Meeting")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundColor(.white)

                Spacer(minLength: 0)
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 12)
            .frame(width: 240, alignment: .leading)
            .background(
                Capsule(style: .continuous)
                    .fill(.ultraThinMaterial)
                    .overlay(
                        Capsule(style: .continuous)
                            .fill(
                                LinearGradient(
                                    colors: [
                                        Color(red: 0.55, green: 0.20, blue: 0.30).opacity(0.55),
                                        Color(red: 0.40, green: 0.15, blue: 0.25).opacity(0.45)
                                    ],
                                    startPoint: .topLeading,
                                    endPoint: .bottomTrailing
                                )
                            )
                    )
                    .overlay(
                        Capsule(style: .continuous)
                            .stroke(Color.white.opacity(0.22), lineWidth: 0.6)
                    )
            )
            .shadow(color: Color(red: 0.60, green: 0.20, blue: 0.30).opacity(0.4), radius: 10, x: 0, y: 4)
        }
        .buttonStyle(.plain)
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
            HStack(spacing: 10) {
                if isGenerating {
                    ProgressView()
                        .controlSize(.small)
                        .progressViewStyle(.circular)
                        .tint(.white)
                        .frame(width: 16, height: 16)
                } else {
                    Image(systemName: "sparkles")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundColor(Color(red: 0.62, green: 0.82, blue: 1.0))
                        .opacity(shimmering ? 0.65 : 1.0)
                        .animation(.easeInOut(duration: 1.4).repeatForever(autoreverses: true), value: shimmering)
                }

                Text(isGenerating ? "Recalling…" : "Catch me up")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundColor(.white)

                Spacer(minLength: 0)
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 12)
            .frame(width: 240, alignment: .leading)
            .background(
                Capsule(style: .continuous)
                    .fill(.ultraThinMaterial)
                    .overlay(
                        Capsule(style: .continuous)
                            .fill(
                                LinearGradient(
                                    colors: [
                                        Color(red: 0.20, green: 0.35, blue: 0.65).opacity(0.55),
                                        Color(red: 0.15, green: 0.25, blue: 0.55).opacity(0.45)
                                    ],
                                    startPoint: .topLeading,
                                    endPoint: .bottomTrailing
                                )
                            )
                    )
                    .overlay(
                        Capsule(style: .continuous)
                            .stroke(Color.white.opacity(0.22), lineWidth: 0.6)
                    )
            )
            .shadow(color: Color(red: 0.15, green: 0.30, blue: 0.60).opacity(0.45), radius: 10, x: 0, y: 4)
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
            HStack(spacing: 10) {
                if isGenerating {
                    ProgressView()
                        .controlSize(.mini)
                        .progressViewStyle(.circular)
                        .tint(.white)
                        .frame(width: 10, height: 10)
                } else {
                    Circle()
                        .fill(dotColor)
                        .frame(width: 10, height: 10)
                }

                HStack(spacing: 4) {
                    Text(label)
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundColor(.white)
                    if let trailingEmoji {
                        Text(trailingEmoji)
                            .font(.system(size: 14))
                    }
                }

                Spacer(minLength: 0)
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 10)
            .frame(width: 220, alignment: .leading)
            .background(
                Capsule(style: .continuous)
                    .fill(.ultraThinMaterial)
                    .overlay(
                        Capsule(style: .continuous)
                            .fill(Color.black.opacity(0.25))
                    )
                    .overlay(
                        Capsule(style: .continuous)
                            .stroke(Color.white.opacity(0.12), lineWidth: 0.5)
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
    let onCopy: () -> Void
    let onDismiss: () -> Void

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

            Text(text)
                .font(.system(size: 13, weight: .regular))
                .foregroundColor(.white.opacity(0.92))
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)

            HStack(spacing: 8) {
                Spacer(minLength: 0)
                MiniAction(label: "Copy", icon: "doc.on.doc", action: onCopy)
                MiniAction(label: "Insert", icon: "arrow.right.circle.fill") {
                    print("→ Insert (dummy)")
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

#Preview {
    let llm = OpenRouterClient()
    let language = LanguagePreference()
    // Use a dedicated UserDefaults suite so previewing the Acknowledge flow
    // doesn't taint the developer's installed app's consent state.
    let previewDefaults = UserDefaults(suiteName: "nod.preview.consent") ?? .standard
    return ContentView()
        .environmentObject(AudioCaptureService())
        .environmentObject(llm)
        .environmentObject(TranscriptStore(client: llm, language: language))
        .environmentObject(language)
        .environmentObject(ConsentPreference(defaults: previewDefaults))
        .background(Color.gray.opacity(0.3))
}
