import Foundation

/// Where each of Nod's two calendar sources stands, and whether the question
/// has been answered at all.
///
/// A value type rather than statics on a SwiftUI view: two surfaces and the
/// tests all ask these questions, and `swift-architecture.md` keeps business
/// logic out of views. `deviceState` is a pure function of `CalendarService`,
/// `googleState` of `IntegrationService`.
enum CalendarSourceState: Equatable {
    case offer
    case pending
    case connected
    case blocked

    @MainActor
    static func device(_ calendar: CalendarService) -> CalendarSourceState {
        switch calendar.status {
        case .authorized where calendar.isEnabled: .connected
        case .denied: .blocked
        // Deliberately still an offer, never a spinner: `ensureAccess` declines
        // to prompt when no window is key, and macOS itself asks only once — so
        // an undetermined grant is a button the user can press again, not a
        // state to wait in.
        default: .offer
        }
    }

    @MainActor
    static func google(_ integrations: IntegrationService) -> CalendarSourceState {
        if integrations.linked.contains(.googleCalendar) { return .connected }
        if integrations.pending == .googleCalendar { return .pending }
        return .offer
    }

    /// Whether the user has answered the calendar question, which is not the
    /// same as `CalendarService.hasAnySource`: a calendar connected a second ago
    /// has nothing synced yet, and a step that still reads "Not now" under a row
    /// saying "Connected" looks broken.
    @MainActor
    static func isAnswered(calendar: CalendarService, integrations: IntegrationService) -> Bool {
        device(calendar) == .connected || google(integrations) == .connected
    }
}
