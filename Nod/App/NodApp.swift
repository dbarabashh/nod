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

/// Bootstrap only: builds the service graph, the window coordinator, and the
/// status item, wires the cross-cutting observers, and routes URL callbacks.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    /// nil only before `applicationDidFinishLaunching` ran — every code path
    /// that can fire earlier (URL callbacks) queues instead of touching it.
    private var services: AppServices?
    private var windows: WindowCoordinator?
    private var statusBar: StatusItemController?
    private var authObserveTask: Task<Void, Never>?
    private var statusObserveTask: Task<Void, Never>?
    private var panelSharingObserveTask: Task<Void, Never>?
    private var pendingCallbackURLs: [URL] = []

    // Sparkle owns its own lifecycle once `startingUpdater: true`. We retain
    // the controller so the automatic check timer (SUScheduledCheckInterval)
    // keeps firing for the life of the app.
    private let updaterController = SPUStandardUpdaterController(
        startingUpdater: true,
        updaterDelegate: nil,
        userDriverDelegate: nil
    )

    func applicationDidFinishLaunching(_ notification: Notification) {
        let services = AppServices.make()
        let windows = WindowCoordinator(services: services)
        let statusBar = StatusItemController(
            services: services,
            windows: windows,
            updaterController: updaterController
        )
        self.services = services
        self.windows = windows
        self.statusBar = statusBar

        // Suggest reply reuses the on-screen pill's notification path (ContentView observes it).
        services.hotkeys.onTrigger = { [weak windows] action in
            switch action {
            case .suggestReply:
                NotificationCenter.default.post(name: .nodSuggestHotkey, object: nil)
            case .togglePanel:
                windows?.toggleFloatingPanel()
            }
        }

        NotificationCenter.default.addObserver(
            forName: .nodOpenMeetingDetail,
            object: nil,
            queue: nil
        ) { [weak windows] note in
            let id = note.userInfo?[Notification.nodMeetingIDKey] as? UUID
            Task { @MainActor in
                guard let windows, let id else { return }
                windows.showHistoryWindow(focusing: id)
                NSApp.activate(ignoringOtherApps: true)
            }
        }

        NotificationCenter.default.addObserver(forName: .nodOpenSettings, object: nil, queue: nil) { [weak windows] _ in
            Task { @MainActor in
                windows?.showSettingsWindow()
                NSApp.activate(ignoringOtherApps: true)
            }
        }
        NotificationCenter.default.addObserver(forName: .nodOpenModes, object: nil, queue: nil) { [weak windows] _ in
            Task { @MainActor in
                windows?.showSettingsWindow(focusModes: true)
                NSApp.activate(ignoringOtherApps: true)
            }
        }
        NotificationCenter.default.addObserver(forName: .nodOpenLibrary, object: nil, queue: nil) { [weak windows] _ in
            Task { @MainActor in
                windows?.showHistoryWindow(focusing: nil)
                NSApp.activate(ignoringOtherApps: true)
            }
        }
        // Upsell buttons (and the post-checkout deep link) route here to open
        // Settings on the Subscription tab.
        NotificationCenter.default.addObserver(forName: .nodOpenSubscription, object: nil, queue: nil) { [weak windows] _ in
            Task { @MainActor in
                windows?.showSettingsWindow(focusSubscription: true)
                NSApp.activate(ignoringOtherApps: true)
            }
        }
        NotificationCenter.default.addObserver(forName: .nodHidePanel, object: nil, queue: nil) { [weak windows] _ in
            Task { @MainActor in
                windows?.hidePanel()
            }
        }
        NotificationCenter.default.addObserver(forName: .nodCheckForUpdates, object: nil, queue: nil) { [weak self] _ in
            Task { @MainActor in
                self?.updaterController.checkForUpdates(nil)
            }
        }
        NotificationCenter.default.addObserver(forName: .nodDeviceConflict, object: nil, queue: nil) { _ in
            Task { @MainActor in
                await services.auth.forceSignOut(
                    reason: "Signed out — this account is being used on another device."
                )
            }
        }
        // Re-resolve the entitlement whenever the app regains focus — this is
        // how a plan bought in the browser checkout (Paddle webhook → DB) shows
        // up here without the user restarting Nod.
        NotificationCenter.default.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: nil) { _ in
            Task { @MainActor in
                guard services.auth.session != nil else { return }
                await services.entitlements.refresh()
                // Retry any meeting still stuck in the outbox now that the app
                // (and likely the network) is active again — scoped to the
                // signed-in user so a previous account's rows aren't re-pushed.
                if let userID = services.auth.currentSupabaseSession?.user.id {
                    await services.meetingOutbox.flush(using: services.meetingStore, userID: userID)
                    let pending = await services.meetingOutbox.pendingCompletedMeetings(for: userID)
                    services.meetingStore.setUnsyncedMeetings(pending)
                }
            }
        }

        Task { await services.updateGate.check() }

        panelSharingObserveTask = Task { @MainActor [weak windows] in
            // `@Published` fires in willSet, so use the yielded value rather
            // than re-reading the (still-stale) stored property.
            for await visible in services.panelSharing.$visibleWhenSharing.values {
                windows?.setPanelVisibleWhenSharing(visible)
            }
        }

        statusObserveTask = Task { @MainActor [weak statusBar] in
            for await state in services.audioCapture.$state.values {
                statusBar?.update(for: state)
            }
        }

        // Observer drives every window transition, including the initial one.
        // Idempotent show*/close* methods inside reconcile make repeat
        // emissions safe.
        authObserveTask = Task { @MainActor [weak self] in
            var wasSignedIn = false
            for await _ in services.auth.$session.values {
                guard let self, let windows = self.windows else { return }
                let isSignedIn = services.auth.session != nil
                if wasSignedIn, !isSignedIn {
                    // Sign-out: tear down the recording pipeline AND drop
                    // the per-user caches so the next signed-in user can't
                    // see the previous one's data through the in-memory
                    // store or a stale History window.
                    await stopRecordingServices()
                    services.meetingStore.clear()
                    services.profileStore.clear()
                    services.chatStore.clear()
                    services.labelStore.clear()
                    services.entitlements.clear()
                    windows.closeHistoryWindow()
                    windows.closeSettingsWindow()
                }
                if isSignedIn {
                    // Single-device lock: claim this device's slot now so a
                    // blocked device is signed out immediately (the claim
                    // broadcasts .nodDeviceConflict on a 403) rather than only
                    // failing once the first proxy call lands mid-onboarding.
                    Task { @MainActor in
                        do { try await services.llmClient.claimDevice() } catch { Log.auth.error(
                            "device claim failed: \(error.localizedDescription)"
                        ) }
                    }
                    // Replay the durable meeting outbox: push anything that
                    // didn't reach the server before the last quit / crash /
                    // app update. `recoverInterruptedMeetings` first promotes any
                    // meeting left mid-recording to a terminal placeholder recap
                    // (safe here — a fresh sign-in has no live recording). Scoped
                    // to THIS user so another account's rows aren't pushed under
                    // this session (they'd RLS-reject and loop forever).
                    if let userID = services.auth.currentSupabaseSession?.user.id {
                        Task {
                            await services.meetingOutbox.recoverInterruptedMeetings()
                            await services.meetingOutbox.flush(using: services.meetingStore, userID: userID)
                            let pending = await services.meetingOutbox.pendingCompletedMeetings(for: userID)
                            await MainActor.run { services.meetingStore.setUnsyncedMeetings(pending) }
                        }
                    }
                    // Warm the profile so its prompt context is ready before
                    // the first meeting ends. `load` no-ops once cached.
                    Task { await services.profileStore.load() }
                    Task { await services.labelStore.refresh() }
                    Task { await services.entitlements.refresh() }
                    Task { await services.billing.loadPrices() }
                }
                wasSignedIn = isSignedIn
                windows.reconcile()
            }
        }

        // Drain any URL callbacks that arrived before auth was ready.
        let pending = pendingCallbackURLs
        pendingCallbackURLs.removeAll()
        for url in pending {
            Task { @MainActor in await services.auth.handleCallback(url) }
        }
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        for url in urls where url.scheme?.lowercased() == AuthService.callbackURL.scheme {
            switch url.host {
            case AuthService.callbackURL.host:
                Log.auth.info("received auth callback url")
                if let auth = services?.auth {
                    Task { @MainActor in await auth.handleCallback(url) }
                } else {
                    pendingCallbackURLs.append(url)
                }
            case "checkout-complete":
                // Paddle's hosted checkout (success URL → /checkout/done) deep-links
                // back here once payment lands. Bring the app forward, open Settings
                // on the Subscription tab, and re-resolve the entitlement so the new
                // plan shows without waiting for the user to switch windows.
                Log.ui.info("received checkout-complete url")
                // Opens Settings on the Subscription tab via the observer above.
                NotificationCenter.default.post(name: .nodOpenSubscription, object: nil)
                Task { @MainActor in await self.services?.entitlements.refresh() }
            case "referral":
                // Attribution B (NOD-22): a `nod://referral?code=ABC123` link
                // pre-fills the paywall's referral field. Best-effort — the code
                // is also always enterable by hand (attribution A).
                let code = URLComponents(url: url, resolvingAgainstBaseURL: false)?
                    .queryItems?.first(where: { $0.name == "code" })?.value
                if let code, !code.isEmpty {
                    Log.ui.info("received referral deep link")
                    ReferralService.storePendingCode(code)
                    NotificationCenter.default.post(name: .nodOpenSubscription, object: nil)
                }
            default:
                break
            }
        }
    }

    private func stopRecordingServices() async {
        await services?.audioCapture.stop()
        services?.transcriptStore.stop()
        services?.transcriptStore.clear()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }
}

