import Foundation
import os
import Security
import Supabase

/// Session storage for the Supabase client, replacing `KeychainLocalStorage`.
///
/// The SDK default hits the keychain on every call that needs a token — ~65
/// reads a minute in a running app — and its query omits
/// `kSecUseDataProtectionKeychain`, so on macOS each one goes through the
/// legacy CSSM-backed login keychain. When that keychain is degraded, CSSM
/// raises a C++ `Security::CssmError`, which Swift cannot catch and which
/// terminates the process. Caching collapses those reads to one per key per
/// launch, and preferring the data-protection keychain leaves CSSM out of the
/// path entirely.
final class AuthSessionStorage: AuthLocalStorage {
    enum StorageError: Error {
        case keychain(OSStatus)
    }

    private struct State {
        var cache = SessionCache()
        var legacyOnly = false
    }

    private let service: String
    /// The protocol is synchronous and `Sendable`, and the SDK calls it from
    /// whatever context needs a token — an actor can't satisfy that shape.
    private let state = OSAllocatedUnfairLock(initialState: State())

    init(service: String = "supabase.gotrue.swift") {
        self.service = service
    }

    func store(key: String, value: Data) throws {
        // The SDK re-stores the session on almost every read of it — its own
        // storage migration re-encodes and writes back — and each of those is
        // a keychain round trip for bytes already there.
        guard state.withLock({ $0.cache.value(for: key) }) != .some(value) else { return }
        try write(value, for: key)
        state.withLock { $0.cache.set(value, for: key) }
    }

    func retrieve(key: String) throws -> Data? {
        if let cached = state.withLock({ $0.cache.value(for: key) }) {
            return cached
        }
        var stored: Data?
        // Cached on the way out whether the read answered or threw: a failure
        // reaches its answer the slow way — a degraded login keychain answers
        // through securityd — and the SDK reports a throw as "no session"
        // regardless, so repeating it only stalls whoever asks next.
        defer { state.withLock { $0.cache.fill(stored, for: key) } }
        stored = try read(key)
        return stored
    }

    func remove(key: String) throws {
        SecItemDelete(baseQuery(key, dataProtection: true) as CFDictionary)
        SecItemDelete(baseQuery(key, dataProtection: false) as CFDictionary)
        state.withLock { $0.cache.set(nil, for: key) }
    }

    private func read(_ key: String) throws -> Data? {
        if state.withLock({ !$0.legacyOnly }) {
            let item = copyItem(key, dataProtection: true)
            switch item.status {
            case errSecSuccess:
                return item.data
            case errSecItemNotFound:
                return adoptLegacyItem(key)
            case errSecMissingEntitlement:
                fallBackToLegacy()
            case let status:
                throw keychainFailure(status, key: key, operation: "read")
            }
        }

        let legacy = copyItem(key, dataProtection: false)
        switch legacy.status {
        case errSecSuccess:
            return legacy.data
        case errSecItemNotFound:
            return nil
        case let status:
            throw keychainFailure(status, key: key, operation: "read legacy")
        }
    }

    /// The SDK catches whatever `retrieve` throws and reports "no session"
    /// (`SessionStorage.live`), so an unreadable keychain is indistinguishable
    /// from a signed-out user — the app lands on the login screen with nothing
    /// anywhere saying why. This is the only place that still knows.
    private func keychainFailure(_ status: OSStatus, key: String, operation: String) -> StorageError {
        let message = SecCopyErrorMessageString(status, nil) as String? ?? "unknown"
        Log.auth.error("session storage: \(operation) failed for \(key) — OSStatus=\(status) (\(message))")
        return StorageError.keychain(status)
    }

    /// Carries a session written by an earlier build over to the
    /// data-protection keychain, so upgrading doesn't sign everyone out. Runs
    /// at most once per key per launch — after it the cache answers.
    private func adoptLegacyItem(_ key: String) -> Data? {
        let legacy = copyItem(key, dataProtection: false)
        guard legacy.status == errSecSuccess, let data = legacy.data else {
            return nil
        }
        do {
            try write(data, for: key)
        } catch {
            // The session is in hand. Failing to carry it forward is not a
            // reason to report the user signed out — it stays where it was,
            // for the next launch to try again.
            return data
        }
        // Only once the copy is somewhere else. Without the entitlement the
        // write falls back to the legacy keychain, so deleting "the old one"
        // deletes the only one — which signed the user out on every launch.
        guard state.withLock({ !$0.legacyOnly }) else { return data }
        SecItemDelete(baseQuery(key, dataProtection: false) as CFDictionary)
        Log.auth.info("session storage: adopted session into the data-protection keychain")
        return data
    }

    private func write(_ data: Data, for key: String) throws {
        if state.withLock({ !$0.legacyOnly }) {
            switch upsert(data, for: key, dataProtection: true) {
            case errSecSuccess:
                return
            case errSecMissingEntitlement:
                fallBackToLegacy()
            case let status:
                throw keychainFailure(status, key: key, operation: "write")
            }
        }

        let status = upsert(data, for: key, dataProtection: false)
        guard status == errSecSuccess else {
            throw keychainFailure(status, key: key, operation: "write legacy")
        }
    }

    private func upsert(_ data: Data, for key: String, dataProtection: Bool) -> OSStatus {
        let query = baseQuery(key, dataProtection: dataProtection)
        let updated = SecItemUpdate(
            query as CFDictionary,
            [kSecValueData as String: data] as CFDictionary
        )
        guard updated == errSecItemNotFound else { return updated }

        var insert = query
        insert[kSecValueData as String] = data
        if dataProtection {
            insert[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        }
        return SecItemAdd(insert as CFDictionary, nil)
    }

    private func copyItem(_ key: String, dataProtection: Bool) -> (status: OSStatus, data: Data?) {
        var query = baseQuery(key, dataProtection: dataProtection)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        return (status, result as? Data)
    }

    private func baseQuery(_ key: String, dataProtection: Bool) -> [String: Any] {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key
        ]
        if dataProtection {
            query[kSecUseDataProtectionKeychain as String] = true
        }
        return query
    }

    private func fallBackToLegacy() {
        state.withLock { $0.legacyOnly = true }
        Log.auth.info("session storage: data-protection keychain unavailable, using legacy")
    }
}

/// What `AuthSessionStorage` remembers between keychain trips, and the rules
/// for what a late answer may overwrite. Its own type because those rules
/// decide whether a user stays signed in, and no keychain can be stood up in
/// a test bundle to exercise them through the storage itself.
struct SessionCache {
    private enum Entry {
        case read(Data?)
        case written(Data?)
    }

    private var entries: [String: Entry] = [:]

    /// `.some(nil)` — looked for, not there — is an answer worth keeping;
    /// `nil` means the key has not been looked for yet.
    func value(for key: String) -> Data?? {
        switch entries[key] {
        case nil: nil
        case let .read(data), let .written(data): data
        }
    }

    /// A session found wins over a session missed: two readers can be inside
    /// the legacy adoption at once, and the one that looks after the item was
    /// moved finds nothing where the other found a session. Neither may undo
    /// what the app itself wrote while they were reading.
    mutating func fill(_ value: Data?, for key: String) {
        switch entries[key] {
        case .written: return
        case let .read(found) where found != nil: return
        default: entries[key] = .read(value)
        }
    }

    /// What the app itself just wrote or deleted.
    mutating func set(_ value: Data?, for key: String) {
        entries[key] = .written(value)
    }
}
