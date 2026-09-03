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
        .commands {
            CommandGroup(after: .appInfo) {
                Button {
                    NotificationCenter.default.post(name: .nodCheckForUpdates, object: nil)
                } label: {
                    IconLabel(title: "Check for Updates…", icon: "nc-refresh-2")
                }
            }

            CommandGroup(replacing: .appSettings) {
                Button {
                    NotificationCenter.default.post(name: .nodOpenSettings, object: nil)
                } label: {
                    IconLabel(title: "Settings…", icon: "nc-gear-2")
                }
                .keyboardShortcut(",", modifiers: .command)

                Button {
                    NotificationCenter.default.post(name: .nodOpenRewards, object: nil)
                } label: {
                    IconLabel(title: "Referral Program…", icon: "nc-gift")
                }
            }
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
    // keeps firing for the life of the app — and the delegate, which Sparkle
    // holds weakly, for the same reason.
    // Built here rather than in `WindowCoordinator` because Sparkle holds its
    // delegate weakly and this is the object that outlives everything.
    private let updaterChannelDelegate = UpdaterChannelDelegate()
    private lazy var updaterController = SPUStandardUpdaterController(
        startingUpdater: true,
        updaterDelegate: updaterChannelDelegate,
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
        // The version footer reads the newest build the feed offers, and the
        // feed is Sparkle's — so the delegate that already answers Sparkle's
        // channel question is the one that reports it.
        windows.feed = updaterChannelDelegate
        updaterChannelDelegate.refresh = { [weak self] in
            self?.updaterController.updater.checkForUpdateInformation()
        }
        self.services = services
        self.windows = windows
        self.statusBar = statusBar

        // Before any window is built, so the first one comes up already in the
        // user's theme rather than flashing the system's.
        services.appearance.apply()

        services.hotkeys.onTrigger = { [weak windows] action in
            switch action {
            case .togglePanel:
                windows?.toggleFloatingPanel()
            case .askNod:
                windows?.askNod()
            case .holdToAsk:
                windows?.beginVoiceAsk()
            }
        }
        services.hotkeys.onRelease = { [weak windows] action in
            guard action == .holdToAsk else { return }
            windows?.endVoiceAsk()
        }

        NotificationCenter.default.addObserver(
            forName: .nodOpenMeetingDetail,
            object: nil,
            queue: nil
        ) { [weak windows] note in
            let id = note.userInfo?[Notification.nodMeetingIDKey] as? UUID
            Task { @MainActor in
                guard let windows, let id else { return }
                windows.showMainWindow(focusing: id)
                NSApp.activate(ignoringOtherApps: true)
            }
        }

        // Settings is a section of the main window, not a window of its own —
        // every entry point raises the pane request first, then brings the
        // window up on it.
        func observeSettingsPane(_ name: Notification.Name, _ pane: SettingsFocus.Pane) {
            NotificationCenter.default.addObserver(forName: name, object: nil, queue: nil) { [weak windows] _ in
                Task { @MainActor in
                    services.settingsFocus.open(pane)
                    windows?.showMainWindow()
                    NSApp.activate(ignoringOtherApps: true)
                }
            }
        }
        observeSettingsPane(.nodOpenSettings, .general)
        observeSettingsPane(.nodOpenPrivacySettings, .privacy)
        observeSettingsPane(.nodOpenRewards, .rewards)
        // Posted by upsell buttons and the post-checkout deep link.
        observeSettingsPane(.nodOpenSubscription, .subscription)
        observeSettingsPane(.nodOpenOrganization, .organization)

        NotificationCenter.default.addObserver(forName: .nodOpenLibrary, object: nil, queue: nil) { [weak windows] _ in
            Task { @MainActor in
                windows?.showMainWindow(focusing: nil)
                NSApp.activate(ignoringOtherApps: true)
            }
        }
        // The main window's way back to the capture surface. Open, never toggle:
        // a button that silently folds away the thing the user just asked for
        // reads as broken.
        NotificationCenter.default.addObserver(forName: .nodShowPanel, object: nil, queue: nil) { [weak windows] _ in
            Task { @MainActor in
                windows?.revealPanel()
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
                await services.emailPreferences.refresh()
                await services.productAnalytics.flush()
                await services.onboardingTelemetry.flush()
                // A task filed in Linear is finished in Linear, and coming back
                // to Nod is exactly when that has just happened. Without this
                // the checkbox here only ever reflects work closed in Nod.
                await services.actionItemStore.refresh()
                // Membership and folder shares change on someone else's Mac —
                // an invite accepted, a team joined, a project shared with you.
                // Nothing in this app can be told about that, so coming back to
                // it is the moment to ask, exactly as the entitlement above does.
                await services.organizations.refresh()
                await services.labelStore.refresh()
                await services.beats.refresh()
                await services.meetingGrants.refresh()
                await services.remoteCalendar.sync(.open)
                // Both, together. Access to a shared folder and access to the
                // sessions inside it are revoked by the same act, so refreshing
                // one without the other leaves the two disagreeing — a project
                // in the sidebar whose contents have already gone.
                await services.meetingStore.refresh(force: true)
                let states = await services.integrations.remoteCompletions(
                    among: services.actionItemStore.items
                )
                await services.actionItemStore.applyRemoteCompletions(states)
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
        // Sparkle reads the cached channel synchronously inside its check, so
        // a channel that only just changed needs the cycle reset to be seen
        // before the next 24h tick.
        Task { @MainActor in
            if await services.releaseChannel.refresh() {
                updaterController.updater.resetUpdateCycle()
            }
        }
        // Ambient capture is opt-in: this starts it only if the user has
        // already turned it on, and is a no-op otherwise.
        services.screenContext.refresh()
        services.beatRunner.start()
        // One-time catch-up: sessions recorded before the distiller existed
        // get their facts extracted now, so the knowledge layer doesn't start
        // empty for everyone who upgrades into it.
        Task { await services.knowledgeStore.backfillDistill() }

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
                // Before `reconcile()` reads `isCompleted`: onboarding progress
                // is per account, and which account it describes is decided
                // here. Signing out adopts nil so the next person to arrive is
                // not handed the last one's answers.
                services.onboarding.adopt(userID: services.auth.currentSupabaseSession?.user.id)
                if wasSignedIn, !isSignedIn {
                    // Sign-out: tear down the recording pipeline AND drop
                    // the per-user caches so the next signed-in user can't
                    // see the previous one's data through the in-memory
                    // store or a stale History window.
                    await stopRecordingServices()
                    await services.clearPerAccountState()
                    windows.closeMainWindow()
                }
                if isSignedIn {
                    if !wasSignedIn {
                        Task { @MainActor in
                            await services.organizations.refresh()
                            await services.accessChannel.resubscribe(
                                orgIDs: services.organizations.memberships.map(\.id),
                                teamIDs: Array(services.organizations.myTeamIDs)
                            )
                        }
                        services.productAnalytics.record(
                            .appOpened,
                            properties: .init(entryPoint: .appLaunch),
                            oncePerSession: "launch"
                        )
                    }
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
                        // `$session` republishes on every token refresh too, so
                        // the recap retry below is scoped to the sign-in
                        // transition — it is a once-per-launch sweep, not an
                        // hourly one.
                        let isFirstSignIn = !wasSignedIn
                        Task {
                            await services.meetingOutbox.recoverInterruptedMeetings()
                            await services.meetingOutbox.flush(using: services.meetingStore, userID: userID)
                            let pending = await services.meetingOutbox.pendingCompletedMeetings(for: userID)
                            await MainActor.run { services.meetingStore.setUnsyncedMeetings(pending) }
                            // After the drain on purpose: a row still queued
                            // would have the new recap overwritten by it.
                            if isFirstSignIn {
                                await services.summaryRegeneration.retryFailedSummaries()
                            }
                        }
                    }
                    // Warm the profile so its prompt context is ready before
                    // the first meeting ends. `load` no-ops once cached.
                    Task { await services.profileStore.load() }
                    Task { await services.labelStore.refresh() }
                    Task {
                        services.remoteCalendar.selfEmail = services.auth.currentSupabaseSession?.user.email
                        await services.meetingGrants.refresh()
                        await services.remoteCalendar.sync(.open)
                    }
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

        // The first focus of any text field lazily spins up the spell / grammar /
        // autocorrect / data-detector services on the main thread. If that first
        // focus is the Ask box during a live recording, the one-time stall starves
        // the audio render thread and is heard as a crackle — but only on a fresh
        // launch, before the services are warm. Warm them now, off the audio path
        // and deferred so launch itself isn't slowed.
        DispatchQueue.main.async { Self.prewarmTextInput() }
    }

    /// One-time warm-up of the text-checking service stack, so the first real
    /// text-field focus (notably the live Ask box mid-recording) doesn't pay the
    /// lazy XPC spin-up as a main-thread stall. See the call site above.
    private static func prewarmTextInput() {
        let checker = NSSpellChecker.shared
        let sample = "Warm up the text checker." as NSString
        let types: NSTextCheckingResult.CheckingType =
            [.spelling, .grammar, .correction, .replacement]
        _ = checker.check(
            sample as String,
            range: NSRange(location: 0, length: sample.length),
            types: types.rawValue,
            options: nil,
            inSpellDocumentWithTag: 0,
            orthography: nil,
            wordCount: nil
        )
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        for url in urls where url.scheme?.lowercased() == AuthService.callbackURL.scheme {
            guard let deepLink = AppDeepLink(url: url, callbackHost: AuthService.callbackURL.host) else { continue }
            switch deepLink {
            case .authCallback:
                Log.auth.info("received auth callback url")
                if let auth = services?.auth {
                    Task { @MainActor in await auth.handleCallback(url) }
                } else {
                    pendingCallbackURLs.append(url)
                }
            case .checkoutComplete:
                // Paddle's hosted checkout (success URL → /checkout/done) deep-links
                // back here once payment lands. Bring the app forward, open Settings
                // on the Subscription tab, and re-resolve the entitlement so the new
                // plan shows without waiting for the user to switch windows.
                Log.ui.info("received checkout-complete url")
                // Opens Settings on the Subscription tab via the observer above.
                NotificationCenter.default.post(name: .nodOpenSubscription, object: nil)
                Task { @MainActor in await self.services?.entitlements.refresh() }
            case let .invite(token):
                // Held rather than acted on when signed out — accepting needs an
                // identity, and the address it was sent to is the one that works.
                Log.ui.info("received organization invite deep link")
                OrganizationService.storePendingInvite(token)
                NotificationCenter.default.post(name: .nodOpenOrganization, object: nil)
                Task { @MainActor in await self.services?.organizations.redeemPendingInvite() }
            case let .referral(code):
                // Attribution B (NOD-22): a `nod://referral?code=ABC123` link
                // pre-fills the paywall's referral field. Best-effort — the code
                // is also always enterable by hand (attribution A).
                Log.ui.info("received referral deep link")
                ReferralService.storePendingCode(code)
                NotificationCenter.default.post(name: .nodOpenSubscription, object: nil)
            case .record:
                NotificationCenter.default.post(name: .nodShowPanel, object: nil)
            case .history:
                NotificationCenter.default.post(name: .nodOpenLibrary, object: nil)
            case .ask:
                NotificationCenter.default.post(name: .nodOpenKnowledgeChats, object: nil)
            case .actionItems:
                NotificationCenter.default.post(name: .nodOpenActionItems, object: nil)
            case let .subscription(offer):
                if offer == "winback" { BillingService.storePendingWinbackOffer() }
                NotificationCenter.default.post(name: .nodOpenSubscription, object: nil)
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

    /// Fired when the user clicks the Dock icon (with no visible windows).
    /// Re-open whichever primary surface matches the current state, and bring
    /// back a panel that was hidden via the toggle hotkey.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows: Bool) -> Bool {
        windows?.reconcile()
        // Clicking the Dock icon means "show me the app" — the home surface.
        // Not the capture panel: that stays something the user summons.
        if services?.auth.session != nil, services?.onboarding.isCompleted == true {
            windows?.showMainWindow()
        }
        NSApp.activate(ignoringOtherApps: true)
        return true
    }
}

extension Notification.Name {
    /// Posted by MeetingSession once a freshly-ended meeting has been
    /// summarised and persisted. AppDelegate opens/focuses the History
    /// window; MainWindowView pushes the meeting's detail view onto its
    /// NavigationStack. `userInfo` carries the meeting id under
    /// `Notification.nodMeetingIDKey`.
    static let nodOpenMeetingDetail = Notification.Name("nod.history.openMeetingDetail")

    static let nodOpenSettings = Notification.Name("nod.app.openSettings")
    /// Posted by the `nod://invite` deep link so Settings lands where the invite
    /// is redeemed rather than wherever it was last left.
    static let nodOpenOrganization = Notification.Name("nod.app.openOrganization")
    static let nodOpenLibrary = Notification.Name("nod.app.openLibrary")
    /// Switch the Meetings window to the saved cross-session chats — posted
    /// when the launcher hands its thread over.
    static let nodOpenKnowledgeChats = Notification.Name("nod.history.openKnowledgeChats")
    /// Posted by the sidebar's ambient row: switching ambient capture ON has to
    /// happen where the disclosure is, not behind a tooltip.
    static let nodOpenPrivacySettings = Notification.Name("nod.app.openPrivacySettings")
    /// Posted from the main window, and by the session when a countdown needs
    /// answering, to open the capture surface.
    static let nodShowPanel = Notification.Name("nod.app.showPanel")
    /// Posted after a completed checkout, and by the paywall gate, to open
    /// Settings on the Subscription tab — the single home for plan/billing.
    static let nodOpenSubscription = Notification.Name("nod.app.openSubscription")
    /// Posted by the menu-bar item to open Settings on the Rewards tab.
    static let nodOpenRewards = Notification.Name("nod.app.openRewards")
    static let nodOpenActionItems = Notification.Name("nod.app.openActionItems")
}

extension Notification {
    static let nodMeetingIDKey = "meetingID"
}