extension Notification.Name {
    /// Posted by MeetingSession once a freshly-ended meeting has been
    /// summarised and persisted. AppDelegate opens/focuses the History
    /// window; HistoryView pushes the meeting's detail view onto its
    /// NavigationStack. `userInfo` carries the meeting id under
    /// `Notification.nodMeetingIDKey`.
    static let nodOpenMeetingDetail = Notification.Name("nod.history.openMeetingDetail")

    /// Posted by the panel's overflow (•••) menu.
    static let nodOpenSettings = Notification.Name("nod.app.openSettings")
    static let nodOpenLibrary = Notification.Name("nod.app.openLibrary")
    /// Posted by the panel's mode chip ("Manage Modes…") to open Settings on the
    /// Modes tab.
    static let nodOpenModes = Notification.Name("nod.app.openModes")
    static let nodHidePanel = Notification.Name("nod.app.hidePanel")
    /// Posted while the floating panel is being dragged. Header hover tooltips
    /// listen for this to dismiss themselves — a drag keeps the cursor "over" an
    /// icon so `.onHover` never fires its exit, leaving the tooltip pill stuck on
    /// screen mid-drag. Same intent as cancelling an open header menu on drag.
    static let nodPanelDidMove = Notification.Name("nod.panel.didMove")
    /// Posted after a completed checkout (and from the panel) to open Settings
    /// on the Subscription tab — the single home for plan/billing.
    static let nodOpenSubscription = Notification.Name("nod.app.openSubscription")
}

extension Notification {
    static let nodMeetingIDKey = "meetingID"
}
