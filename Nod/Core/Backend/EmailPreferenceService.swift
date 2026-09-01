import Combine
import Foundation
import Supabase

/// The three optional email topics. Every one starts off and only ever turns on
/// because someone chose it — Supabase is authoritative, Resend is a mirror.
enum EmailTopic: String, CaseIterable, Identifiable, Hashable {
    case productUpdates = "product_updates"
    case lifecycleGuidance = "lifecycle_guidance"
    case founderResearch = "founder_research"

    var id: String {
        rawValue
    }

    var title: String {
        switch self {
        case .productUpdates: "Product updates"
        case .lifecycleGuidance: "Tips for getting more out of Nod"
        case .founderResearch: "Founder research"
        }
    }

    var detail: String {
        switch self {
        case .productUpdates:
            "Occasional product news, offers, and referral announcements."
        case .lifecycleGuidance:
            "During a trial: learning emails on days 1, 4, and 10. After that: an occasional useful nudge."
        case .founderResearch:
            "Notes from Vlad about how Nod is working for you, sometimes with an optional call."
        }
    }

    var policyVersion: String {
        self == .lifecycleGuidance ? "communications-v2" : "communications-v1"
    }

    var icon: String {
        switch self {
        case .productUpdates: "nc-sparkle-3"
        case .lifecycleGuidance: "nc-lightbulb-3"
        case .founderResearch: "nc-users"
        }
    }
}

enum EmailPreferenceSource: String {
    case onboardingPrompt = "onboarding_prompt"
    case existingUserPrompt = "existing_user_prompt"
    case settings = "macos_settings"
}

/// What the server holds for one account: a status per topic plus whether this
/// version of the consent prompt has been seen.
struct EmailPreferenceSnapshot: Equatable {
    var subscribed: Set<EmailTopic> = []
    var policyVersions: [EmailTopic: String] = [:]
    var promptSeen = false
    var hasSeenV1Prompt = false
    var promptVersion: String?

    func isSubscribed(to topic: EmailTopic) -> Bool {
        subscribed.contains(topic)
    }

    func hasSeenPrompt(version: String) -> Bool {
        promptSeen && promptVersion == version
    }
}

@MainActor
protocol EmailPreferenceRepository {
    func preferences() async throws -> EmailPreferenceSnapshot
    func setPreference(topic: EmailTopic, subscribed: Bool, source: EmailPreferenceSource) async throws
    /// One prompt's whole outcome — see `save_email_consent`. An empty
    /// `choices` records only that the prompt was seen.
    func saveConsent(choices: [EmailTopic: Bool], source: EmailPreferenceSource) async throws
}

struct SupabaseEmailPreferenceRepository: EmailPreferenceRepository {
    let supabase: SupabaseClient

    private struct PreferencesResponse: Decodable {
        struct Row: Decodable {
            let topic: String
            let status: String
            let policyVersion: String?

            enum CodingKeys: String, CodingKey {
                case topic, status
                case policyVersion = "policy_version"
            }
        }

        let preferences: [Row]?
        let promptSeen: Bool
        let hasSeenV1Prompt: Bool?
        let promptVersion: String?

        enum CodingKeys: String, CodingKey {
            case preferences
            case promptSeen = "prompt_seen"
            case hasSeenV1Prompt = "has_seen_v1_prompt"
            case promptVersion = "prompt_version"
        }
    }

    func preferences() async throws -> EmailPreferenceSnapshot {
        let response: PreferencesResponse = try await supabase
            .rpc("get_email_preferences")
            .execute()
            .value
        var snapshot = EmailPreferenceSnapshot()
        for row in response.preferences ?? [] {
            guard let topic = EmailTopic(rawValue: row.topic) else { continue }
            snapshot.policyVersions[topic] = row.policyVersion
            if row.status == "subscribed" { snapshot.subscribed.insert(topic) }
        }
        snapshot.promptSeen = response.promptSeen
        snapshot.hasSeenV1Prompt = response.hasSeenV1Prompt ?? false
        snapshot.promptVersion = response.promptVersion
        return snapshot
    }

