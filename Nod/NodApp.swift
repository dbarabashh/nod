import SwiftUI
import AppKit

@main
struct NodApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        Settings {
            EmptyView()
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var panel: NSPanel?
    private var onboardingWindow: NSWindow?
    private var permissions: PermissionManager?
    private var onboarding: OnboardingState?
    private var audioCapture: AudioCaptureService?
    private var llmClient: OpenRouterClient?
    private var transcriptStore: TranscriptStore?
    private var languagePreference: LanguagePreference?
    private var upcomingMeetings: UpcomingMeetingService?

    func applicationDidFinishLaunching(_ notification: Notification) {
        Task { @MainActor in
            let permissions = PermissionManager()
            let onboarding = OnboardingState()
            let audioCapture = AudioCaptureService()
            let llmClient = OpenRouterClient()
            let languagePreference = LanguagePreference()
            let transcriptStore = TranscriptStore(client: llmClient, language: languagePreference)
            let upcomingMeetings = UpcomingMeetingService()
            Task { await upcomingMeetings.requestAccessIfNeeded() }

            audioCapture.onMicBuffer = { [weak transcriptStore] buffer in
                transcriptStore?.appendMicBuffer(buffer)
            }
            audioCapture.onSystemBuffer = { [weak transcriptStore] buffer in
                transcriptStore?.appendSystemBuffer(buffer)
            }

            self.permissions = permissions
            self.onboarding = onboarding
            self.audioCapture = audioCapture
            self.llmClient = llmClient
            self.transcriptStore = transcriptStore
            self.languagePreference = languagePreference
            self.upcomingMeetings = upcomingMeetings

            if onboarding.isCompleted {
                showFloatingPanel()
            } else {
                showOnboardingWindow()
            }
        }
    }

    @MainActor
    private func showOnboardingWindow() {
        guard let permissions, let onboarding else { return }

        NSApp.setActivationPolicy(.regular)

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 520, height: 420),
            styleMask: [.titled, .closable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.isReleasedWhenClosed = false
        window.center()

        let root = OnboardingView(onComplete: { [weak self] in
            Task { @MainActor in
                self?.onboardingWindow?.close()
                self?.onboardingWindow = nil
                self?.showFloatingPanel()
            }
        })
        .environmentObject(permissions)
        .environmentObject(onboarding)

        window.contentViewController = NSHostingController(rootView: root)
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        onboardingWindow = window
    }

    @MainActor
    private func showFloatingPanel() {
        guard let audioCapture, let llmClient, let transcriptStore, let languagePreference, let upcomingMeetings else { return }
        NSApp.setActivationPolicy(.accessory)

        let content = ContentView()
            .environmentObject(audioCapture)
            .environmentObject(llmClient)
            .environmentObject(transcriptStore)
            .environmentObject(languagePreference)
            .environmentObject(upcomingMeetings)

        let panel = FloatingPanel(
            contentRect: NSRect(x: 0, y: 0, width: 640, height: 560),
            content: content
        )
        panel.positionOnLeftCenter()
        panel.orderFrontRegardless()
        self.panel = panel
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }
}
