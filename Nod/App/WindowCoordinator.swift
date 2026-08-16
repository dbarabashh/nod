import AppKit
import Combine
import SwiftUI

/// Owns every window the app can show — sign-in, onboarding, the floating
/// panel, Library, Settings — and the reconciliation rule that decides which
/// of the three primary surfaces matches the current auth/onboarding state.
@MainActor
final class WindowCoordinator: NSObject, NSWindowDelegate {
    private let services: AppServices
    /// The capture surface: a notch hanging off the menu bar.
    private let notch = NotchController()
    /// Watches for a call starting and ending. Lives with the notch's session,
    /// which is the thing it can act on.
    private var detector: MeetingDetector?
    private var schedule: ScheduledMeetingWatcher?
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
            closeNotch()
            closeOnboardingWindow()
            showSignInWindow()
        } else if !services.onboarding.isCompleted {
            closeNotch()
            closeSignInWindow()
            showOnboardingWindow()
        } else {
            closeSignInWindow()
            closeOnboardingWindow()
            buildNotch()
            applyLaunchBehavior()
        }
    }

    /// What launch puts on screen. Opening the app is not the same as asking to
    /// capture, so the notch only opens up when the user chose that — or asks
    /// for it later by hotkey, menu bar, or the Capture button.
    ///
    /// Runs once per signed-in run: the auth publisher emits on every token
    /// refresh, and a surface the user folded away must stay folded.
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

    /// The toggle hotkey and the menu-bar item: pull the notch open, or fold it
    /// back. The surface itself is always on screen — at rest it is the bare
    /// cut-out — so there is nothing to show or hide, only to open or close.
    func toggleFloatingPanel() {
        notch.toggleOpen()
    }

    /// Open the capture surface. The Dock re-open path and the main window's
    /// way back; never creates the notch, because `reconcile` has already
    /// ensured the right surface exists.
    func revealPanel() {
        notch.open()
    }

    func setPanelVisibleWhenSharing(_ visible: Bool) {
        notch.setSharing(visible ? .readOnly : .none)
        mainWindow?.sharingType = visible ? .readOnly : .none
        syncActivationPolicy()
    }

    /// Dock icon and ⌘-Tab entry follow whichever surface is actually up.
    ///
    /// A notch-only session in stealth stays `.accessory`: excluding the surface
    /// from captures is pointless if the Dock still announces Nod. A main window
    /// the user opened is not stealth — without `.regular` it has no Dock tile
    /// and no ⌘-Tab entry, so clicking any other app leaves the menu-bar item as
    /// the only way back, and `applicationShouldHandleReopen` can never fire.
    ///
    /// Sign-in / onboarding set `.regular` directly and are not routed here.
    private func syncActivationPolicy() {
        if mainWindow != nil {
            NSApp.setActivationPolicy(.regular)
        } else if notch.isBuilt {
            NSApp.setActivationPolicy(services.panelSharing.visibleWhenSharing ? .regular : .accessory)
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
        .environmentObject(services.modeStore)
        .environmentObject(services.emailPreferences)
        .environmentObject(services.integrations)

        window.contentViewController = NSHostingController(rootView: root)
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        onboardingWindow = window
    }

    private func closeOnboardingWindow() {
        close(&onboardingWindow)
    }

    // MARK: - Notch

    /// Builds the capture surface. At rest it is the bare cut-out, so putting it
    /// on screen costs the user nothing — opening it up is the separate decision
    /// (`applyLaunchBehavior`, the hotkey, the menu bar, a detected call).
    private func buildNotch() {
        // Idempotent — re-entrant from the auth observer is normal.
        guard !notch.isBuilt else { return }

        // Dock icon presence tracks share visibility. When Nod is visible in
        // shares, show the icon so a user can click it to bring the surface
        // forward (see AppDelegate.applicationShouldHandleReopen). In stealth
        // mode the surface is excluded from screen captures, so a Dock icon (and
        // ⌘-Tab entry) would leak Nod's presence anyway — go accessory to match.
        syncActivationPolicy()

        // One session per notch — created with it, dropped on sign-out teardown,
        // so a mid-recording sign-out can't leak a stale capture state into the
        // next user's surface.
        let meetingSession = MeetingSession(
            audioCapture: services.audioCapture,
            store: services.transcriptStore,
            llm: services.llmClient,
            meetingStore: services.meetingStore,
            entityStore: services.entityStore,
            knowledgeStore: services.knowledgeStore,
            actionItemStore: services.actionItemStore,
            language: services.languagePreference,
            proactivity: services.proactivityPreference,
            auth: services.auth,
            profileStore: services.profileStore,
            outbox: services.meetingOutbox,
            modeStore: services.modeStore,
            screenExclusions: services.screenExclusions,
            calendar: services.calendar,
            analytics: services.productAnalytics,
            proposalRaiser: ProposalRaiser(
                proposals: services.actionProposals,
                integrations: services.integrations,
                organizations: services.organizations,
                meetings: services.meetingStore
            ),
            rooms: services.rooms
        )

        // The detector belongs to the session it can act on, and the notch
        // renders its invitation as one of its own states — so unlike the old
        // detection card there is no second window to raise, position and tear
        // down for every call.
        let detector = MeetingDetector(
            session: meetingSession,
            exclusions: services.screenExclusions,
            preference: services.meetingDetection
        )
        self.detector = detector

        // The calendar's own offer, raised from the invitation rather than from
        // anything running on the Mac — see `ScheduledMeetingWatcher`. It starts
        // and stops itself from the Settings switch, so nothing starts it here.
        let schedule = ScheduledMeetingWatcher(calendar: services.calendar, session: meetingSession, rooms: services.rooms)
        self.schedule = schedule

        // One owner of "should we ask?", fed by both sources — see `MeetingOffers`.
        let offers = MeetingOffers(
            detector: detector,
            schedule: schedule,
            session: meetingSession,
            preference: services.meetingDetection
        )

        notch.build(
            model: NotchModel(
                session: meetingSession,
                offers: offers,
                audioCapture: services.audioCapture,
                rooms: services.rooms,
                calendar: services.calendar,
                language: services.languagePreference,
                updateGate: services.updateGate,
                playback: services.demoPlayback,
                captureSurface: services.captureSurface,
                panelSharing: services.panelSharing,
                profiles: services.profileStore,
                briefing: CallBriefing(
                    meetings: services.meetingStore,
                    actionItems: services.actionItemStore,
                    calendar: services.calendar
                ),
                consent: services.consent,
                entitlements: services.entitlements,
                billing: services.billing,
                meetingStore: services.meetingStore
            ),
            cards: NotchCardEnvironment(
                integrations: services.integrations,
                actionItems: services.actionItemStore,
                drafts: services.taskDrafts,
                meetingGrants: services.meetingGrants,
                organizations: services.organizations,
                meetings: services.meetingStore
            ),
            sharing: services.panelSharing.sharingType
        )

        detector.start()
    }

    private func closeNotch() {
        notch.teardown()
        detector?.stop()
        detector = nil
        schedule?.stop()
        schedule = nil
    }

    /// Settings renders inside the main window as one of its sections, so it is
    /// built here (where the service graph lives) and handed over as a view.
    private var settingsPane: AnyView {
        AnyView(
            SettingsView(
                hotkey: services.hotkeys,
                profileStore: services.profileStore,
                panelSharing: services.panelSharing,
                proactivity: services.proactivityPreference,
                launchBehavior: services.launchBehavior,
                billing: services.billing,
                entitlements: services.entitlements,
                granolaImporter: services.granolaImporter,
                auth: services.auth,
                accountExport: services.accountExport,
                connections: services.connections,
                integrations: services.integrations,
                organizations: services.organizations,
                modeStore: services.modeStore,
                referral: services.referral,
                emailPreferences: services.emailPreferences,
                productAnalytics: services.productAnalytics,
                screenExclusions: services.screenExclusions,
                screenContext: services.screenContext,
                meetingDetection: services.meetingDetection,
                calendar: services.calendar,
                demoPlayback: services.demoPlayback,
                captureSurface: services.captureSurface,
                audioCapture: services.audioCapture
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
        // The title still feeds the Window menu, ⌘-Tab and Mission Control, but
        // older macOS draws it in the transparent titlebar while macOS 26 does
        // not — hide it explicitly so every version looks the same.
        window.title = "Nod"
        window.titleVisibility = .hidden
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
        let root = CalendarPromptHost(
            onboarding: services.onboarding,
            integrations: services.integrations,
            email: services.emailPreferences
        ) {
            EmailConsentPromptHost(preferences: services.emailPreferences) {
                MainWindowView(initialFocusMeetingID: meetingID, settings: settingsPane)
                    .environmentObject(services.meetingStore)
                    .environmentObject(services.chatStore)
                    .environmentObject(services.profileStore)
                    .environmentObject(services.entityStore)
                    .environmentObject(services.knowledgeStore)
                    .environmentObject(services.knowledgeChat)
                    .environmentObject(services.knowledgeThreads)
                    .environmentObject(services.actionItemStore)
                    .environmentObject(services.integrations)
                    .environmentObject(services.actionProposals)
                    .environmentObject(services.taskDrafts)
                    .environmentObject(services.llmClient)
                    .environmentObject(services.languagePreference)
                    .environmentObject(services.labelStore)
                    .environmentObject(services.meetingGrants)
                    .environmentObject(services.organizations)
                    .environmentObject(services.entitlements)
                    .environmentObject(services.hotkeys)
                    .environmentObject(services.settingsFocus)
                    .environmentObject(services.screenContext)
                    .environmentObject(services.summaryRegeneration)
                    .environmentObject(services.productAnalytics)
                    .environmentObject(services.demoPlayback)
            }
        }

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
        syncActivationPolicy()
    }

    func closeMainWindow() {
        close(&mainWindow)
        syncActivationPolicy()
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
                // Back to whatever the panel alone warrants — a stealth session
                // must not keep the Dock tile the main window earned.
                syncActivationPolicy()
                return
            }
            // User-initiated close of the only UI: re-open whichever window
            // matches the current state. closing the sign-in window with no
            // session would otherwise leave the app with zero UI.
            reconcile()
        }
    }
}