    func setPreference(topic: EmailTopic, subscribed: Bool, source: EmailPreferenceSource) async throws {
        struct Params: Encodable {
            let pTopic: String
            let pStatus: String
            let pPolicyVersion: String
            let pSource: String

            enum CodingKeys: String, CodingKey {
                case pTopic = "p_topic"
                case pStatus = "p_status"
                case pPolicyVersion = "p_policy_version"
                case pSource = "p_source"
            }
        }

        try await supabase
            .rpc("set_email_preference", params: Params(
                pTopic: topic.rawValue,
                pStatus: subscribed ? "subscribed" : "unsubscribed",
                pPolicyVersion: topic.policyVersion,
                pSource: source.rawValue
            ))
            .execute()
    }

    /// Every topic plus the prompt itself, written together. The server runs it
    /// in one transaction, so a rejected topic leaves nothing behind rather than
    /// recording a choice the person was then told had failed.
    func saveConsent(choices: [EmailTopic: Bool], source: EmailPreferenceSource) async throws {
        struct Choice: Encodable {
            let topic: String
            let status: String
            let policyVersion: String

            enum CodingKeys: String, CodingKey {
                case topic, status
                case policyVersion = "policy_version"
            }
        }

        struct Params: Encodable {
            let pChoices: [Choice]
            let pPromptVersion: String
            let pSource: String

            enum CodingKeys: String, CodingKey {
                case pChoices = "p_choices"
                case pPromptVersion = "p_prompt_version"
                case pSource = "p_source"
            }
        }

        try await supabase
            .rpc("save_email_consent", params: Params(
                // Ordered, so the request bytes are the same for the same
                // answer — a dictionary's order is not.
                pChoices: EmailTopic.allCases.compactMap { topic in
                    choices[topic].map {
                        Choice(
                            topic: topic.rawValue,
                            status: $0 ? "subscribed" : "unsubscribed",
                            policyVersion: topic.policyVersion
                        )
                    }
                },
                pPromptVersion: EmailPreferenceService.promptVersion,
                pSource: source.rawValue
            ))
            .execute()
    }
}

@MainActor
final class EmailPreferenceService: ObservableObject {
    /// Consent is recorded against the policy it was given under. The server
    /// rejects a write carrying a stale version, so bumping this here without
    /// publishing the policy fails loudly instead of silently mislabelling.
    static let promptVersion = "communications-v2"

    @Published private(set) var snapshot = EmailPreferenceSnapshot()
    @Published private(set) var hasLoaded = false
    @Published private(set) var isLoading = false
    @Published private(set) var savingTopics: Set<EmailTopic> = []
    @Published private(set) var isSavingPrompt = false
    @Published private(set) var lastError: String?

    private let repository: (any EmailPreferenceRepository)?
    private let hasSession: () -> Bool
    private let analytics: ProductAnalytics?
    /// Bumped by `clear()`. An in-flight response for the previous account is
    /// dropped rather than applied to whoever signed in next.
    private var revision = 0

    init(supabase: SupabaseClient? = nil, auth: AuthService? = nil, analytics: ProductAnalytics? = nil) {
        repository = supabase.map(SupabaseEmailPreferenceRepository.init)
        hasSession = { [weak auth] in auth?.session != nil }
        self.analytics = analytics
    }

    /// True once we know the server has never shown this person the current
    /// prompt. Never true before loading, so nobody sees it twice.
    var shouldPresentPrompt: Bool {
        hasLoaded && !snapshot.hasSeenPrompt(version: Self.promptVersion)
    }

    var shouldPresentFullPrompt: Bool {
        shouldPresentPrompt && !snapshot.hasSeenV1Prompt
    }

    var shouldPresentUpgradePrompt: Bool {
        shouldPresentPrompt && snapshot.hasSeenV1Prompt
    }

    var isBusy: Bool {
        isLoading || isSavingPrompt || !savingTopics.isEmpty
    }

    var subscribedCount: Int {
        snapshot.subscribed.count
    }

    func isSubscribed(to topic: EmailTopic) -> Bool {
        snapshot.isSubscribed(to: topic)
    }

    func isSaving(_ topic: EmailTopic) -> Bool {
        savingTopics.contains(topic)
    }

    func refresh() async {
        guard let repository, hasSession() else {
            clear()
            return
        }
        guard !isBusy else { return }
        let current = revision
        isLoading = true
        lastError = nil
        defer { if current == revision { isLoading = false } }

        do {
            let refreshed = try await repository.preferences()
            guard current == revision, hasSession() else { return }
            snapshot = refreshed
            hasLoaded = true
        } catch {
            guard current == revision else { return }
            Log.ui.error("email preferences refresh failed: \(error.localizedDescription)")
            lastError = "Couldn't load your email choices. Please try again."
        }
    }

