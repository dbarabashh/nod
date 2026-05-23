import Foundation
import AppKit
import AVFoundation
import ScreenCaptureKit
import Combine

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

    func refresh() {
        microphone = currentMicrophoneStatus()
        screenRecording = currentScreenRecordingStatus()
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
        open("x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone")
    }

    // MARK: - Screen Recording

    // CGRequestScreenCaptureAccess returns the *current* state and triggers the TCC
    // prompt only on the first call. The user's response is asynchronous — Meetily
    // mirrors this by re-checking after the prompt and routing to System Settings
    // on subsequent attempts.
    func requestScreenRecording() async -> Bool {
        if screenRecording == .authorized { return true }

        requestedScreenRecordingThisSession = true
        UserDefaults.standard.set(true, forKey: Self.screenPromptedKey)

        if CGRequestScreenCaptureAccess() {
            screenRecording = .authorized
            return true
        }

        try? await Task.sleep(nanoseconds: 800_000_000)
        if CGPreflightScreenCaptureAccess() {
            screenRecording = .authorized
            return true
        }

        screenRecording = .denied
        return false
    }

    func openScreenRecordingSettings() {
        open("x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")
    }

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

    private func open(_ urlString: String) {
        guard let url = URL(string: urlString) else { return }
        NSWorkspace.shared.open(url)
    }
}
