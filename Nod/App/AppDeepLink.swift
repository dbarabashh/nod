import Foundation

enum AppDeepLink: Equatable {
    case authCallback
    case checkoutComplete
    case referral(code: String)
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
