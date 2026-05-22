import Foundation
import EventKit
import Combine

struct UpcomingMeeting: Equatable {
    let title: String
    let startDate: Date
    let attendeeCount: Int

    var startsInMinutes: Int {
        max(0, Int(startDate.timeIntervalSinceNow / 60))
    }

    /// Subtitle string shown below the title in the card.
    var subtitle: String {
        let mins = startsInMinutes
        let timing: String
        if startDate.timeIntervalSinceNow < 0 {
            let pastMins = abs(Int(startDate.timeIntervalSinceNow / 60))
            timing = pastMins == 0 ? "Live now" : "Started \(pastMins) min ago"
        } else if mins == 0 {
            timing = "Starting now"
        } else if mins < 60 {
            timing = "Starts in \(mins) min"
        } else {
            let h = mins / 60
            let m = mins % 60
            timing = m == 0 ? "Starts in \(h)h" : "Starts in \(h)h \(m)m"
        }
        if attendeeCount > 0 {
            return "\(timing) · \(attendeeCount) attendees"
        }
        return timing
    }
}

@MainActor
final class UpcomingMeetingService: ObservableObject {
    enum Access {
        case unknown
        case denied
        case authorized
    }

    @Published private(set) var access: Access = .unknown
    @Published private(set) var nextMeeting: UpcomingMeeting?

    private let store = EKEventStore()
    private var refreshTask: Task<Void, Never>?
    private var changeObserver: NSObjectProtocol?

    init() {
        evaluateAccess()
        if access == .authorized {
            startObservingChanges()
            startRefreshLoop()
            Task { await refresh() }
        }
    }

    /// Call once at app launch to surface the system permission prompt.
    func requestAccessIfNeeded() async {
        let status = EKEventStore.authorizationStatus(for: .event)
        if status == .denied || status == .restricted {
            access = .denied
            return
        }
        if Self.statusIsAuthorized(status) {
            access = .authorized
            startObservingChanges()
            startRefreshLoop()
            await refresh()
            return
        }
        // .notDetermined → request now.
        do {
            let granted: Bool
            if #available(macOS 14.0, *) {
                granted = try await store.requestFullAccessToEvents()
            } else {
                granted = try await store.requestAccess(to: .event)
            }
            access = granted ? .authorized : .denied
            if granted {
                startObservingChanges()
                startRefreshLoop()
                await refresh()
            }
        } catch {
            Log.ui.error("calendar access request failed: \(error.localizedDescription)")
            access = .denied
        }
    }

    /// Treat both legacy `.authorized` and macOS 14+ `.fullAccess` / `.writeOnly`
    /// as "we can read events".
    private static func statusIsAuthorized(_ status: EKAuthorizationStatus) -> Bool {
        if status == .authorized { return true }
        if #available(macOS 14.0, *) {
            if status == .fullAccess || status == .writeOnly { return true }
        }
        return false
    }

    func refresh() async {
        guard access == .authorized else { return }
        let now = Date()
        let horizon = Calendar.current.date(byAdding: .hour, value: 12, to: now) ?? now.addingTimeInterval(12 * 3600)
        let predicate = store.predicateForEvents(withStart: now.addingTimeInterval(-300), end: horizon, calendars: nil)
        let events = store.events(matching: predicate)
            .filter { !$0.isAllDay }
            .filter { ($0.endDate ?? $0.startDate) >= now }
            .sorted { $0.startDate < $1.startDate }

        if let first = events.first {
            let next = UpcomingMeeting(
                title: first.title ?? "(Untitled)",
                startDate: first.startDate,
                attendeeCount: first.attendees?.count ?? 0
            )
            if nextMeeting != next {
                Log.ui.info("next meeting → \(next.title) (\(next.subtitle))")
            }
            nextMeeting = next
        } else {
            if nextMeeting != nil {
                Log.ui.info("no upcoming meeting in next 12h")
            }
            nextMeeting = nil
        }
    }

    private func evaluateAccess() {
        let status = EKEventStore.authorizationStatus(for: .event)
        if status == .denied || status == .restricted {
            access = .denied
        } else if Self.statusIsAuthorized(status) {
            access = .authorized
        } else {
            access = .unknown
        }
    }

    private func startRefreshLoop() {
        refreshTask?.cancel()
        refreshTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 60_000_000_000) // 60s
                await self?.refresh()
            }
        }
    }

    private func startObservingChanges() {
        guard changeObserver == nil else { return }
        changeObserver = NotificationCenter.default.addObserver(
            forName: .EKEventStoreChanged,
            object: store,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                await self?.refresh()
            }
        }
    }
}
