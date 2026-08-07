import CryptoKit
import Foundation
import Supabase

/// Manages the user's external agent connections (Settings → Connections).
///
/// Minting is privacy-preserving: the raw `nod_pat_…` token is generated and
/// hashed ON-DEVICE; only the hex sha256 is sent to `create_connection`. The
/// caller shows the raw token to the user exactly once — it can never be
/// recovered afterwards, only revoked and reissued.
@MainActor
final class ConnectionService: ObservableObject {
    struct Rollout: Equatable {
        let officialConnectorsEnabled: Bool
        let chatGPTURL: URL?
        let claudeURL: URL?
        let legacyPATSunsetAt: Date?

        static let disabled = Rollout(
            officialConnectorsEnabled: false,
            chatGPTURL: nil,
            claudeURL: nil,
            legacyPATSunsetAt: nil
        )
    }

    @Published private(set) var connections: [Connection] = []
    @Published private(set) var rollout = Rollout.disabled
    @Published private(set) var isLoading = false
    @Published var lastError: String?

    private let supabase: SupabaseClient

    init(supabase: SupabaseClient) {
        self.supabase = supabase
    }

    func refresh() async {
        isLoading = true
        defer { isLoading = false }
        do {
            connections = try await supabase
                .from("connections")
                .select("id,name,client,created_at,last_used_at,revoked_at")
                .is("revoked_at", value: nil)
                .order("created_at", ascending: false)
                .execute()
                .value
            lastError = nil
        } catch {
            lastError = "Couldn't load your connections."
            Log.ui.error("ConnectionService.refresh failed: \(error.localizedDescription)")
        }
        do {
            struct Config: Decodable {
                let officialConnectorsEnabled: Bool
                let chatGPTConnectorURL: String?
                let claudeConnectorURL: String?
                let legacyPATSunsetAt: Date?

                enum CodingKeys: String, CodingKey {
                    case officialConnectorsEnabled = "official_connectors_enabled"
                    case chatGPTConnectorURL = "chatgpt_connector_url"
                    case claudeConnectorURL = "claude_connector_url"
                    case legacyPATSunsetAt = "legacy_pat_sunset_at"
                }
            }
            let configs: [Config] = try await supabase
                .from("app_config")
                .select("official_connectors_enabled,chatgpt_connector_url,claude_connector_url,legacy_pat_sunset_at")
                .limit(1)
                .execute()
                .value
            guard let config = configs.first else {
                rollout = .disabled
                return
            }
            rollout = Rollout(
                officialConnectorsEnabled: config.officialConnectorsEnabled,
                chatGPTURL: config.chatGPTConnectorURL.flatMap(URL.init(string:)),
                claudeURL: config.claudeConnectorURL.flatMap(URL.init(string:)),
                legacyPATSunsetAt: config.legacyPATSunsetAt
            )
        } catch {
            rollout = .disabled
            Log.ui.error("ConnectionService rollout refresh failed: \(error.localizedDescription)")
        }
    }

    /// Generates a token, sends only its sha256 to the server, and returns the
    /// raw token so the caller can show it once. Throws on failure so the UI can
    /// surface it inline.
    func create(name: String, client: ConnectionClient) async throws -> String {
        let raw = Self.generateToken()
        let hash = Self.sha256Hex(raw)
        struct Params: Encodable {
            let p_name: String
            let p_client: String
            let p_token_hash: String
        }
        try await supabase
            .rpc("create_connection", params: Params(p_name: name, p_client: client.rawValue, p_token_hash: hash))
            .execute()
        await refresh()
        return raw
    }

    func revoke(_ connection: Connection) async {
        do {
            struct Params: Encodable { let p_id: UUID }
            try await supabase
                .rpc("revoke_connection", params: Params(p_id: connection.id))
                .execute()
            await refresh()
        } catch {
            lastError = "Couldn't revoke the connection."
            Log.ui.error("ConnectionService.revoke failed: \(error.localizedDescription)")
        }
    }

    /// A cryptographically random `nod_pat_<48 hex>` token. Uses the system
    /// CSPRNG; the prefix aids secret-scanning and human recognition.
    private static func generateToken() -> String {
        var rng = SystemRandomNumberGenerator()
        let bytes = (0 ..< 24).map { _ in UInt8.random(in: .min ... .max, using: &rng) }
        return "nod_pat_" + bytes.map { String(format: "%02x", $0) }.joined()
    }

    private static func sha256Hex(_ value: String) -> String {
        SHA256.hash(data: Data(value.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
    }
}
