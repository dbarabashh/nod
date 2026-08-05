import AppKit
import Carbon.HIToolbox
import SwiftUI

/// Owns the quick panel: its window, its model, and the keys that drive it.
///
/// Navigation keys are taken with a local event monitor rather than SwiftUI's
/// `onKeyPress` (macOS 14+) because a focused `TextField` swallows the arrows
/// for caret movement, and the panel must work on the app's macOS 13 floor.
@MainActor
final class LauncherController {
    private let services: AppServices
    private let model: LauncherModel
    private var panel: LauncherPanel?
    private var keyMonitor: Any?

    /// Opens the Library on a session — the launcher is a way in, not a place
    /// to read a whole meeting.
    private let openMeeting: (UUID) -> Void
    private let openLibrary: () -> Void

    init(services: AppServices, openMeeting: @escaping (UUID) -> Void, openLibrary: @escaping () -> Void) {
        self.services = services
        self.openMeeting = openMeeting
        self.openLibrary = openLibrary
        model = LauncherModel(
            meetings: services.meetingStore,
            knowledge: services.knowledgeStore,
            chat: services.knowledgeChat
        )
    }

    func toggle() {
        if panel?.isVisible == true {
            dismiss()
        } else {
            present()
        }
    }

    private func present() {
        // Doesn't clear the shared thread — the Library dock may be
        // mid-conversation on the same store. The model decides whether this is
        // a fresh open or a return to what was just on screen.
        model.prepareForPresentation()

        let panel = panel ?? makePanel()
        self.panel = panel
        panel.sharingType = services.panelSharing.sharingType
        panel.present()
        startKeyMonitor()
        // The cached list is what the launcher searches, so top it up in the
        // background rather than blocking the panel on a round trip.
        Task { await services.meetingStore.refresh() }
    }

    private func dismiss() {
        panel?.dismiss()
    }

    private func makePanel() -> LauncherPanel {
        let content = LauncherView(
            model: model,
            onOpenMeeting: { [weak self] id in self?.open(id) },
            onAsk: { [weak self] in self?.ask() },
            onContinueInLibrary: { [weak self] in self?.continueInLibrary() },
            onDismiss: { [weak self] in self?.dismiss() }
        )
        .environmentObject(services.knowledgeChat)
        .environmentObject(services.knowledgeThreads)
        .environmentObject(services.entitlements)
        .frame(width: LauncherPanel.width)

        return LauncherPanel(content: content, sharing: services.panelSharing.sharingType) { [weak self] in
            self?.stopKeyMonitor()
            self?.model.noteDismissed()
        }
    }

    // MARK: - Actions

    private func open(_ id: UUID) {
        model.noteConsumed()
        dismiss()
        openMeeting(id)
    }

    /// Hands the thread to the Library — same store and the same saved thread,
    /// so the conversation continues rather than restarting.
    private func continueInLibrary() {
        model.noteConsumed()
        dismiss()
        openLibrary()
        NotificationCenter.default.post(name: .nodOpenKnowledgeChats, object: nil)
    }

    private func ask() {
        Task { await model.ask() }
    }

    // MARK: - Keys

    private func startKeyMonitor() {
        guard keyMonitor == nil else { return }
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, panel?.isKeyWindow == true else { return event }
            return handle(event) ? nil : event
        }
    }

    private func stopKeyMonitor() {
        guard let keyMonitor else { return }
        NSEvent.removeMonitor(keyMonitor)
        self.keyMonitor = nil
    }

    /// Returns true when the event was consumed and must not reach the field.
    private func handle(_ event: NSEvent) -> Bool {
        let command = event.modifierFlags.contains(.command)
        switch Int(event.keyCode) {
        case kVK_UpArrow:
            model.moveSelection(by: -1)
            return true
        case kVK_DownArrow:
            model.moveSelection(by: 1)
            return true
        case kVK_Tab:
            // Jumps to the ask row wherever it sits, so asking never needs the
            // "?" prefix or a hunt through the list.
            model.selection = model.leadsWithAsk ? 0 : max(model.rows.count - 1, 0)
            return true
        case kVK_Return, kVK_ANSI_KeypadEnter:
            // ⌘↩ always means "ask" — from search it's the shortcut into the
            // other mode, and in ask mode it hands the thread to the Library.
            if command {
                if model.isAnswering, model.answer != nil {
                    continueInLibrary()
                } else {
                    ask()
                }
                return true
            }
            switch model.selectedRow {
            case .ask:
                ask()
            case let .session(result):
                open(result.id)
            case nil:
                // Nothing selected but something typed still reads as "answer
                // this" rather than a dead key.
                ask()
            }
            return true
        default:
            return false
        }
    }
}
