import AppKit
import Sparkle
import Supabase

/// Owns the menu-bar status item: the capture-state icon and the dropdown
/// menu. Window actions route to the WindowCoordinator.
@MainActor
final class StatusItemController: NSObject, NSMenuDelegate {
    private let services: AppServices
    private let windows: WindowCoordinator
    private let updaterController: SPUStandardUpdaterController
    private var statusItem: NSStatusItem?

    init(
        services: AppServices,
        windows: WindowCoordinator,
        updaterController: SPUStandardUpdaterController
    ) {
        self.services = services
        self.windows = windows
        self.updaterController = updaterController
        super.init()

        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        let menu = NSMenu()
        menu.delegate = self
        item.menu = menu
        statusItem = item
        update(for: .idle)
    }

    /// Surfaces capture state in the menu bar.
    ///
    /// It carries a word, not just a coloured dot, while transcription is
    /// running: the notch sits at the top centre of one screen, and the user is
    /// as likely to be looking at a call on another. The menu bar is the one
    /// place on every screen that can say it out loud.
    func update(for state: CaptureState) {
        guard let button = statusItem?.button else { return }
        let (dotColor, label, toolTip): (NSColor?, String?, String)
        switch state {
        case .idle: (dotColor, label, toolTip) = (nil, nil, "Nod")
        case .capturing: (dotColor, label, toolTip) = (.systemRed, "Transcribing", "Nod — transcribing this call")
        case .paused: (dotColor, label, toolTip) = (.systemOrange, "Paused", "Nod — transcription paused")
        }
        button.image = Self.statusItemImage(dotColor: dotColor, appearance: button.effectiveAppearance)
        button.imagePosition = label == nil ? .imageOnly : .imageLeading
        button.attributedTitle = Self.title(label)
        button.toolTip = toolTip
    }

    /// The state word, at the menu bar's own small size and a hair dimmer than
    /// the glyph so it reads as a status rather than a second app name.
    private static func title(_ label: String?) -> NSAttributedString {
        guard let label else { return NSAttributedString(string: "") }
        return NSAttributedString(
            string: " \(label)",
            attributes: [
                .font: NSFont.systemFont(ofSize: NSFont.smallSystemFontSize, weight: .medium),
                .foregroundColor: NSColor.labelColor.withAlphaComponent(0.85)
            ]
        )
    }

    /// A non-actionable, full-contrast menu row — used for the signed-in
    /// user's name and email, which carry information but no tap target.
    private static func infoMenuItem(_ text: String, font: NSFont, color: NSColor) -> NSMenuItem {
        let item = NSMenuItem(title: "", action: nil, keyEquivalent: "")
        item.attributedTitle = NSAttributedString(string: text, attributes: [.font: font, .foregroundColor: color])
        return item
    }

    /// Copied before tinting — `NSImage(named:)` hands back a shared cached
    /// instance, so sizing it in place would resize that glyph everywhere else
    /// it is drawn. Template rendering inverts it with the row's highlight
    /// instead of leaving it dark on the selection fill.
    private static let rewardsIcon: NSImage? = {
        guard let icon = NSImage(named: "nc-gift")?.copy() as? NSImage else { return nil }
        icon.isTemplate = true
        icon.size = NSSize(width: 16, height: 16)
        return icon
    }()