    @discardableResult
    func setPreference(_ subscribed: Bool, for topic: EmailTopic, source: EmailPreferenceSource = .settings) async -> Bool {
        guard let repository, hasSession() else {
            lastError = "Sign in to change your email choices."
            return false
        }
        guard !savingTopics.contains(topic) else { return false }
        if source == .settings, snapshot.isSubscribed(to: topic) == subscribed { return true }

        let current = revision
        savingTopics.insert(topic)
        lastError = nil
        defer { if current == revision { savingTopics.remove(topic) } }

        do {
            try await repository.setPreference(topic: topic, subscribed: subscribed, source: source)
            guard current == revision, hasSession() else { return false }
            apply(subscribed, to: topic)
            Log.ui.info("email preference saved topic=\(topic.rawValue) subscribed=\(subscribed)")
            return true
        } catch {
            guard current == revision else { return false }
            Log.ui.error("email preference save failed topic=\(topic.rawValue): \(error.localizedDescription)")
            lastError = "Couldn't save your email choices. Please try again."
            return false
        }
    }

    /// Writes every topic, then records that the prompt was answered. The order
    /// matters: if a write fails the prompt stays unanswered, so the person is
    /// asked again rather than silently left with a half-saved choice.
    @discardableResult
    func savePromptSelection(_ selected: Set<EmailTopic>, source: EmailPreferenceSource) async -> Bool {
        guard let repository, hasSession() else {
            lastError = "Sign in to save your email choices."
            return false
        }
        guard !isSavingPrompt else { return false }

        let current = revision
        isSavingPrompt = true
        lastError = nil
        defer { if current == revision { isSavingPrompt = false } }

        do {
            try await repository.saveConsent(
                choices: Dictionary(uniqueKeysWithValues: EmailTopic.allCases.map { ($0, selected.contains($0)) }),
                source: source
            )
            guard current == revision, hasSession() else { return false }
            for topic in EmailTopic.allCases {
                apply(selected.contains(topic), to: topic)
            }
            snapshot.promptSeen = true
            snapshot.promptVersion = Self.promptVersion
            hasLoaded = true
            Log.ui.info("email consent prompt answered source=\(source.rawValue) topics=\(selected.count)")
            analytics?.record(
                .emailConsentSaved,
                properties: .init(
                    entryPoint: source == .onboardingPrompt ? .appLaunch : .mainWindow,
                    stage: .consent,
                    surface: source == .onboardingPrompt ? .onboarding : .home,
                    outcome: selected.isEmpty ? .declined : .granted
                )
            )
            return true
        } catch {
            guard current == revision else { return false }
            Log.ui.error("email consent prompt save failed: \(error.localizedDescription)")
            lastError = "Couldn't save your email choices. Please try again."
            return false
        }
    }

    @discardableResult
    func saveLifecycleUpgrade(subscribed: Bool) async -> Bool {
        guard let repository, hasSession() else {
            lastError = "Sign in to save your email choices."
            return false
        }
        guard !isSavingPrompt else { return false }
        let current = revision
        isSavingPrompt = true
        lastError = nil
        defer { if current == revision { isSavingPrompt = false } }
        do {
            // Declining writes no preference at all — the other two topics were
            // not on this card, and rewriting them would stamp them as answered
            // here. An empty `choices` marks only that the prompt was seen.
            try await repository.saveConsent(
                choices: subscribed ? [.lifecycleGuidance: true] : [:],
                source: .existingUserPrompt
            )
            guard current == revision, hasSession() else { return false }
            if subscribed { apply(true, to: .lifecycleGuidance) }
            snapshot.promptSeen = true
            snapshot.promptVersion = Self.promptVersion
            return true
        } catch {
            guard current == revision else { return false }
            Log.ui.error("lifecycle consent upgrade failed: \(error.localizedDescription)")
            lastError = "Couldn't save your email choice. Please try again."
            return false
        }
    }

    func clear() {
        revision += 1
        snapshot = EmailPreferenceSnapshot()
        hasLoaded = false
        isLoading = false
        savingTopics = []
        isSavingPrompt = false
        lastError = nil
    }

    private func apply(_ subscribed: Bool, to topic: EmailTopic) {
        if subscribed {
            snapshot.subscribed.insert(topic)
        } else {
            snapshot.subscribed.remove(topic)
        }
        hasLoaded = true
    }
}
