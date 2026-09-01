import Foundation

/// Why a chat turn produced no answer, and what the person can do about it.
///
/// `LLMProxyClient.ClientError` already says what went wrong on the wire. What
/// it cannot say is which button belongs under the sentence: a plan that
/// doesn't cover Ask Nod and a dropped connection are both "no answer
/// arrived", and offering Retry for the first is a button guaranteed not to
/// work. Both chats publish this instead of a bare string, so the two surfaces
/// can't disagree about what a failure means or what to offer for it.
struct ChatFailure: Equatable {
    /// The one action worth offering. Everything here is reachable from a chat
    /// surface — a failure whose fix isn't (an expired session, a stale build)
    /// carries `.none` and says what to do in words instead.
    enum Recovery: Equatable {
        case retry
        case upgrade
        case none
    }

    let message: String
    let recovery: Recovery
    /// The underlying error verbatim, behind a disclosure. Kept because
    /// dropping it makes every report of a broken chat unactionable; hidden
    /// because "LLM proxy HTTP 502: upstream timeout" is not a sentence.
    var detail: String?
    /// What the turn had already done when it failed. A tool call that ran
    /// before the answer broke is the difference between "nothing happened"
    /// and "the ticket exists, the summary doesn't" — so the steps outlive the
    /// answer that never came.
    var steps: [ChatTurnStep] = []
    /// The link was the problem, so the turn can be picked up again on its own
    /// once it returns.
    var isOffline = false
}

extension ChatFailure {
    init(_ error: Error, steps: [ChatTurnStep] = []) {
        self = Self.classify(error)
        self.steps = steps
    }

    /// The model spent its rounds asking for tools and never wrote a word.
    static func emptyAnswer(steps: [ChatTurnStep] = []) -> ChatFailure {
        ChatFailure(message: "Nod couldn't finish that answer.", recovery: .retry, steps: steps)
    }

    /// The model asked for something that isn't on the table.
    static func unknownTool(steps: [ChatTurnStep] = []) -> ChatFailure {
        ChatFailure(message: ChatToolGate.unknownToolMessage, recovery: .retry, steps: steps)
    }

    /// The stream died after the reader had already started reading. What
    /// arrived is kept, so this is a note on a partial answer rather than a
    /// replacement for one.
    static func cutShort(steps: [ChatTurnStep] = []) -> ChatFailure {
        ChatFailure(message: "The answer was cut short.", recovery: .retry, steps: steps)
    }

    private static func classify(_ error: Error) -> ChatFailure {
        guard let client = error as? LLMProxyClient.ClientError else {
            return offline(error as? URLError) ?? ChatFailure(
                message: "Something went wrong.",
                recovery: .retry,
                detail: error.localizedDescription
            )
        }
        switch client {
        // These already carry a sentence written for a person, so they are
        // taken as they are. Restating them here would be a second copy of the
        // same wording, free to drift from whatever else shows the error.
        case .unauthenticated, .updateRequired, .deviceConflict, .meetingBlocked:
            return ChatFailure(message: spoken(client), recovery: .none)
        case .entitlementRequired, .meetingLimitReached:
            return ChatFailure(message: spoken(client), recovery: .upgrade)
        // The rest describe the wire — "LLM proxy HTTP 502", "Failed to decode
        // proxy response" — which is a detail, not a sentence. Those get one
        // written here and keep the original behind the disclosure.
        case let .requestFailed(status, body):
            return requestFailure(status: status, body: body)
        case .emptyResponse:
            return ChatFailure(message: "Nod got an empty answer back.", recovery: .retry)
        case let .decodingFailed(detail):
            return ChatFailure(message: "Nod couldn't read the answer.", recovery: .retry, detail: detail)
        case let .networkFailed(underlying):
            return offline(underlying as? URLError) ?? ChatFailure(
                message: "Nod couldn't reach the server.",
                recovery: .retry,
                detail: underlying.localizedDescription
            )
        case let .indexIncomplete(indexed, total):
            return ChatFailure(
                message: "Only \(indexed) of \(total) parts of that session are indexed yet.",
                recovery: .retry
            )
        }
    }

    private static func spoken(_ error: LLMProxyClient.ClientError) -> String {
        error.errorDescription ?? "Something went wrong."
    }

    private static func requestFailure(status: Int, body: String) -> ChatFailure {
        let detail = "HTTP \(status): \(body)"
        switch status {
        case 429:
            return ChatFailure(message: "Too many requests right now. Give it a moment.", recovery: .retry, detail: detail)
        case 500 ... 599:
            return ChatFailure(message: "The server had a problem answering that.", recovery: .retry, detail: detail)
        default:
            return ChatFailure(message: "Nod couldn't finish that answer.", recovery: .retry, detail: detail)
        }
    }

    /// Transport codes that mean "the link, not the server". Named so the row
    /// can say "you're offline" instead of blaming Nod, and so the turn can be
    /// resumed by itself when the path comes back.
    private static func offline(_ error: URLError?) -> ChatFailure? {
        guard let error, offlineCodes.contains(error.code) else { return nil }
        return ChatFailure(
            message: "You're offline. Nod will pick this up when the connection is back.",
            recovery: .retry,
            detail: error.localizedDescription,
            isOffline: true
        )
    }

    private static let offlineCodes: Set<URLError.Code> = [
        .notConnectedToInternet,
        .networkConnectionLost,
        .cannotConnectToHost,
        .cannotFindHost,
        .dataNotAllowed,
        .timedOut
    ]
}

extension ChatFailure.Recovery {
    /// The button's words, or nil when there is nothing to press. Never a bare
    /// "Retry" on a failure a retry cannot fix.
    var label: String? {
        switch self {
        case .retry: "Try again"
        case .upgrade: "Upgrade"
        case .none: nil
        }
    }
}
