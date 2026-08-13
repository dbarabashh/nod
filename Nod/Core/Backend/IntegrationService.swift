import AppKit
import Foundation
import Supabase

/// Outbound integrations: which providers the user has linked, and starting the
/// authorization when they haven't.
///
/// Authorization runs in the browser, not in the app — `integration-connect`
/// mints a Nango Connect session and we open the link it returns. The result
/// comes back out of band, through Nango's webhook into
/// `integration_connections`, so after opening the browser the only way to learn
/// the outcome is to watch the table.
@MainActor
final class IntegrationService: ObservableObject {
    @Published private(set) var linked: Set<IntegrationProvider> = []
    /// The products a task can be filed in right now — connected, and able to
    /// take one. Stored rather than computed: it is read from a view body once
    /// per action-item row, and changes only when `linked` does.
    @Published private(set) var taskTargets: [IntegrationProvider] = []
    @Published private(set) var pending: IntegrationProvider?
    @Published private(set) var isLoading = false
    @Published var lastError: String?

    private let supabase: SupabaseClient
    private var watch: Task<Void, Never>?
    private var hasLoaded = false

    init(supabase: SupabaseClient) {
        self.supabase = supabase
    }

    deinit {
        watch?.cancel()
    }

    /// Loads the links once per launch. The chat needs to know what's connected
    /// before it can offer any tools, and it can't wait for the user to have
    /// visited Settings first.
    func refreshIfNeeded() async {
        guard !hasLoaded else { return }
        await refresh()
    }

    func refresh() async {
        isLoading = true
        defer { isLoading = false }
        do {
            let rows: [IntegrationConnection] = try await supabase
                .from("integration_connections")
                .select("provider")
                .is("revoked_at", value: nil)
                .execute()
                .value
            linked = Set(rows.compactMap { IntegrationProvider(rawValue: $0.provider) })
            taskTargets = linked
                .filter { ChatTools.taskAction(for: $0) != nil }
                .sorted { $0.rawValue < $1.rawValue }
            hasLoaded = true
            lastError = nil
            Log.ui.info("integrations linked=\(linked.map(\.rawValue).sorted().joined(separator: ","))")
        } catch {
            lastError = "Couldn't load your integrations."
            Log.ui.error("IntegrationService.refresh failed: \(error.localizedDescription)")
        }
    }

    /// Opens the provider's authorization page and then watches for the webhook
    /// to land. Safe to call again while one is pending — the previous watch is
    /// replaced rather than stacked.
    func connect(_ provider: IntegrationProvider) async {
        pending = provider
        lastError = nil
        struct Request: Encodable { let provider: String }
        struct Response: Decodable { let connectLink: URL }

        do {
            let response: Response = try await supabase.functions.invoke(
                "integration-connect",
                options: FunctionInvokeOptions(body: Request(provider: provider.rawValue))
            )
            Log.ui.info("IntegrationService.connect opening authorization for \(provider.rawValue)")
            NSWorkspace.shared.open(response.connectLink)
            watchForConnection(provider)
        } catch {
            pending = nil
            lastError = "Couldn't start authorization. Please try again."
            Log.ui.error("IntegrationService.connect failed: \(error.localizedDescription)")
        }
    }

    /// Composes an action item into a task and files it.
    ///
    /// Composition lives here rather than in the view: how much of an item
    /// becomes a title and what falls to the body is a decision about what Nod
    /// sends to a third party, which is not a rendering concern.
    func file(_ item: ActionItem, in provider: IntegrationProvider) async -> ProviderLinkItem? {
        guard let action = ChatTools.taskAction(for: provider) else { return nil }
        var body: [String] = []
        if item.text.count > Self.titleLimit { body.append(item.text) }
        if let deadline = item.deadline, !deadline.isEmpty { body.append("Due: \(deadline)") }

        return await createTask(
            title: String(item.text.prefix(Self.titleLimit)),
            description: body.isEmpty ? nil : body.joined(separator: "\n\n"),
            in: provider,
            action: action
        )
    }

    /// Trackers show titles in one line; the rest of a long item, and the
    /// deadline as it was actually said, belong in the body.
    private static let titleLimit = 120

