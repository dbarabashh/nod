import Foundation

enum AppDeepLink: Equatable {
    case authCallback
    case checkoutComplete
    case referral(code: String)
    /// `nod://invite?token=…` from the landing page's `/invite/<token>`.
    case invite(token: UUID)
    /// `nod://meeting?id=…` from the footer of a task filed out of a session.
    case meeting(id: UUID)
    case record
    case history
    case ask
    case actionItems
    case subscription(offer: String?)

    /// Every case but the callback opens the main window without asking, and
    /// a launch that has the sign-in or onboarding window up would have that
    /// covered — so those links wait here rather than being acted on early.
    var needsSignedInApp: Bool {
        switch self {
        case .authCallback:
            false
        case .checkoutComplete, .referral, .invite, .meeting,
             .record, .history, .ask, .actionItems, .subscription:
            true
        }
    }

    init?(url: URL, callbackHost: String?) {
        guard let host = url.host else { return nil }
        if host == callbackHost {
            self = .authCallback
            return
        }
        let query = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems
        switch host {
        case "checkout-complete":
            self = .checkoutComplete
        case "referral":
            guard let code = query?.first(where: { $0.name == "code" })?.value, !code.isEmpty else { return nil }
            self = .referral(code: code)
        case "invite":
            // A token that isn't a UUID can only be a mistyped or truncated link;
            // there is nothing to redeem, so the link is not ours to handle.
            guard let raw = query?.first(where: { $0.name == "token" })?.value,
                  let token = UUID(uuidString: raw) else { return nil }
            self = .invite(token: token)
        case "meeting":
            guard let raw = query?.first(where: { $0.name == "id" })?.value,
                  let id = UUID(uuidString: raw) else { return nil }
            self = .meeting(id: id)
        case "record":
            self = .record
        case "history":
            self = .history
        case "ask":
            self = .ask
        case "action-items":
            self = .actionItems
        case "subscription":
            self = .subscription(offer: query?.first(where: { $0.name == "offer" })?.value)
        default:
            return nil
        }
    }
}
