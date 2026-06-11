import AppKit
import SwiftUI

/// Owns every window the app can show — sign-in, onboarding, the floating
/// panel, Library, Settings — and the reconciliation rule that decides which
/// of the three primary surfaces matches the current auth/onboarding state.
@MainActor
final class WindowCoordinator: NSObject, NSWindowDelegate {
    private let services: AppServices
    private(set) var panel: NSPanel?
    private var onboardingWindow: NSWindow?
    private var signInWindow: NSWindow?
    private var historyWindow: NSWindow?
    private var settingsWindow: NSWindow?

    init(services: AppServices) {
        self.services = services
    }

    /// Drives every window transition, including the initial one.
    /// Idempotent show*/close* methods make repeat calls safe.
    func reconcile() {
        if services.auth.session == nil {
            closeFloatingPanel()
            closeOnboardingWindow()
            showSignInWindow()
        } else if !services.onboarding.isCompleted {
            closeFloatingPanel()
            closeSignInWindow()
            showOnboardingWindow()
        } else {
            closeSignInWindow()
            closeOnboardingWindow()
            showFloatingPanel()
        }
    }

    func toggleFloatingPanel() {
        guard let panel else { return }
        if panel.isVisible {
            panel.orderOut(nil)
        } else {
            panel.orderFrontRegardless()
        }
    }

    func hidePanel() {
        panel?.orderOut(nil)
    }

    func setPanelVisibleWhenSharing(_ visible: Bool) {
        panel?.sharingType = visible ? .readOnly : .none
    }

    // MARK: - Sign-in window

    private func showSignInWindow() {
        guard signInWindow == nil else { return }
        NSApp.setActivationPolicy(.regular)

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 420, height: 420),
            styleMask: [.titled, .closable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.appearance = NSAppearance(named: .darkAqua)
        window.center()

        let root = SignInView().environmentObject(services.auth)
        window.contentViewController = NSHostingController(rootView: root)
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        signInWindow = window
    }

    private func closeSignInWindow() {
        if let window = signInWindow {
            // Detach delegate so the windowWillClose handler doesn't recurse.
            window.delegate = nil
            window.close()
        }
        signInWindow = nil
    }

    // MARK: - Onboarding window

    private func showOnboardingWindow() {
        guard onboardingWindow == nil else { return }

        NSApp.setActivationPolicy(.regular)

        // .resizable so users with large system text settings can grow the
        // window when content overflows the 580x540 default.
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 580, height: 540),
            styleMask: [.titled, .closable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.appearance = NSAppearance(named: .darkAqua)
        window.center()

        let root = OnboardingView(onComplete: { [weak self] in
            self?.reconcile()
        })
        .environmentObject(services.permissions)
        .environmentObject(services.onboarding)
        .environmentObject(services.languagePreference)
        .environmentObject(services.profileStore)
        .environmentObject(services.auth)

        window.contentViewController = NSHostingController(rootView: root)
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        onboardingWindow = window
    }

    private func closeOnboardingWindow() {
        if let window = onboardingWindow {
            window.delegate = nil
            window.close()
        }
        onboardingWindow = nil
    }

    // MARK: - Floating panel

    private func showFloatingPanel() {
        // Idempotent — re-entrant from the auth observer is normal.
        guard panel == nil else { return }

        NSApp.setActivationPolicy(.accessory)

        // One session per panel — its lifetime matches the old view-local
        // @State (created with the panel, dropped on sign-out teardown), so
        // a mid-recording sign-out can't leak a stale REC state into the
        // next user's panel.
        let meetingSession = MeetingSession(
            audioCapture: services.audioCapture,
            store: services.transcriptStore,
            llm: services.llmClient,
            meetingStore: services.meetingStore,
            entityStore: services.entityStore,
            knowledgeStore: services.knowledgeStore,
            language: services.languagePreference,
            auth: services.auth,
            profileStore: services.profileStore
        )

        let content = ContentView(
            onPreferredWidthChange: { [weak self] width in self?.panel?.setWidth(to: width) }
        )
        .environmentObject(meetingSession)
        .environmentObject(services.audioCapture)
        .environmentObject(services.languagePreference)
        .environmentObject(services.consent)
        .environmentObject(services.entitlements)
        .environmentObject(services.updateGate)
        .environmentObject(services.hotkeys)

        // Start at the compact width — the panel launches idle. ContentView
        // reports the desired width as the layout changes and the panel
        // animates the frame, keeping the left edge anchored.
        let panel = FloatingPanel(
            contentRect: NSRect(x: 0, y: 0, width: PanelWidth.compact, height: 560),
            content: content
        )
        panel.sharingType = services.panelSharing.sharingType
        panel.positionOnLeftCenter()
        panel.orderFrontRegardless()
        self.panel = panel
    }

