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
