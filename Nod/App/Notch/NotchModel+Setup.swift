import Foundation

/// The notch's half of onboarding. Every card asks for one thing; a thing this
/// Mac has already granted is stepped over rather than shown as a tick, and the
/// flow ends on the first capture — or on declining it.
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

    /// The week, spoken: setup is over, and the first recording starts on the
    /// same click. A voice note, so the system-audio gate never stands in
    /// the way; the consent and language gates still do, as for any first
    /// recording. The Library opens behind it, which is where the recap and
    /// its action items will land.
    func startFirstCaptureFromSetup() {
        session.selectedKind = .voiceNote
        finishSetup()
        requestStart()
    }

    /// The person left a permission ungranted on purpose.
    func skipSetupStage() {
        guard let current = setup else { return }
        if current == .microphone {
            onboardingTelemetry.permissionsSkipped()
            onboarding.recordPermissionsDecision(skipped: true)
        }
        advanceSetup()
    }

    private func show(_ stage: NotchSetupStage) {
        setup = stage
        isOpened = true
        onboardingTelemetry.setupStageShown(stage)
        refresh()
    }

    /// Whether this Mac has already answered an ask, so the card is not shown.
    /// Machine-level facts only: macOS grants the microphone to the app, not to
    /// an account. The calendar is asked of everybody — a second account may
    /// want a different one — unless it is already connected.
    private func isSetupStageSatisfied(_ stage: NotchSetupStage) -> Bool {
        switch stage {
        case .microphone: permissions.microphone == .authorized
        case .calendar: CalendarSourceState.isAnswered(calendar: calendar, integrations: integrations)
        case .intro, .plans: false
        }
    }
}