    private func closeFloatingPanel() {
        panel?.close()
        panel = nil
    }

    // MARK: - Settings window

    func showSettingsWindow(focusSubscription: Bool = false) {
        if let existing = settingsWindow {
            existing.makeKeyAndOrderFront(nil)
            return
        }
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 740, height: 560),
            styleMask: [.titled, .closable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.title = "Settings"
        window.titlebarAppearsTransparent = true
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.appearance = NSAppearance(named: .darkAqua)
        window.center()
        window.contentViewController = NSHostingController(rootView: SettingsView(
            hotkey: services.hotkeys,
            profileStore: services.profileStore,
            panelSharing: services.panelSharing,
            billing: services.billing,
            entitlements: services.entitlements,
            focusSubscription: focusSubscription
        ))
        window.makeKeyAndOrderFront(nil)
        settingsWindow = window
    }

    func closeSettingsWindow() {
        if let window = settingsWindow {
            window.delegate = nil
            window.close()
        }
        settingsWindow = nil
    }

    // MARK: - History window (issue #14)

    func showHistoryWindow(focusing meetingID: UUID? = nil) {
        if let existing = historyWindow {
            existing.makeKeyAndOrderFront(nil)
            // HistoryView is already mounted and observing the
            // `.nodOpenMeetingDetail` notification — its own `.onReceive`
            // handles the navigation push.
            return
        }

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1040, height: 640),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.title = "Library"
        window.titlebarAppearsTransparent = true
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.appearance = NSAppearance(named: .darkAqua)
        // Min size accommodates the list/detail column + the fixed 380pt chat
        // dock so neither can collapse below a usable width.
        window.contentMinSize = NSSize(width: 860, height: 520)
        window.center()

        // First-mount focus is handed in via init — the open-detail
        // notification fires before HistoryView's `.onReceive` subscribes
        // when the window is being created fresh, so its `.task` reads
        // `initialFocusMeetingID` after the initial refresh instead.
        let root = HistoryView(initialFocusMeetingID: meetingID)
            .frame(minWidth: 860, minHeight: 520)
            .environmentObject(services.meetingStore)
            .environmentObject(services.chatStore)
            .environmentObject(services.profileStore)
            .environmentObject(services.entityStore)
            .environmentObject(services.knowledgeStore)
            .environmentObject(services.llmClient)
            .environmentObject(services.languagePreference)
            .environmentObject(services.labelStore)
            .environmentObject(services.entitlements)

        window.contentViewController = NSHostingController(rootView: root)
        window.makeKeyAndOrderFront(nil)
        historyWindow = window
    }

    func closeHistoryWindow() {
        if let window = historyWindow {
            window.delegate = nil
            window.close()
        }
        historyWindow = nil
    }

    // MARK: - NSWindowDelegate

    nonisolated func windowWillClose(_ notification: Notification) {
        let closed = notification.object as AnyObject?
        Task { @MainActor [weak self] in
            guard let self else { return }
            if closed === signInWindow {
                signInWindow = nil
            } else if closed === onboardingWindow {
                onboardingWindow = nil
            } else if closed === historyWindow {
                // History is auxiliary — closing it doesn't trigger any
                // reconciliation; the floating panel keeps running.
                historyWindow = nil
                return
            } else if closed === settingsWindow {
                settingsWindow = nil
                return
            }
            // User-initiated close of the only UI: re-open whichever window
            // matches the current state. closing the sign-in window with no
            // session would otherwise leave the app with zero UI.
            reconcile()
        }
    }
}
