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
        var entries: [String: Data?] = [:]
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
        try write(value, for: key)
        state.withLock { $0.entries[key] = value }
    }

    func retrieve(key: String) throws -> Data? {
        if let cached = state.withLock({ $0.entries[key] }) {
            return cached
        }
        let stored = try read(key)
        state.withLock { $0.entries[key] = stored }
        return stored
    }

    func remove(key: String) throws {
        SecItemDelete(baseQuery(key, dataProtection: true) as CFDictionary)
        SecItemDelete(baseQuery(key, dataProtection: false) as CFDictionary)
        state.withLock { $0.entries[key] = Data?.none }
    }

    private func read(_ key: String) throws -> Data? {
        if state.withLock({ !$0.legacyOnly }) {
            let item = copyItem(key, dataProtection: true)
            switch item.status {
            case errSecSuccess:
                return item.data
            case errSecItemNotFound:
                return try adoptLegacyItem(key)
            case errSecMissingEntitlement:
                fallBackToLegacy()
            case let status:
                throw StorageError.keychain(status)
            }
        }

        let legacy = copyItem(key, dataProtection: false)
        switch legacy.status {
        case errSecSuccess:
            return legacy.data
        case errSecItemNotFound:
            return nil
        case let status:
            throw StorageError.keychain(status)
        }
    }

    /// Carries a session written by an earlier build over to the
    /// data-protection keychain, so upgrading doesn't sign everyone out. Runs
    /// at most once per key per launch — after it the cache answers.
    private func adoptLegacyItem(_ key: String) throws -> Data? {
        let legacy = copyItem(key, dataProtection: false)
        guard legacy.status == errSecSuccess, let data = legacy.data else {
            return nil
        }
        try write(data, for: key)
        SecItemDelete(baseQuery(key, dataProtection: false) as CFDictionary)
        Log.auth.info("session storage: adopted session from the legacy keychain")
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
                throw StorageError.keychain(status)
            }
        }

        let status = upsert(data, for: key, dataProtection: false)
        guard status == errSecSuccess else {
            throw StorageError.keychain(status)
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
