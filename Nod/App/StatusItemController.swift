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

        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        let menu = NSMenu()
        menu.delegate = self
        item.menu = menu
        statusItem = item
        update(for: .idle)
    }

    /// Surfaces capture state in the menu bar so a recording stays visible
    /// when the panel is hidden via the toggle hotkey.
    func update(for state: CaptureState) {
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
        windows.showHistoryWindow(focusing: nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    @objc private func showSettingsAction() {
        windows.showSettingsWindow()
        NSApp.activate(ignoringOtherApps: true)
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

            if signedIn, let panel = windows.panel {
                let toggle = NSMenuItem(
                    title: panel.isVisible ? "Hide Panel" : "Show Panel",
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
