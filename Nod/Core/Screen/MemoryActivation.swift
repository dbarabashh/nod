import Foundation

enum MemoryActivation {
    enum Stage: String, Equatable {
        case hidden, off, permission, paused, checking, waiting, ready, failed
    }

    static let question = "What was I working on in the last 24 hours? Summarize the available screen context and show the sources."

    static func stage(
        eligible: Bool,
        dismissed: Bool,
        completed: Bool,
        enabled: Bool,
        needsAccess: Bool,
        paused: Bool,
        ready: Bool?,
        failed: Bool
    ) -> Stage {
        guard eligible, !dismissed, !completed else { return .hidden }
        guard enabled else { return .off }
        if paused { return .paused }
        if needsAccess { return .permission }
        if failed { return .failed }
        guard let ready else { return .checking }
        return ready ? .ready : .waiting
    }

    static func completionKey(_ userID: UUID) -> String {
        "memory-activation.answered.\(userID.uuidString)"
    }
}
