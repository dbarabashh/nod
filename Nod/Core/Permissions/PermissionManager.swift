import AppKit
import AVFoundation
import Combine
import Foundation

enum PermissionStatus: String, Codable {
    case notDetermined
    case authorized
    case denied
}

@MainActor
final class PermissionManager: ObservableObject {
    @Published private(set) var microphone: PermissionStatus = .notDetermined
    @Published private(set) var screenRecording: PermissionStatus = .notDetermined

    /// True when SR access was requested during this app session — used by the
    /// onboarding UI to surface "Quit & Relaunch" once the user comes back from
    /// System Settings, since ScreenCaptureKit can't pick up a freshly added
    /// TCC entry without a process restart.
    @Published private(set) var requestedScreenRecordingThisSession: Bool = false

    /// Set when `relaunch()` was attempted but the OS refused to spawn a new
    /// instance (signing, sandbox, missing bundle). The UI surfaces this so the
    /// user can quit/reopen manually instead of losing the app silently.
    @Published var lastRelaunchError: String?

    private static let screenPromptedKey = "permissions.screenRecording.prompted"

    /// The relaunch copy, here rather than in each surface: three cards now say
    /// it, and they had already drifted into three slightly different
    /// sentences about the same macOS behaviour.
    static let relaunchHint = "macOS only applies Screen Recording after Nod restarts."

    static func relaunchFailureMessage(_ error: String) -> String {
        "Relaunch failed: \(error). Quit and reopen Nod yourself."
    }

    /// The line under a Screen Recording ask once it has been made: why
    /// nothing changed yet, or why the relaunch that would change it failed.
    var relaunchMessage: String {
        lastRelaunchError.map(Self.relaunchFailureMessage) ?? Self.relaunchHint
    }

    init() {
        refresh()
        NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
    }

    /// Both grants Nod needs to hear a conversation: the microphone for the
    /// user's own side, screen recording for everything else the Mac plays.
    /// Asked by the onboarding step, the settings card and the setup checklist
    /// — three places that were each spelling the conjunction themselves.
    var canCaptureBothSides: Bool {
        microphone == .authorized && screenRecording == .authorized
    }

    func refresh() {
        // Assigned only on a change: this runs on every app activation, and an
        // unchanged grant would still invalidate the body of everything
        // observing — which now includes surfaces that redraw a whole list.
        let mic = currentMicrophoneStatus()
        if mic != microphone { microphone = mic }
        let screen = currentScreenRecordingStatus()
        if screen != screenRecording { screenRecording = screen }
    }

    // MARK: - Microphone

    func requestMicrophone() async -> Bool {
        if microphone == .authorized { return true }

        let granted = await withCheckedContinuation { (cont: CheckedContinuation<Bool, Never>) in
            AVCaptureDevice.requestAccess(for: .audio) { granted in
                cont.resume(returning: granted)
            }
        }
        microphone = granted ? .authorized : .denied
        return granted
    }

    func openMicrophoneSettings() {
        SystemSettings.open(privacyPane: "Privacy_Microphone")
    }

    // MARK: - Screen Recording

    /// What asking for Screen Recording could establish. There is deliberately
    /// no `denied` case: once the user answers the TCC prompt, this process
    /// keeps seeing the access it started with, so a grant and a refusal are
    /// indistinguishable until a fresh process asks. Reporting `denied` there
    /// was a guess, and it read as a failure to users who had just said yes.
    enum ScreenRecordingRequest {
        case authorized
        case pendingRelaunch
    }

    // CGRequestScreenCaptureAccess returns the *current* state and triggers the TCC
    // prompt only on the first call. The user's response is asynchronous — Meetily
    // mirrors this by re-checking after the prompt and routing to System Settings
    // on subsequent attempts.
    func requestScreenRecording() async -> ScreenRecordingRequest {
        if screenRecording == .authorized { return .authorized }

        requestedScreenRecordingThisSession = true
        UserDefaults.standard.set(true, forKey: Self.screenPromptedKey)

        if CGRequestScreenCaptureAccess() {
            screenRecording = .authorized
            return .authorized
        }

        try? await Task.sleep(nanoseconds: 800_000_000)
        if CGPreflightScreenCaptureAccess() {
            screenRecording = .authorized
            return .authorized
        }

        // Not "no" — "not yet visible here". The row switches to Open Settings,
        // which is the right next step whether they refused or granted in a
        // pane this process can't see.
        screenRecording = .denied
        return .pendingRelaunch
    }

