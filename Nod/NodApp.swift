import AppKit
import Sparkle
import Supabase
import SwiftUI

@main
struct NodApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        Settings {
            EmptyView()
        }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate, NSMenuDelegate {
    private var panel: NSPanel?
    private var onboardingWindow: NSWindow?
    private var signInWindow: NSWindow?
    private var historyWindow: NSWindow?
    private var settingsWindow: NSWindow?
    private var permissions: PermissionManager?
    private var onboarding: OnboardingState?
    private var audioCapture: AudioCaptureService?
    private var llmClient: OpenRouterClient?
    private var transcriptStore: TranscriptStore?
    private var languagePreference: LanguagePreference?
    private var supabase: SupabaseClient?
    private var auth: AuthService?
    private var consent: ConsentPreference?
    private var meetingStore: MeetingStore?
    private var profileStore: ProfileStore?
    private var chatStore: ChatStore?
    private var entityStore: EntityStore?
    private var knowledgeStore: KnowledgeStore?
    private var labelStore: LabelStore?
    private var panelSharing: PanelSharingPreference?
    private var authObserveTask: Task<Void, Never>?
    private var statusObserveTask: Task<Void, Never>?
    private var panelSharingObserveTask: Task<Void, Never>?
    private var pendingCallbackURLs: [URL] = []
    private var statusItem: NSStatusItem?

    // Sparkle owns its own lifecycle once `startingUpdater: true`. We retain
    // the controller so the automatic check timer (SUScheduledCheckInterval)
    // keeps firing for the life of the app.
    private let updaterController = SPUStandardUpdaterController(
        startingUpdater: true,
        updaterDelegate: nil,
        userDriverDelegate: nil
    )

    func applicationDidFinishLaunching(_ notification: Notification) {
        setupStatusItem()

        // Suggest reply reuses the on-screen pill's notification path (ContentView observes it).
        HotkeyManager.shared.onTrigger = { [weak self] action in
            switch action {
            case .suggestReply:
                NotificationCenter.default.post(name: .nodSuggestHotkey, object: nil)
            case .togglePanel:
                self?.toggleFloatingPanel()
            }
        }

        NotificationCenter.default.addObserver(
            forName: .nodOpenMeetingDetail,
            object: nil,
            queue: nil
        ) { [weak self] note in
            let id = note.userInfo?[Notification.nodMeetingIDKey] as? UUID
            Task { @MainActor in
                guard let self, let id else { return }
                self.showHistoryWindow(focusing: id)
                NSApp.activate(ignoringOtherApps: true)
            }
        }

        NotificationCenter.default.addObserver(forName: .nodOpenSettings, object: nil, queue: nil) { [weak self] _ in
            Task { @MainActor in
                self?.showSettingsWindow()
                NSApp.activate(ignoringOtherApps: true)
            }
        }
        NotificationCenter.default.addObserver(forName: .nodOpenLibrary, object: nil, queue: nil) { [weak self] _ in
            Task { @MainActor in
                self?.showHistoryWindow(focusing: nil)
                NSApp.activate(ignoringOtherApps: true)
            }
        }
        NotificationCenter.default.addObserver(forName: .nodHidePanel, object: nil, queue: nil) { [weak self] _ in
            Task { @MainActor in
                self?.panel?.orderOut(nil)
            }
        }

        let permissions = PermissionManager()
        let onboarding = OnboardingState()
        let audioCapture = AudioCaptureService()
        let languagePreference = LanguagePreference()
        // Supabase client must exist before the LLM client — all LLM traffic
        // is JWT-authenticated through the `llm-proxy` Edge Function (#11).
        // Opt into the new authStateChanges behavior — the SDK emits the
        // locally stored session immediately as `.initialSession`, even if
        // expired, and refreshes in the background. AuthService treats an
        // expired session as nil so the UI doesn't flip to "signed in"
        // with an unusable token. See supabase-swift PR #822.
        let supabase = SupabaseClient(
            supabaseURL: SupabaseConfig.url,
            supabaseKey: SupabaseConfig.anonKey,
            options: SupabaseClientOptions(
                auth: SupabaseClientOptions.AuthOptions(
                    emitLocalSessionAsInitialSession: true
                )
            )
        )
        let auth = AuthService(client: supabase)
        let llmClient = OpenRouterClient(supabase: supabase)
        let transcriptStore = TranscriptStore(client: llmClient, language: languagePreference)
        let consent = ConsentPreference(
            supabase: supabase,
            auth: auth
        )
        let meetingStore = MeetingStore(supabase: supabase)
        let profileStore = ProfileStore(supabase: supabase, auth: auth)
        let chatStore = ChatStore(supabase: supabase, llm: llmClient)
        let entityStore = EntityStore(supabase: supabase)
        let knowledgeStore = KnowledgeStore(llm: llmClient)
        let labelStore = LabelStore(supabase: supabase, auth: auth)
        let panelSharing = PanelSharingPreference()

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
        self.supabase = supabase
        self.auth = auth
        self.consent = consent
        self.meetingStore = meetingStore
        self.profileStore = profileStore
        self.chatStore = chatStore
        self.entityStore = entityStore
        self.knowledgeStore = knowledgeStore
        self.labelStore = labelStore
        self.panelSharing = panelSharing

        panelSharingObserveTask = Task { @MainActor [weak self] in
            // `@Published` fires in willSet, so use the yielded value rather
            // than re-reading the (still-stale) stored property.
            for await visible in panelSharing.$visibleWhenSharing.values {
                self?.panel?.sharingType = visible ? .readOnly : .none
            }
        }

        statusObserveTask = Task { @MainActor [weak self] in
            guard let self, let audioCapture = self.audioCapture else { return }
            for await state in audioCapture.$state.values {
                updateStatusItem(for: state)
            }
        }

        // Observer drives every window transition, including the initial one.
        // Idempotent show*/close* methods make repeat emissions safe.
        authObserveTask = Task { @MainActor [weak self] in
            guard let self, let auth = self.auth else { return }
            var wasSignedIn = false
            for await _ in auth.$session.values {
                let isSignedIn = auth.session != nil
                if wasSignedIn, !isSignedIn {
                    // Sign-out: tear down the recording pipeline AND drop
                    // the per-user caches so the next signed-in user can't
                    // see the previous one's data through the in-memory
                    // store or a stale History window.
                    await stopRecordingServices()
                    self.meetingStore?.clear()
                    self.profileStore?.clear()
                    self.chatStore?.clear()
                    self.labelStore?.clear()
                    closeHistoryWindow()
                    closeSettingsWindow()
                }
                if isSignedIn {
                    // Warm the profile so its prompt context is ready before
                    // the first meeting ends. `load` no-ops once cached.
                    Task { await self.profileStore?.load() }
                    Task { await self.labelStore?.refresh() }
                }
                wasSignedIn = isSignedIn
                reconcileWindows()
            }
        }

        // Drain any URL callbacks that arrived before auth was ready.
        let pending = pendingCallbackURLs
        pendingCallbackURLs.removeAll()
        for url in pending {
            Task { @MainActor in await auth.handleCallback(url) }
        }
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        for url in urls
            where url.scheme?.lowercased() == AuthService.callbackURL.scheme
            && url.host == AuthService.callbackURL.host {
            Log.auth.info("received callback url")
            if let auth = self.auth {
                Task { @MainActor in await auth.handleCallback(url) }
            } else {
                pendingCallbackURLs.append(url)
            }
        }
    }

    private func stopRecordingServices() async {
        await audioCapture?.stop()
        transcriptStore?.stop()
        transcriptStore?.clear()
    }

    private func reconcileWindows() {
        guard let auth, let onboarding else { return }
        if auth.session == nil {
            closeFloatingPanel()
            closeOnboardingWindow()
            showSignInWindow()
        } else if !onboarding.isCompleted {
            closeFloatingPanel()
            closeSignInWindow()
            showOnboardingWindow()
        } else {
            closeSignInWindow()
            closeOnboardingWindow()
            showFloatingPanel()
        }
    }

    private func showSignInWindow() {
        guard let auth, signInWindow == nil else { return }
        NSApp.setActivationPolicy(.regular)

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 420, height: 360),
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

        let root = SignInView().environmentObject(auth)
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

    private func showOnboardingWindow() {
        guard let permissions, let onboarding, let languagePreference, let profileStore, let auth, onboardingWindow == nil else { return }

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
            self?.reconcileWindows()
        })
        .environmentObject(permissions)
        .environmentObject(onboarding)
        .environmentObject(languagePreference)
        .environmentObject(profileStore)
        .environmentObject(auth)

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

    private func showFloatingPanel() {
        // Idempotent — re-entrant from the auth observer is normal.
        guard panel == nil else { return }
        // Surface init-order bugs loudly. The chained `guard let` above used
        // to silently swallow a missing dep — now each absence logs which
        // service didn't land in time for the panel.
        guard let audioCapture else { Log.ui.error("showFloatingPanel: missing audioCapture"); return }
        guard let llmClient else { Log.ui.error("showFloatingPanel: missing llmClient"); return }
        guard let transcriptStore else { Log.ui.error("showFloatingPanel: missing transcriptStore"); return }
        guard let languagePreference else { Log.ui.error("showFloatingPanel: missing languagePreference"); return }
        guard let consent else { Log.ui.error("showFloatingPanel: missing consent"); return }
        guard let meetingStore else { Log.ui.error("showFloatingPanel: missing meetingStore"); return }
        guard let auth else { Log.ui.error("showFloatingPanel: missing auth"); return }
        guard let profileStore else { Log.ui.error("showFloatingPanel: missing profileStore"); return }
        guard let entityStore else { Log.ui.error("showFloatingPanel: missing entityStore"); return }
        guard let knowledgeStore else { Log.ui.error("showFloatingPanel: missing knowledgeStore"); return }
        guard let labelStore else { Log.ui.error("showFloatingPanel: missing labelStore"); return }

        NSApp.setActivationPolicy(.accessory)

        let content = ContentView(
            onPreferredWidthChange: { [weak self] width in self?.panel?.setWidth(to: width) }
        )
        .environmentObject(audioCapture)
        .environmentObject(llmClient)
        .environmentObject(transcriptStore)
        .environmentObject(languagePreference)
        .environmentObject(consent)
        .environmentObject(meetingStore)
        .environmentObject(auth)
        .environmentObject(profileStore)
        .environmentObject(entityStore)
        .environmentObject(knowledgeStore)
        .environmentObject(labelStore)

        // Start at the compact width — the panel launches idle. ContentView
        // reports the desired width as the layout changes and the panel
        // animates the frame, keeping the left edge anchored.
        let panel = FloatingPanel(
            contentRect: NSRect(x: 0, y: 0, width: PanelWidth.compact, height: 560),
            content: content
        )
        panel.sharingType = panelSharing?.sharingType ?? .none
        panel.positionOnLeftCenter()
        panel.orderFrontRegardless()
        self.panel = panel
    }

    private func closeFloatingPanel() {
        panel?.close()
        panel = nil
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    // MARK: - Status bar item

    private func setupStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        let menu = NSMenu()
        menu.delegate = self
        item.menu = menu
        statusItem = item
        updateStatusItem(for: .idle)
    }

    /// Surfaces capture state in the menu bar so a recording stays visible
    /// when the panel is hidden via the toggle hotkey.
    private func updateStatusItem(for state: CaptureState) {
        guard let button = statusItem?.button else { return }
        let (dotColor, toolTip): (NSColor?, String)
        switch state {
        case .idle: (dotColor, toolTip) = (nil, "Nod")
        case .capturing: (dotColor, toolTip) = (.systemRed, "Nod — Recording")
        case .paused: (dotColor, toolTip) = (.systemOrange, "Nod — Paused")
        }
        button.image = Self.statusItemImage(dotColor: dotColor)
        button.toolTip = toolTip
    }

    private static func statusItemImage(dotColor: NSColor?) -> NSImage? {
        guard let glyph = NSImage(named: "NTemplate") else { return nil }
        let size = NSSize(width: 18, height: 18)

        // Idle: hand the template glyph to macOS untouched so it tints for
        // light/dark menu bars and selection automatically — the colourful
        // mesh badge belongs on the app icon, not the menu bar.
        guard let dotColor else {
            glyph.size = size
            glyph.isTemplate = true
            return glyph
        }

        // Recording / paused: the status dot is colour-coded, so the image
        // can't be a template (template tinting would flatten the dot to one
        // colour). Draw the glyph in the menu-bar foreground colour ourselves,
        // then the dot on top.
        let composed = NSImage(size: size)
        composed.lockFocus()
        let rect = NSRect(origin: .zero, size: size)
        glyph.draw(in: rect, from: .zero, operation: .sourceOver, fraction: 1)
        NSColor.white.withAlphaComponent(0.92).set()
        rect.fill(using: .sourceAtop)
        let diameter: CGFloat = 8
        let dot = NSBezierPath(ovalIn: NSRect(x: size.width - diameter, y: 0, width: diameter, height: diameter).insetBy(dx: 1, dy: 1))
        dotColor.setFill()
        dot.fill()
        NSColor.white.withAlphaComponent(0.9).setStroke()
        dot.lineWidth = 1
        dot.stroke()
        composed.unlockFocus()
        composed.isTemplate = false
        return composed
    }

    @objc private func toggleFloatingPanel() {
        guard let panel else { return }
        if panel.isVisible {
            panel.orderOut(nil)
        } else {
            panel.orderFrontRegardless()
        }
    }

    @objc private func signOutAction() {
        Task { @MainActor in await self.auth?.signOut() }
    }

    @objc private func showSignInAction() {
        reconcileWindows()
        NSApp.activate(ignoringOtherApps: true)
    }

    @objc private func showHistoryAction() {
        showHistoryWindow(focusing: nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    @objc private func showSettingsAction() {
        showSettingsWindow()
        NSApp.activate(ignoringOtherApps: true)
    }

    // MARK: - Settings window

    private func showSettingsWindow() {
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
        window.contentViewController = NSHostingController(rootView: SettingsView(profileStore: profileStore, panelSharing: panelSharing))
        window.makeKeyAndOrderFront(nil)
        settingsWindow = window
    }

    private func closeSettingsWindow() {
        if let window = settingsWindow {
            window.delegate = nil
            window.close()
        }
        settingsWindow = nil
    }

    // MARK: - History window (issue #14)

    private func showHistoryWindow(focusing meetingID: UUID? = nil) {
        guard let meetingStore, let chatStore, let profileStore, let entityStore,
              let knowledgeStore, let llmClient, let languagePreference, let labelStore else { return }

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
            .environmentObject(meetingStore)
            .environmentObject(chatStore)
            .environmentObject(profileStore)
            .environmentObject(entityStore)
            .environmentObject(knowledgeStore)
            .environmentObject(llmClient)
            .environmentObject(languagePreference)
            .environmentObject(labelStore)

        window.contentViewController = NSHostingController(rootView: root)
        window.makeKeyAndOrderFront(nil)
        historyWindow = window
    }

    private func closeHistoryWindow() {
        if let window = historyWindow {
            window.delegate = nil
            window.close()
        }
        historyWindow = nil
    }

    private func displayName(for user: User) -> String {
        user.profileDisplayName
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
            reconcileWindows()
        }
    }

    // MARK: - NSMenuDelegate

    nonisolated func menuNeedsUpdate(_ menu: NSMenu) {
        MainActor.assumeIsolated {
            menu.removeAllItems()

            let signedIn = auth?.session != nil

            if let user = auth?.session?.user {
                let name = displayName(for: user)
                let email = user.email ?? ""

                if !name.isEmpty {
                    let nameItem = NSMenuItem(title: name, action: nil, keyEquivalent: "")
                    nameItem.isEnabled = false
                    menu.addItem(nameItem)
                }
                if !email.isEmpty {
                    let attr = NSAttributedString(
                        string: email,
                        attributes: [
                            .font: NSFont.systemFont(ofSize: NSFont.smallSystemFontSize),
                            .foregroundColor: NSColor.secondaryLabelColor
                        ]
                    )
                    let emailItem = NSMenuItem(title: email, action: nil, keyEquivalent: "")
                    emailItem.attributedTitle = attr
                    emailItem.isEnabled = false
                    menu.addItem(emailItem)
                }
                if !name.isEmpty || !email.isEmpty {
                    menu.addItem(.separator())
                }
            }

            if signedIn, let panel = self.panel {
                let toggle = NSMenuItem(
                    title: panel.isVisible ? "Hide Panel" : "Show Panel",
                    action: #selector(toggleFloatingPanel),
                    keyEquivalent: ""
                )
                toggle.target = self
                // Display-only mirror of the binding; the Carbon global hotkey is the real trigger.
                if let (key, mask) = HotkeyManager.shared.combo(for: .togglePanel).menuKeyEquivalent {
                    toggle.keyEquivalent = key
                    toggle.keyEquivalentModifierMask = mask
                }
                menu.addItem(toggle)

                let history = NSMenuItem(
                    title: "Library…",
                    action: #selector(showHistoryAction),
                    // No keyEquivalent — `"h"` defaults to ⌘H which the
                    // system reserves for "Hide Application".
                    keyEquivalent: ""
                )
                history.target = self
                menu.addItem(history)

                let settings = NSMenuItem(
                    title: "Settings…",
                    action: #selector(showSettingsAction),
                    keyEquivalent: ","
                )
                settings.target = self
                menu.addItem(settings)

                menu.addItem(.separator())
            } else if !signedIn {
                let showSignIn = NSMenuItem(
                    title: "Sign In…",
                    action: #selector(showSignInAction),
                    keyEquivalent: ""
                )
                showSignIn.target = self
                menu.addItem(showSignIn)
                menu.addItem(.separator())
            }

            if signedIn {
                let signOut = NSMenuItem(
                    title: "Sign Out",
                    action: #selector(signOutAction),
                    keyEquivalent: ""
                )
                signOut.target = self
                menu.addItem(signOut)
                menu.addItem(.separator())
            }

            let checkForUpdates = NSMenuItem(
                title: "Check for Updates…",
                action: #selector(SPUStandardUpdaterController.checkForUpdates(_:)),
                keyEquivalent: ""
            )
            checkForUpdates.target = updaterController
            menu.addItem(checkForUpdates)
            menu.addItem(.separator())

            let quit = NSMenuItem(
                title: "Quit Nod",
                action: #selector(NSApplication.terminate(_:)),
                keyEquivalent: "q"
            )
            menu.addItem(quit)
        }
    }
}

extension Notification.Name {
    /// Posted by ContentView once a freshly-ended meeting has been
    /// summarised and persisted. AppDelegate opens/focuses the History
    /// window; HistoryView pushes the meeting's detail view onto its
    /// NavigationStack. `userInfo` carries the meeting id under
    /// `Notification.nodMeetingIDKey`.
    static let nodOpenMeetingDetail = Notification.Name("nod.history.openMeetingDetail")

    /// Posted by the panel's overflow (•••) menu.
    static let nodOpenSettings = Notification.Name("nod.app.openSettings")
    static let nodOpenLibrary = Notification.Name("nod.app.openLibrary")
    static let nodHidePanel = Notification.Name("nod.app.hidePanel")
}

extension Notification {
    static let nodMeetingIDKey = "meetingID"
}