    /// Files a task and returns where it landed.
    ///
    /// Not routed through the chat's tool approval: that gate exists because a
    /// model decided to act. Here the user clicked a specific item, which is the
    /// decision — asking again would be confirming what they just did.
    private func createTask(
        title: String,
        description: String?,
        in provider: IntegrationProvider,
        action: String
    ) async -> ProviderLinkItem? {
        struct FiledTask: Decodable {
            let key: String
            let title: String
            let url: String
        }
        struct Response: Decodable {
            let result: FiledTask?
        }

        var params = ["title": title]
        if let description, !description.isEmpty { params["description"] = description }

        do {
            let data = try await invokeAction(provider: provider, action: action, params: params)
            let body = String(bytes: data, encoding: .utf8) ?? ""
            if let message = Self.failure(in: body) {
                Log.ui.error("IntegrationService.file refused: \(message)")
                return nil
            }
            guard let filed = try? JSONDecoder().decode(Response.self, from: data).result,
                  let url = URL(string: filed.url)
            else { return nil }
            Log.ui.info("IntegrationService.file filed \(filed.key)")
            return ProviderLinkItem(provider: provider, title: filed.key, url: url)
        } catch {
            Log.ui.error("IntegrationService.file failed: \(error.localizedDescription)")
            return nil
        }
    }

    func cancelPending() {
        watch?.cancel()
        watch = nil
        pending = nil
    }

    /// Polls until the provider shows up or the session's own lifetime is spent.
    /// Nango connect links expire in 30 minutes, but a user who wandered off is
    /// better served by the row appearing on the next `refresh()` than by us
    /// polling for half an hour.
    private func watchForConnection(_ provider: IntegrationProvider) {
        watch?.cancel()
        watch = Task { [weak self] in
            for _ in 0 ..< Self.watchAttempts {
                try? await Task.sleep(nanoseconds: Self.watchInterval)
                if Task.isCancelled { return }
                guard let self else { return }
                await refresh()
                if linked.contains(provider) {
                    pending = nil
                    return
                }
            }
            self?.pending = nil
        }
    }

    /// Runs an approved tool call against `integration-action`.
    ///
    /// Never throws: a failure the model can act on — not connected, several
    /// teams, the provider said no — is worth more as a readable result than as
    /// a broken turn. A thrown error would end the agent's turn and lose the
    /// question.
    func run(_ call: ChatToolCall, tool: ChatTool) async -> String {
        do {
            let response = try await invokeAction(
                provider: tool.provider,
                action: tool.action,
                params: call.arguments
            )
            Log.llm.info("tool \(tool.name) returned \(response.count) bytes")
            return String(bytes: response, encoding: .utf8) ?? Self.unreadableResult
        } catch {
            Log.llm.error("tool \(tool.name) failed: \(error.localizedDescription)")
            return #"{"error":{"code":"unreachable","message":"The action could not be run."}}"#
        }
    }

    /// The one door to `integration-action`.
    ///
    /// Handed back raw: the body is whatever the provider returned. The chat
    /// gives it to the model as text; the filing button decodes it. Typing it
    /// here would mean re-encoding a line later for one caller, and a shape
    /// mismatch would throw away a result the other could have used.
    private func invokeAction(
        provider: IntegrationProvider,
        action: String,
        params: [String: String]
    ) async throws -> Data {
        struct Request: Encodable {
            let provider: String
            let action: String
            let params: [String: String]
        }
        return try await supabase.functions.invoke(
            "integration-action",
            options: FunctionInvokeOptions(
                body: Request(provider: provider.rawValue, action: action, params: params)
            ),
            decode: { data, _ in data }
        )
    }

    private static let unreadableResult = #"{"error":{"code":"unreadable","message":"The action returned something unreadable."}}"#

    /// The message from an error the action returned, if it returned one. The
    /// wire shape is `{"error":{"code","message"}}` — a failed call still comes
    /// back as a readable result, so this is how the trace tells "did nothing"
    /// from "did something".
    static func failure(in result: String) -> String? {
        guard let data = result.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let error = object["error"] as? [String: Any]
        else { return nil }
        return error["message"] as? String ?? "The action failed."
    }

    /// The result for a call the user refused. The model still needs *an* answer
    /// for every call it made — a missing one makes the next request invalid —
    /// and telling it the user declined is what stops it from trying again.
    static func declinedResult() -> String {
        #"{"error":{"code":"declined","message":"The user declined this action. Do not retry it; answer with what you already know."}}"#
    }

    private static let watchAttempts = 60
    private static let watchInterval: UInt64 = 2_000_000_000
}
