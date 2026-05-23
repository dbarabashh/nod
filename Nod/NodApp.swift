import SwiftUI
import AppKit
import Supabase

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
    private var permissions: PermissionManager?
    private var onboarding: OnboardingState?
    private var audioCapture: AudioCaptureService?
    private var llmClient: OpenRouterClient?
    private var transcriptStore: TranscriptStore?
    private var languagePreference: LanguagePreference?
    private var upcomingMeetings: UpcomingMeetingService?
    private var supabase: SupabaseClient?
    private var auth: AuthService?
    private var authObserveTask: Task<Void, Never>?
    private var pendingCallbackURLs: [URL] = []
    private var statusItem: NSStatusItem?

    func applicationDidFinishLaunching(_ notification: Notification) {
        setupStatusItem()

        let permissions = PermissionManager()
        let onboarding = OnboardingState()
        let audioCapture = AudioCaptureService()
        let llmClient = OpenRouterClient()
        let languagePreference = LanguagePreference()
        let transcriptStore = TranscriptStore(client: llmClient, language: languagePreference)
        let upcomingMeetings = UpcomingMeetingService()
        let supabase = SupabaseClient(
            supabaseURL: SupabaseConfig.url,
            supabaseKey: SupabaseConfig.anonKey
        )
        let auth = AuthService(client: supabase)
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
        self.supabase = supabase
        self.auth = auth

        // Observer drives every window transition, including the initial one.
        // Idempotent show*/close* methods make repeat emissions safe.
        authObserveTask = Task { @MainActor [weak self] in
            guard let self, let auth = self.auth else { return }
            var wasSignedIn = false
            for await _ in auth.$session.values {
                let isSignedIn = auth.session != nil
                if wasSignedIn && !isSignedIn {
                    await self.stopRecordingServices()
                }
                wasSignedIn = isSignedIn
                self.reconcileWindows()
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
        guard let permissions, let onboarding, onboardingWindow == nil else { return }

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
        window.delegate = self
        window.center()

        let root = OnboardingView(onComplete: { [weak self] in
            self?.reconcileWindows()
        })
        .environmentObject(permissions)
        .environmentObject(onboarding)

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
        guard let audioCapture, let llmClient, let transcriptStore, let languagePreference, let upcomingMeetings, panel == nil else { return }
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
        if let button = item.button, let image = NSImage(named: "NodLogo") {
            image.size = NSSize(width: 18, height: 18)
            button.image = image
            button.toolTip = "Nod"
        }
        let menu = NSMenu()
        menu.delegate = self
        item.menu = menu
        statusItem = item
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

    private func displayName(for user: User) -> String {
        let metadata = user.userMetadata
        for key in ["full_name", "name", "user_name"] {
            if let value = metadata[key]?.stringValue, !value.isEmpty {
                return value
            }
        }
        return ""
    }

    // MARK: - NSWindowDelegate

    nonisolated func windowWillClose(_ notification: Notification) {
        let closed = notification.object as AnyObject?
        Task { @MainActor [weak self] in
            guard let self else { return }
            if closed === self.signInWindow {
                self.signInWindow = nil
            } else if closed === self.onboardingWindow {
                self.onboardingWindow = nil
            }
            // User-initiated close of the only UI: re-open whichever window
            // matches the current state. closing the sign-in window with no
            // session would otherwise leave the app with zero UI.
            self.reconcileWindows()
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
                menu.addItem(toggle)
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

            let quit = NSMenuItem(
                title: "Quit Nod",
                action: #selector(NSApplication.terminate(_:)),
                keyEquivalent: "q"
            )
            menu.addItem(quit)
        }
    }
}
