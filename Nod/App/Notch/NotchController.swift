import AppKit
import Combine
import SwiftUI

/// Owns the notch window and the model behind it, and keeps the two attached to
/// the right screen.
///
/// Built once per signed-in session and torn down with it, so a mid-recording
/// sign-out can't leave the next user looking at the previous one's capture.
@MainActor
final class NotchController {
    private(set) var model: NotchModel?

    private var panel: NotchPanel?
    private var outsideClickMonitor: Any?
    private var cancellables = Set<AnyCancellable>()

    var isBuilt: Bool {
        panel != nil
    }

    /// The model arrives already built: assembling it needs the whole service
    /// graph, which lives with the coordinator. This owns the window.
    func build(model: NotchModel, sharing: NSWindow.SharingType) {
        guard panel == nil else { return }
        self.model = model

        let panel = NotchPanel(content: NotchView(model: model), sharing: sharing)
        self.panel = panel
        anchor()
        panel.orderFrontRegardless()

        observeScreens()
        watchForOutsideClicks(model: model)
    }

    func teardown() {
        if let outsideClickMonitor {
            NSEvent.removeMonitor(outsideClickMonitor)
        }
        outsideClickMonitor = nil
        cancellables.removeAll()
        panel?.close()
        panel = nil
        model = nil
    }

    /// The hotkey and the menu-bar item both land here: pull the surface open,
    /// or fold it away if it already is.
    func toggleOpen() {
        model?.toggleOpen()
    }

    func open() {
        model?.open()
    }

    func setSharing(_ sharing: NSWindow.SharingType) {
        panel?.sharingType = sharing
    }

    /// Resolve the host screen once and hand both halves of the answer out: the
    /// window gets anchored to it, the model gets its cut-out dimensions.
    private func anchor() {
        guard let screen = NSScreen.nodNotchHost else { return }
        panel?.anchor(to: screen)
        model?.setGeometry(screen.nodNotchGeometry)
    }

    /// Plugging in a display, unplugging one, or changing the arrangement can
    /// move the menu bar to a different screen — and the notch has to follow it
    /// rather than stay hanging in the middle of a monitor that no longer has one.
    private func observeScreens() {
        NotificationCenter.default
            .publisher(for: NSApplication.didChangeScreenParametersNotification)
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.anchor() }
            .store(in: &cancellables)
    }

    /// Fold an opened surface away when the user's attention goes elsewhere.
    ///
    /// A *global* monitor: it only sees clicks outside this app's windows, which
    /// is exactly the question being asked. Clicks inside the notch never reach
    /// it, so no coordinate maths is needed to tell the two apart.
    private func watchForOutsideClicks(model: NotchModel) {
        outsideClickMonitor = NSEvent.addGlobalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown]
        ) { [weak model] _ in
            MainActor.assumeIsolated {
                guard let model, model.closesOnOutsideClick else { return }
                model.close()
            }
        }
    }
}
