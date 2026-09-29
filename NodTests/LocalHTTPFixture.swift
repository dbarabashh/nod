import Foundation
import Supabase
import XCTest

actor LocalHTTPRoutes {
    typealias Handler = @Sendable (URLRequest) async throws -> (Int, Data)
    static let shared = LocalHTTPRoutes()
    private var routes: [String: Handler] = [:]

    func register(host: String, handler: @escaping Handler) {
        routes[host] = handler
    }

    func remove(host: String) {
        routes[host] = nil
    }

    func response(to request: URLRequest) async throws -> (Int, Data) {
        guard let host = request.url?.host, let handler = routes[host] else {
            throw URLError(.unsupportedURL)
        }
        return try await handler(request)
    }
}

final class LocalHTTPProtocol: URLProtocol, @unchecked Sendable {
    private var loading: Task<Void, Never>?

    override class func canInit(with request: URLRequest) -> Bool {
        true
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        loading = Task {
            do {
                let (status, data) = try await LocalHTTPRoutes.shared.response(to: request)
                guard !Task.isCancelled, let url = request.url,
                      let response = HTTPURLResponse(
                          url: url,
                          statusCode: status,
                          httpVersion: nil,
                          headerFields: ["Content-Type": "application/json"]
                      ) else { return }
                client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
                client?.urlProtocol(self, didLoad: data)
                client?.urlProtocolDidFinishLoading(self)
            } catch {
                guard !Task.isCancelled else { return }
                client?.urlProtocol(self, didFailWithError: error)
            }
        }
    }

    override func stopLoading() {
        loading?.cancel()
    }
}

struct LocalAuthStorage: AuthLocalStorage {
    let data: Data
    func store(key: String, value: Data) throws {}
    func retrieve(key: String) throws -> Data? {
        key == "local-auth" ? data : nil
    }

    func remove(key: String) throws {}
}

@MainActor
struct LocalHTTPFixture {
    let client: SupabaseClient
    let host: String
    let session: URLSession

    init(userID: UUID, handler: @escaping LocalHTTPRoutes.Handler) async throws {
        host = "\(UUID().uuidString.lowercased()).invalid"
        await LocalHTTPRoutes.shared.register(host: host, handler: handler)
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [LocalHTTPProtocol.self]
        session = URLSession(configuration: config)
        let user = User(
            id: userID,
            appMetadata: [:],
            userMetadata: [:],
            aud: "authenticated",
            createdAt: Date(),
            updatedAt: Date()
        )
        let authSession = Session(
            accessToken: "local-test",
            tokenType: "bearer",
            expiresIn: 3600,
            expiresAt: Date().addingTimeInterval(3600).timeIntervalSince1970,
            refreshToken: "local-refresh",
            user: user
        )
        client = try SupabaseClient(
            supabaseURL: XCTUnwrap(URL(string: "https://\(host)")), supabaseKey: "local-test",
            options: .init(
                auth: .init(
                    storage: LocalAuthStorage(data: JSONEncoder().encode(authSession)),
                    storageKey: "local-auth",
                    autoRefreshToken: false,
                    emitLocalSessionAsInitialSession: true
                ),
                global: .init(session: session)
            )
        )
        _ = try await client.auth.session
    }

    func close() async {
        session.invalidateAndCancel()
        await LocalHTTPRoutes.shared.remove(host: host)
    }
}