    /// Counts as asking. On the second launch the row already reads `.denied`,
    /// so this — not `requestScreenRecording()` — is the button the user
    /// presses; without the flag they grant access in System Settings, come
    /// back, and are never told a restart is what's still missing.
    /// Whether asking again can still produce the TCC prompt.
    ///
    /// `CGRequestScreenCaptureAccess` shows its dialog once per install, so
    /// once we've been refused the only honest next step is System Settings.
    /// Both the button's label and the button's action need this answer, and
    /// they were deciding it separately.
    var canPromptForScreenRecording: Bool {
        screenRecording != .denied
    }

    func openScreenRecordingSettings() {
        requestedScreenRecordingThisSession = true
        SystemSettings.open(privacyPane: "Privacy_ScreenCapture")
    }

    #if DEBUG || NOD_SANDBOX
        /// The next launch is a genuine first run rather than a replay over
        /// green ticks: our own prompted flag goes, and macOS is asked to
        /// forget the grants. `tccutil reset` on the app's own bundle needs
        /// no privilege and has to land before the relaunch, so it is waited
        /// for; a grant it could not clear is logged, not fatal.
        static func resetPersistedGrants() {
            UserDefaults.standard.removeObject(forKey: screenPromptedKey)
            guard let bundleID = Bundle.main.bundleIdentifier else { return }
            for service in ["Microphone", "ScreenCapture", "Accessibility"] {
                let process = Process()
                process.executableURL = URL(fileURLWithPath: "/usr/bin/tccutil")
                process.arguments = ["reset", service, bundleID]
                process.standardOutput = FileHandle.nullDevice
                do {
                    try process.run()
                    process.waitUntilExit()
                    if process.terminationStatus != 0 {
                        Log.ui.error("first-run reset: tccutil reset \(service) exited \(process.terminationStatus)")
                    }
                } catch {
                    Log.ui.error("first-run reset: tccutil reset \(service) failed — \(error.localizedDescription)")
                }
            }
        }
    #endif

    // MARK: - Relaunch

    /// Quits the app and asks Launch Services to start it again. Needed after
    /// the user grants Screen Recording in System Settings — ScreenCaptureKit
    /// only picks up the new TCC entry on a fresh process. Only terminates on
    /// confirmed success — otherwise the user would be left with no app.
    func relaunch() {
        lastRelaunchError = nil
        let bundleURL = Bundle.main.bundleURL
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.createsNewApplicationInstance = true
        NSWorkspace.shared.openApplication(at: bundleURL, configuration: configuration) { [weak self] _, error in
            DispatchQueue.main.async {
                if let error {
                    Log.ui.error("relaunch failed: \(error.localizedDescription)")
                    self?.lastRelaunchError = error.localizedDescription
                    return
                }
                NSApp.terminate(nil)
            }
        }
    }

    // MARK: - Internals

    private func currentMicrophoneStatus() -> PermissionStatus {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: return .authorized
        case .denied, .restricted: return .denied
        case .notDetermined: return .notDetermined
        @unknown default: return .notDetermined
        }
    }

    // macOS doesn't expose a notDetermined vs. denied distinction for screen
    // capture. We synthesize it: a persisted "we've prompted before" flag flips
    // notDetermined → denied so the UI knows to surface "Open Settings".
    private func currentScreenRecordingStatus() -> PermissionStatus {
        if CGPreflightScreenCaptureAccess() { return .authorized }
        let prompted = UserDefaults.standard.bool(forKey: Self.screenPromptedKey)
        return prompted ? .denied : .notDetermined
    }
}
