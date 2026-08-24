import AppKit
import Foundation
import Supabase

/// One product in the broker's catalogue, whether or not Nod can use it.
struct CatalogueApp: Identifiable, Equatable, Decodable {
    /// The broker's app slug. The identity everywhere, because it is what a
    /// request records and what a mark is fetched by.
    let slug: String
    let name: String
    let description: String
    let categories: [String]

    var id: String {
        slug
    }
}

/// Names and draws the products this account has connected.
///
/// Its own object rather than more of `IntegrationService`: that one owns the
/// connections this account actually has, which is a fact about the account.
/// This reaches the broker's catalogue, which is the same for everybody and is
/// where a product's name and mark come from when no asset ships for it.
///
/// In `Core` because two features read it now: Settings, which searches it, and
/// every surface that draws a connected product's mark — `ProviderMark` can no
/// longer answer from the asset catalogue once a connection can be to anything.
@MainActor
final class IntegrationCatalogue: ObservableObject {
    /// Products this account has authorized that Nod has no adapters for, by
    /// slug. Resolved separately from a search because a connected product has
    /// to name and draw itself whether or not it happens to be in the results.
    @Published private(set) var connected: [String: CatalogueApp] = [:]

    private let supabase: SupabaseClient?
    /// The fetch for each mark, not the mark: two rows asking for the same slug
    /// while the first is in flight would otherwise both hit the network, which
    /// is the common case when consecutive searches share rows.
    private var marks: [String: Task<NSImage?, Never>] = [:]
    /// Slugs a request is already in flight for. Settings and the chat composer
    /// both ask on the same signal, and without this they both fan out.
    private var resolving: Set<String> = []

    init(supabase: SupabaseClient?) {
        self.supabase = supabase
    }

    /// Names the products behind a set of connected slugs.
    ///
    /// Only asks for what it does not already hold: this runs whenever the
    /// connection list changes, which during a connect is every couple of
    /// seconds.
    func resolve(_ slugs: Set<String>) async {
        guard let supabase else { return }
        let missing = slugs.subtracting(connected.keys).subtracting(resolving)
        guard !missing.isEmpty else { return }
        resolving.formUnion(missing)
        defer { resolving.subtract(missing) }

        struct Request: Encodable { let slugs: [String] }
        struct Response: Decodable { let apps: [CatalogueApp] }

        do {
            let response: Response = try await supabase.functions.invoke(
                "integration-catalogue",
                options: FunctionInvokeOptions(body: Request(slugs: Array(missing)))
            )
            for app in response.apps {
                connected[app.slug] = app
            }
        } catch {
            Log.ui.error("catalogue resolve failed: \(error.localizedDescription)")
        }
    }

    /// Decoded bitmaps, one per connected product. `URLCache` makes the refetch
    /// free, so holding them past the screen is memory kept for nothing.
    func forgetMarks() {
        marks.removeAll()
    }

    /// The products behind a set of connected slugs, named and ordered.
    ///
    /// One derivation for the three surfaces that draw this list — a `Set` has
    /// no order, and three copies of the sort meant three chances for two of
    /// them to disagree.
    func apps(for slugs: Set<String>) -> [CatalogueApp] {
        slugs
            .compactMap { connected[$0] }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    /// A catalogue row's mark, cached for as long as the screen is open.
    ///
    /// Fetched through our own function rather than the broker's CDN: a list
    /// that redraws on every keystroke would otherwise have the desktop client
    /// tell a third party what somebody is typing. That also rules out
    /// `AsyncImage`, which cannot carry the anon key the gateway wants — so the
    /// bytes are fetched here, where the result can be kept.
    func mark(for slug: String) async -> NSImage? {
        if let running = marks[slug] { return await running.value }

        let fetch = Task<NSImage?, Never> {
            var request = URLRequest(url: Self.logoURL(slug))
            request.setValue(SupabaseConfig.anonKey, forHTTPHeaderField: "apikey")
            guard let (data, response) = try? await URLSession.shared.data(for: request),
                  (response as? HTTPURLResponse)?.statusCode == 200
            else { return nil }
            return NSImage(data: data)
        }
        marks[slug] = fetch
        return await fetch.value
    }

    private static func logoURL(_ slug: String) -> URL {
        SupabaseConfig.url
            .appendingPathComponent("functions/v1/integration-catalogue")
            .appending(queryItems: [URLQueryItem(name: "logo", value: slug)])
    }
}
