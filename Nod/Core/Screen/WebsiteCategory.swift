import Foundation

/// A broad class of site the user can exclude in one switch, instead of naming
/// domains one at a time.
///
/// Each category is a curated keyword list, matched against the browser window
/// title — the only thing available without descending into the page. That
/// makes a category a good *default*, never a guarantee: a bank whose tab is
/// titled "Transfers" matches nothing here. Excluding the browser itself
/// remains the only absolute control, and the UI says so.
enum WebsiteCategory: String, CaseIterable, Identifiable, Codable {
    case adult
    case banking
    case health
    case social
    case shopping

    var id: String {
        rawValue
    }

    var title: String {
        switch self {
        case .adult: "Adult content"
        case .banking: "Banking & finance"
        case .health: "Health & medical"
        case .social: "Social media"
        case .shopping: "Shopping"
        }
    }

    var summary: String {
        switch self {
        case .adult: "Adult websites and mature content"
        case .banking: "Bank accounts, financial transactions, and investment platforms"
        case .health: "Medical records, health information, and healthcare providers"
        case .social: "Social media platforms and messaging services"
        case .shopping: "E-commerce sites and online shopping platforms"
        }
    }

    var icon: String {
        switch self {
        case .adult: "eye.slash"
        case .banking: "banknote"
        case .health: "cross.case"
        case .social: "bubble.left.and.bubble.right"
        case .shopping: "cart"
        }
    }

    /// Lowercased fragments matched against a window title.
    var keywords: [String] {
        switch self {
        case .adult:
            ["porn", "xxx", "onlyfans", "nsfw"]
        case .banking:
            [
                "bank", "banking", "банк", "revolut", "monobank", "privat24", "wise.com",
                "paypal", "coinbase", "binance", "ibkr", "brokerage"
            ]
        case .health:
            ["clinic", "medical", "patient", "healthcare", "helsana", "myhealth"]
        case .social:
            [
                "facebook", "instagram", "twitter", "tiktok", "linkedin",
                "reddit", "telegram", "whatsapp", "messenger"
            ]
        case .shopping:
            ["amazon", "ebay", "aliexpress", "rozetka", "checkout", "basket"]
        }
    }

    static func keywords(for categories: Set<WebsiteCategory>) -> [String] {
        categories.sorted { $0.rawValue < $1.rawValue }.flatMap(\.keywords)
    }
}
