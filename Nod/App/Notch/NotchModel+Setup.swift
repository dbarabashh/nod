import Foundation

/// The notch's half of onboarding. Every card asks for one thing; a thing this
/// Mac has already granted is stepped over rather than shown as a tick, and the
/// flow ends the first time a real question comes back answered.
extension NotchModel {
    /// Called by the coordinator once the window has handed off. A no-op for
    /// an account that has finished — the notch is built on every sign-in.
    func beginSetup() {
        guard onboarding.isSettingUpInNotch, setup == nil else { return }
        show(.intro)
        Log.ui.info("setup: started in the notch")
    }

    /// The card's own next: whatever follows, skipping what is already answered.
    func advanceSetup() {
        guard let current = setup else { return }
        var next = current.next
        while let candidate = next, isSetupStageSatisfied(candidate) {
            next = candidate.next
        }
        guard let next else { return finishSetup() }
        show(next)
    }

    /// Done, from the last card or the corner glyph. Either way the account is
    /// through: a permission left ungranted stays one click away in Settings,
    /// and the flow must never be something the person cannot get out of.
    func finishSetup() {
        guard setup != nil else { return }
        setup = nil
        isOpened = false
        onboarding.complete()
        onboardingTelemetry.completed()
        Log.ui.info("setup: finished")
        refresh()
        // The notch has been the whole of onboarding; the window it hands
        // back to is the one place the day's own screen — and the first-visit
        // tips on it — actually lives.
        openLibrary()
    }

    func requestMicrophoneFromSetup() {
        guard !isRequestingSetupPermission else { return }
        isRequestingSetupPermission = true
        onboardingTelemetry.permissionRequested(.microphone)
        Task { @MainActor in
            let granted = await permissions.requestMicrophone()
            onboardingTelemetry.permissionResolved(.microphone, granted: granted)
            isRequestingSetupPermission = false
            if granted { advanceSetup() }
        }
    }

    func requestSystemAudioFromSetup() {
        guard !isRequestingSetupPermission else { return }
        isRequestingSetupPermission = true
        onboardingTelemetry.permissionRequested(.screenRecording)
        Task { @MainActor in
            switch await permissions.requestScreenRecording() {
            case .authorized:
                onboardingTelemetry.permissionResolved(.screenRecording, granted: true)
                isRequestingSetupPermission = false
                advanceSetup()
            case .pendingRelaunch:
                onboardingTelemetry.screenRecordingPendingRelaunch()
                onboardingTelemetry.relaunchPrompted()
                isRequestingSetupPermission = false
                refresh()
            }
        }
    }

    /// The relaunch the Screen Recording grant needs. The setup resumes on
    /// this same card in the new process: the step is stored, and the next
    /// launch walks straight past it if the grant took.
    func relaunchFromSetup() {
        Task { @MainActor in
            await onboardingTelemetry.relaunchClicked()
            permissions.relaunch()
        }
    }

    /// The same switch Settings flips, flipped from the card that explained it.
    /// It asks macOS for Accessibility on the way; the card then waits for the
    /// grant, which `ScreenContextService` notices on its own.
    func enableAmbientFromSetup() {
        screenContext.setAmbientEnabled(true)
        refresh()
    }

    /// The person left a permission ungranted on purpose.
    func skipSetupStage() {
        guard let current = setup else { return }
        if current == .microphone || current == .systemAudio {
            onboardingTelemetry.permissionsSkipped()
            onboarding.recordPermissionsDecision(skipped: true)
        }
        advanceSetup()
    }

    /// The first question, from the last card. The thread is the Library's;
    /// the card shows only what lands after it opened.
    func submitSetupAsk(_ question: String) {
        submitIdleAsk(question)
    }

    private func show(_ stage: NotchSetupStage) {
        setup = stage
        isOpened = true
        if stage == .firstAsk {
            askBaseline = knowledgeChat.messages.count
        }
        onboardingTelemetry.setupStageShown(stage)
        refresh()
        if stage == .firstAsk {
            onWantsKeyboard?()
        }
        // From here the flow is effectively done — the remaining cards are
        // "here's how to use it", not more setup — so the room the person
        // will actually work in is already open behind the notch.
        if stage == .ready || stage == .firstAsk {
            openLibrary()
        }
    }

    /// Whether this Mac has already answered an ask, so the card is not shown.
    /// Machine-level facts only: macOS grants the microphone to the app, not to
    /// an account. The calendar is asked of everybody — a second account may
    /// want a different one — unless it is already connected.
    private func isSetupStageSatisfied(_ stage: NotchSetupStage) -> Bool {
        switch stage {
        case .microphone: permissions.microphone == .authorized
        case .systemAudio: permissions.screenRecording == .authorized
        case .ambient: screenContext.isRunning
        case .calendar: CalendarSourceState.isAnswered(calendar: calendar, integrations: integrations)
        case .intro, .ready, .firstAsk: false
        }
    }
}
