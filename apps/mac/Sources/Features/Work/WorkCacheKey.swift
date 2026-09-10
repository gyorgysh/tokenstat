// SPDX-License-Identifier: LicenseRef-tokenstat-source-available

import Foundation
import Security

/// The per-scope key that seals saved work, held by the system keychain.
///
/// One 256-bit key per account scope (or the local installation), generated
/// on first save and never leaving the keychain except into the sealing call
/// that needs it. The cache file holds ciphertext beside record ids; without
/// this key those rows are sizes and timestamps. Deleting the key is what
/// makes a sign-out purge unrecoverable rather than merely unlisted.
enum WorkCacheKey {
    private static let service = "ai.tokenstat.work-cache"

    /// The scope's key, creating and storing one on first use. Nil when the
    /// keychain itself is unavailable: saving is then skipped, never stored
    /// under a weaker key or written beside the ciphertext.
    static func key(for scope: String, generate: () -> [UInt8] = randomBytes) -> [UInt8]? {
        guard !WorkCacheCleanupJournal.blocks(scope) else { return nil }
        if let held = load(scope: scope) { return held }
        let fresh = generate()
        guard fresh.count == 32 else { return nil }
        guard store(scope: scope, key: fresh) else { return nil }
        return fresh
    }

    @discardableResult
    static func delete(for scope: String) -> Bool {
        let status = SecItemDelete([
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: scope,
        ] as CFDictionary)
        return status == errSecSuccess || status == errSecItemNotFound
    }

    /// The scope's key when one was already stored, creating nothing. Reads
    /// use this: opening a conversation must not leave a keychain entry
    /// behind for a scope that keeps nothing.
    static func existingKey(for scope: String) -> [UInt8]? {
        guard !WorkCacheCleanupJournal.blocks(scope) else { return nil }
        return load(scope: scope)
    }

    /// Base64 for the wire, which takes the key as text beside the call.
    static func encoded(_ key: [UInt8]) -> String {
        Data(key).base64EncodedString()
    }

    private static func randomBytes() -> [UInt8] {
        var bytes = [UInt8](repeating: 0, count: 32)
        guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else { return [] }
        return bytes
    }

    private static func load(scope: String) -> [UInt8]? {
        var result: CFTypeRef?
        let status = SecItemCopyMatching([
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: scope,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ] as CFDictionary, &result)
        guard status == errSecSuccess, let data = result as? Data, data.count == 32 else { return nil }
        return Array(data)
    }

    private static func store(scope: String, key: [UInt8]) -> Bool {
        SecItemDelete([
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: scope,
        ] as CFDictionary)
        // Readable after first unlock so a cold open in airplane mode still
        // finds its copies; this device only, so a backup never carries it.
        let status = SecItemAdd([
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: scope,
            kSecValueData as String: Data(key),
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
        ] as CFDictionary, nil)
        return status == errSecSuccess
    }
}
