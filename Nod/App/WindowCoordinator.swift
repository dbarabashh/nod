import AppKit
import Combine
import SwiftUI

/// Owns every window the app can show — sign-in, onboarding, the floating
/// panel, Library, Settings — and the reconciliation rule that decides which
/// of the three primary surfaces matches the current auth/onboarding state.
@MainActor
final class WindowCoordinator: NSObject, NSWindowDelegate {
    private let services: AppServices
    private(set) var panel: NSPanel?
    /// The panel's session. Held so the window can hand it a capture kind —
    /// the alternative was routing that through the panel's *view*, which made
    /// a view the app's intent router.
    private var meetingSession: MeetingSession?
    /// Watches for a call starting and ending. Lives with the panel's session,
    /// which is the thing it can act on.
    private var detector: MeetingDetector?
    private var detectionCard: FloatingPanel<MeetingDetectedCard>?
    private var detectionObserver: AnyCancellable?
    private var onboardingWindow: NSWindow?
    private var signInWindow: NSWindow?
    private var mainWindow: NSWindow?

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
            buildFloatingPanel()
            applyLaunchBehavior()
        }
    }

    /// What launch puts on screen. Opening the app is not the same as asking to
    /// capture, so the panel only arrives when the user chose that — or asks for
    /// it later by hotkey, menu bar, or the Capture button.
    ///
    /// Runs once per signed-in run: the auth publisher emits on every token
    /// refresh, and a window the user closed must stay closed.
    private func applyLaunchBehavior() {
        guard !didApplyLaunchBehavior else { return }
        didApplyLaunchBehavior = true
        switch services.launchBehavior.mode {
        case .mainWindow:
            showMainWindow()
            NSApp.activate(ignoringOtherApps: true)
        case .capturePanel:
            revealPanel()
        case .menuBarOnly:
            break
        }
    }

    private var didApplyLaunchBehavior = false

    /// The quick panel, built on first use — most sessions never open it, and
    /// it holds a hosting controller plus an event monitor.
    private lazy var launcher = LauncherController(
        services: services,
        openMeeting: { [weak self] id in self?.showMainWindow(focusing: id) },
        openLibrary: { [weak self] in self?.showMainWindow() }
    )

    func toggleLauncher() {
        launcher.toggle()
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

    /// Order an existing (possibly hotkey-hidden) panel back to the front.
    /// Unlike `showFloatingPanel`, this never creates one — it's the Dock
    /// re-open path, where `reconcile` has already ensured the right surface
    /// exists.
    func revealPanel() {
        panel?.orderFrontRegardless()
    }

    func setPanelVisibleWhenSharing(_ visible: Bool) {
        panel?.sharingType = visible ? .readOnly : .none
        mainWindow?.sharingType = visible ? .readOnly : .none
        // Keep the Dock icon / ⌘-Tab entry in lockstep with share visibility —
        // hiding the panel from captures is pointless if the Dock still shows
        // Nod. Only while the panel is the active surface; sign-in/onboarding
        // force .regular regardless.
        if panel != nil {
            NSApp.setActivationPolicy(visible ? .regular : .accessory)
        }
    }

    /// Shared chrome for every coordinator-owned window: transparent
    /// titlebar, dark appearance, this coordinator as delegate, centred.
    private func makeWindow(contentRect: NSRect, styleMask: NSWindow.StyleMask) -> NSWindow {
        let window = NSWindow(
            contentRect: contentRect,
            styleMask: styleMask,
            backing: .buffered,
            defer: false
        )
        window.titlebarAppearsTransparent = true
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.appearance = NSAppearance(named: .darkAqua)
        window.center()
        return window
    }

    private func close(_ window: inout NSWindow?) {
        if let window {
            // Detach delegate so the windowWillClose handler doesn't recurse.
            window.delegate = nil
            window.close()
        }
        window = nil
    }

    // MARK: - Sign-in window

    private func showSignInWindow() {
        guard signInWindow == nil else { return }
        NSApp.setActivationPolicy(.regular)

        let window = makeWindow(
            contentRect: NSRect(x: 0, y: 0, width: 420, height: 420),
            styleMask: [.titled, .closable, .fullSizeContentView]
        )
        window.titleVisibility = .hidden

        let root = SignInView().environmentObject(services.auth)
        window.contentViewController = NSHostingController(rootView: root)
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        signInWindow = window
    }

    private func closeSignInWindow() {
        close(&signInWindow)
    }

    // MARK: - Onboarding window

    private func showOnboardingWindow() {
        guard onboardingWindow == nil else { return }

        NSApp.setActivationPolicy(.regular)

        // .resizable so users with large system text settings can grow the
        // window. A content min size stops it shrinking below where the
        // primary action (Continue) still fits.
        let window = makeWindow(
            contentRect: NSRect(x: 0, y: 0, width: 580, height: 600),
            styleMask: [.titled, .closable, .resizable, .fullSizeContentView]
        )
        window.contentMinSize = NSSize(width: 580, height: 560)
        window.titleVisibility = .hidden

        let root = OnboardingView(onComplete: { [weak self] in
            self?.reconcile()
        })
        .environmentObject(services.permissions)
        .environmentObject(services.onboarding)
        .environmentObject(services.languagePreference)
        .environmentObject(services.profileStore)
        .environmentObject(services.auth)
        .environmentObject(services.onboardingTelemetry)

        window.contentViewController = NSHostingController(rootView: root)
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        onboardingWindow = window
    }

    private func closeOnboardingWindow() {
        close(&onboardingWindow)
    }

    // MARK: - Floating panel

    /// Builds the panel without putting it on screen. It has to exist — it owns
    /// the `MeetingSession` and the whole recording surface — but showing it is
    /// a separate decision (`applyLaunchBehavior`, the hotkey, the menu bar, or
    /// the Capture button).
    private func buildFloatingPanel() {
        // Idempotent — re-entrant from the auth observer is normal.
        guard panel == nil else { return }

        // Dock icon presence tracks share visibility. When Nod is visible in
        // shares, show the icon so a user who hid the panel via the toggle
        // hotkey can click it to bring the panel back (see
        // AppDelegate.applicationShouldHandleReopen). In stealth mode the panel
        // is excluded from screen captures, so a Dock icon (and ⌘-Tab entry)
        // would leak Nod's presence anyway — go accessory to match.
        NSApp.setActivationPolicy(services.panelSharing.visibleWhenSharing ? .regular : .accessory)

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
            actionItemStore: services.actionItemStore,
            language: services.languagePreference,
            auth: services.auth,
            profileStore: services.profileStore,
            outbox: services.meetingOutbox,
            modeStore: services.modeStore,
            screenExclusions: services.screenExclusions
        )

        self.meetingSession = meetingSession

        let content = ContentView(
            onPreferredWidthChange: { [weak self] width in self?.panel?.setWidth(to: width) },
            onRedrawNeeded: { [weak self] in self?.panel?.forceRedraw() }
        )
        .environmentObject(meetingSession)
        .environmentObject(services.audioCapture)
        .environmentObject(services.languagePreference)
        .environmentObject(services.consent)
        .environmentObject(services.entitlements)
        .environmentObject(services.updateGate)
        .environmentObject(services.hotkeys)
        .environmentObject(services.panelSharing)
        .environmentObject(services.modeStore)

        // Start at the compact width — the panel launches idle. ContentView
        // reports the desired width as the layout changes and the panel
        // animates the frame, keeping the left edge anchored.
        let panel = FloatingPanel(
            contentRect: NSRect(x: 0, y: 0, width: PanelWidth.compact, height: 560),
            content: content
        )
        panel.sharingType = services.panelSharing.sharingType
        panel.positionOnLeftCenter()
        self.panel = panel

        startDetecting(for: meetingSession)
    }

    private func closeFloatingPanel() {
        panel?.close()
        panel = nil
        stopDetecting()
        meetingSession = nil
    }

    // MARK: - Meeting detection

    private func startDetecting(for session: MeetingSession) {
        let detector = MeetingDetector(
            session: session,
            exclusions: services.screenExclusions,
            preference: services.meetingDetection
        )
        self.detector = detector
        detectionObserver = detector.$invitation.sink { [weak self] app in
            guard let app else { return self?.closeDetectionCard() ?? () }
            self?.showDetectionCard(for: app)
        }
        detector.start()
    }

    private func stopDetecting() {
        detectionObserver = nil
        detector?.stop()
        detector = nil
        closeDetectionCard()
    }

    private func closeDetectionCard() {
        detectionCard?.close()
        detectionCard = nil
    }

    /// The card is rebuilt per call rather than kept around and re-bound: it
    /// appears a few times a day at most, and a window held open all day to
    /// save one allocation is the wrong trade.
    private func showDetectionCard(for app: ConferencingApp) {
        closeDetectionCard()
        guard let detector else { return }

        let card = FloatingPanel(
            contentRect: NSRect(origin: .zero, size: MeetingDetectedCard.initialWindowSize),
            content: MeetingDetectedCard(
                app: app,
                onStart: { [weak detector] in detector?.accept() },
                onDismiss: { [weak detector] in detector?.decline() },
                onMute: { [weak detector] in detector?.mute(app) }
            ),
            sizesToContent: true
        )
        // Never in a screen share, whatever the panel's own preference is: this
        // window names the call the user is in, on top of that same call.
        card.sharingType = .none
        // Lay the content out before anchoring: the panel is created at a
        // placeholder height and only takes its real one once hosted.
        card.contentViewController?.view.layoutSubtreeIfNeeded()
        card.positionOnTopRight()
        card.orderFrontRegardless()
        detectionCard = card
    }

    /// Pick what the next capture is and bring the panel forward. It stops
    /// there on purpose: consent, the permission prompts and the language check
    /// live in the panel, and no shortcut into recording may skip them. A kind
    /// arriving mid-recording is ignored — the streams are already chosen.
    func capture(_ kind: SessionKind) {
        if meetingSession?.meeting == .idle {
            meetingSession?.selectedKind = kind
        }
        revealPanel()
    }

    /// Settings renders inside the main window as one of its sections, so it is
    /// built here (where the service graph lives) and handed over as a view.
    private var settingsPane: AnyView {
        AnyView(
            SettingsView(
                hotkey: services.hotkeys,
                profileStore: services.profileStore,
                panelSharing: services.panelSharing,
                launchBehavior: services.launchBehavior,
                billing: services.billing,
                entitlements: services.entitlements,
                granolaImporter: services.granolaImporter,
                auth: services.auth,
                accountExport: services.accountExport,
                connections: services.connections,
                modeStore: services.modeStore,
                referral: services.referral,
                screenExclusions: services.screenExclusions,
                screenContext: services.screenContext,
                meetingDetection: services.meetingDetection
            )
        )
    }

    // MARK: - Main window (issue #14)

    func showMainWindow(focusing meetingID: UUID? = nil) {
        if let existing = mainWindow {
            existing.makeKeyAndOrderFront(nil)
            // MainWindowView is already mounted and observing the
            // `.nodOpenMeetingDetail` notification — its own `.onReceive`
            // handles the navigation push.
            return
        }

        let window = makeWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1040, height: 640),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView]
        )
        window.title = "Nod"
        // The panel is kept out of screen captures unless the user opts in, and
        // this window now opens by itself on launch — a window listing their
        // meeting titles, open actions and unresolved points must follow the
        // same preference, or the first screen-share pops it into the call.
        window.sharingType = services.panelSharing.sharingType

        // First-mount focus is handed in via init — the open-detail
        // notification fires before MainWindowView's `.onReceive` subscribes
        // when the window is being created fresh, so its `.task` reads
        // `initialFocusMeetingID` after the initial refresh instead.
        // No SwiftUI `minWidth/minHeight` on the root on purpose — a SwiftUI min
        // frame makes the root demand 860pt even in a narrower window, and
        // NSHostingView then centers that oversized content, clipping BOTH edges
        // and sliding the left rail off-screen. The size floor is enforced at the
        // window level instead (`contentMinSize`, set after the controller is
        // attached), so the content always fills the window and the rail stays
        // pinned at the leading edge.
        let root = MainWindowView(initialFocusMeetingID: meetingID, settings: settingsPane)
            .environmentObject(services.meetingStore)
            .environmentObject(services.chatStore)
            .environmentObject(services.profileStore)
            .environmentObject(services.entityStore)
            .environmentObject(services.knowledgeStore)
            .environmentObject(services.knowledgeChat)
            .environmentObject(services.knowledgeThreads)
            .environmentObject(services.actionItemStore)
            .environmentObject(services.llmClient)
            .environmentObject(services.languagePreference)
            .environmentObject(services.labelStore)
            .environmentObject(services.entitlements)
            .environmentObject(services.hotkeys)
            .environmentObject(services.settingsFocus)
            .environmentObject(services.screenContext)

        let hosting = NSHostingController(rootView: root)
        // Don't let the hosting controller derive the window's min/max size from
        // the SwiftUI content — it would override `contentMinSize` (and, with no
        // SwiftUI min frame, let the window shrink to a cramped, unusable width).
        // We own the window sizing; the floor below is authoritative.
        hosting.sizingOptions = []
        window.contentViewController = hosting
        // With the hosting controller no longer sizing the window, set the opening
        // size and the floor explicitly AFTER attaching it (assigning a
        // contentViewController resets the window's size constraints). Three
        // columns now: 1240×760 opens comfortably; 980×560 is where the sidebar,
        // the centre column, and the context column all still work.
        window.setContentSize(NSSize(width: 1240, height: 760))
        window.contentMinSize = NSSize(width: 980, height: 560)
        window.center()
        window.makeKeyAndOrderFront(nil)
        mainWindow = window
    }

    func closeMainWindow() {
        close(&mainWindow)
        // Only sign-out reaches here (a user close goes through
        // `windowWillClose`), so the next account gets its own launch surface.
        didApplyLaunchBehavior = false
    }

    // MARK: - NSWindowDelegate

    /// Hard floor on the History window's size. `contentMinSize` proved
    /// unreliable under `fullSizeContentView` + an `NSHostingView` (the window
    /// could still be dragged narrower, hiding the rail), so the minimum is
    /// enforced here — AppKit calls this on every live-resize tick. Scoped to the
    /// History window so the fixed-size sign-in / onboarding windows are
    /// untouched. Runs on the main thread, so the isolated state is safe to read.
    nonisolated func windowWillResize(_ sender: NSWindow, to frameSize: NSSize) -> NSSize {
        MainActor.assumeIsolated {
            guard sender === mainWindow else { return frameSize }
            return NSSize(width: max(frameSize.width, 980), height: max(frameSize.height, 560))
        }
    }

    nonisolated func windowWillClose(_ notification: Notification) {
        let closed = notification.object as AnyObject?
        Task { @MainActor [weak self] in
            guard let self else { return }
            if closed === signInWindow {
                signInWindow = nil
            } else if closed === onboardingWindow {
                onboardingWindow = nil
            } else if closed === mainWindow {
                // The main window is auxiliary to the panel — closing it
                // doesn't trigger any reconciliation; capture keeps running.
                mainWindow = nil
                return
            }
            // User-initiated close of the only UI: re-open whichever window
            // matches the current state. closing the sign-in window with no
            // session would otherwise leave the app with zero UI.
            reconcile()
        }
    }
}