    private static func statusItemImage(dotColor: NSColor?, appearance: NSAppearance) -> NSImage? {
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
        //
        // That colour comes from the BUTTON's appearance, not `NSApp`'s: the
        // menu bar follows the Mac's own Light/Dark and the wallpaper behind
        // it, so this is the one surface that must ignore Nod's Appearance
        // setting. Hardcoded white, it vanished on a light menu bar.
        // Flattened to a concrete colour inside the block, not carried out as
        // a dynamic one: `lockFocus` below draws under whatever appearance is
        // current then, which is Nod's, not the menu bar's.
        var menuBarInk = NSColor.labelColor
        appearance.performAsCurrentDrawingAppearance {
            menuBarInk = NSColor.labelColor.usingColorSpace(.sRGB) ?? .labelColor
        }
        let glyphInk = menuBarInk.withAlphaComponent(0.92)
        let dotEdge = menuBarInk.withAlphaComponent(0.9)
        let composed = NSImage(size: size)
        composed.lockFocus()
        let rect = NSRect(origin: .zero, size: size)
        glyph.draw(in: rect, from: .zero, operation: .sourceOver, fraction: 1)
        glyphInk.set()
        rect.fill(using: .sourceAtop)
        let diameter: CGFloat = 8
        let dot = NSBezierPath(ovalIn: NSRect(x: size.width - diameter, y: 0, width: diameter, height: diameter).insetBy(dx: 1, dy: 1))
        dotColor.setFill()
        dot.fill()
        dotEdge.setStroke()
        dot.lineWidth = 1
        dot.stroke()
        composed.unlockFocus()
        composed.isTemplate = false
        return composed
    }

    // MARK: - Menu actions

    @objc private func toggleFloatingPanel() {
        windows.toggleFloatingPanel()
    }

    @objc private func signOutAction() {
        // Slot release is handled by AuthService.onSignOut, so every sign-out
        // path frees it — not just this one.
        Task { @MainActor in await self.services.auth.signOut() }
    }

    @objc private func showSignInAction() {
        windows.reconcile()
        NSApp.activate(ignoringOtherApps: true)
    }

    @objc private func showHistoryAction() {
        windows.showMainWindow(focusing: nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    @objc private func showSettingsAction() {
        // Settings is a section of the main window now; the observer in
        // AppDelegate raises it and brings the window up.
        NotificationCenter.default.post(name: .nodOpenSettings, object: nil)
    }

    @objc private func showRewardsAction() {
        NotificationCenter.default.post(name: .nodOpenRewards, object: nil)
    }

    private func displayName(for user: User) -> String {
        user.profileDisplayName
    }

    // MARK: - NSMenuDelegate

    nonisolated func menuNeedsUpdate(_ menu: NSMenu) {
        MainActor.assumeIsolated {
            menu.removeAllItems()

            let signedIn = services.auth.session != nil

            if let user = services.auth.session?.user {
                let name = displayName(for: user)
                let email = user.email ?? ""

                // `isEnabled = false` layers AppKit's own disabled-item dimming
                // on top of any custom color, which on the menu's vibrancy
                // material washed this out to near-invisible. These rows have
                // no action anyway, so leaving them enabled (just with a nil
                // action) keeps full contrast without making them look tappable.
                if !name.isEmpty {
                    menu.addItem(Self.infoMenuItem(name, font: .boldSystemFont(ofSize: NSFont.systemFontSize), color: .labelColor))
                }
                if !email.isEmpty {
                    menu.addItem(
                        Self.infoMenuItem(email, font: .systemFont(ofSize: NSFont.smallSystemFontSize), color: .secondaryLabelColor)
                    )
                }
                if !name.isEmpty || !email.isEmpty {
                    menu.addItem(.separator())
                }
            }

            if signedIn {
                let toggle = NSMenuItem(
                    title: "Open Capture",
                    action: #selector(toggleFloatingPanel),
                    keyEquivalent: ""
                )
                toggle.target = self
                // Display-only mirror of the binding; the Carbon global hotkey is the real trigger.
                if let (key, mask) = services.hotkeys.combo(for: .togglePanel).menuKeyEquivalent {
                    toggle.keyEquivalent = key
                    toggle.keyEquivalentModifierMask = mask
                }
                menu.addItem(toggle)

                let history = NSMenuItem(
                    title: "Open Nod…",
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

                let rewards = NSMenuItem(
                    title: "Rewards…",
                    action: #selector(showRewardsAction),
                    keyEquivalent: ""
                )
                rewards.target = self
                rewards.image = Self.rewardsIcon
                menu.addItem(rewards)

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
