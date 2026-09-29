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

    /// Keychain reads may wait for the security service or an unlock prompt.
    /// Never make the UI executor wait with them. Creation stays on the main
    /// actor after authorization is checked again, so a sign-out during the
    /// read cannot recreate the key its cleanup just removed.
    @MainActor
    static func keyForSaving(for scope: String, canCreate: () -> Bool) async -> [UInt8]? {
        await resolveForSaving(
            read: { await readInBackground(scope: scope) },
            canCreate: { canCreate() && !WorkCacheCleanupJournal.blocks(scope) },
            add: { store(scope: scope, key: $0) }, generate: randomBytes
        )
    }

    @MainActor
    static func resolveForSaving(
        read: () async -> (status: OSStatus, key: [UInt8]?),
        canCreate: () -> Bool, add: ([UInt8]) -> OSStatus,
        generate: () -> [UInt8]
    ) async -> [UInt8]? {
        guard canCreate(), !Task.isCancelled else { return nil }
        let existing = await read()
        guard canCreate(), !Task.isCancelled else { return nil }
        if existing.status == errSecSuccess { return existing.key }
        guard existing.status == errSecItemNotFound else { return nil }
        let fresh = generate()
        guard fresh.count == 32 else { return nil }
        switch add(fresh) {
        case errSecSuccess: return fresh
        case errSecDuplicateItem:
            let winner = await read()
            guard canCreate(), !Task.isCancelled else { return nil }
            return winner.status == errSecSuccess ? winner.key : nil
        default: return nil
        }
    }

    /// Read-only lookup: opening saved work never creates a keychain entry.
    static func existingKeyInBackground(for scope: String) async -> [UInt8]? {
        let result = await readInBackground(scope: scope)
        guard !Task.isCancelled, !WorkCacheCleanupJournal.blocks(scope) else { return nil }
        return result.status == errSecSuccess ? result.key : nil
    }

    private static let reads = WorkCacheKeyReads { scope in
        guard !WorkCacheCleanupJournal.blocks(scope) else { return (errSecInteractionNotAllowed, nil) }
        return load(scope: scope)
    }
    private static func readInBackground(scope: String) async -> (status: OSStatus, key: [UInt8]?) {
        guard !Task.isCancelled else { return (errSecUserCanceled, nil) }
        return await reads.read(scope)
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

    /// Base64 for the wire, which takes the key as text beside the call.
    static func encoded(_ key: [UInt8]) -> String {
        Data(key).base64EncodedString()
    }

    private static func randomBytes() -> [UInt8] {
        var bytes = [UInt8](repeating: 0, count: 32)
        guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else { return [] }
        return bytes
    }

    private static func load(scope: String) -> (status: OSStatus, key: [UInt8]?) {
        var result: CFTypeRef?
        let status = SecItemCopyMatching([
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: scope,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ] as CFDictionary, &result)
        guard status == errSecSuccess else { return (status, nil) }
        guard let data = result as? Data, data.count == 32 else { return (errSecDecode, nil) }
        return (errSecSuccess, Array(data))
    }

    private static func store(scope: String, key: [UInt8]) -> OSStatus {
        // Readable after first unlock so a cold open in airplane mode still
        // finds its copies; this device only, so a backup never carries it.
        let status = SecItemAdd([
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: scope,
            kSecValueData as String: Data(key),
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
        ] as CFDictionary, nil)
        return status
    }
}

/// A stalled security service cannot retain an unbounded number of saved pages
/// or block the UI. Concurrent readers share one lookup per scope. After the
/// deadline, callers fail closed while that lookup finishes; no replacement
/// lookup is started until it returns. Successful keys are never memoized.
final class WorkCacheKeyReads: @unchecked Sendable {
    typealias Result = (status: OSStatus, key: [UInt8]?)
    private struct Pending {
        let id = UUID()
        var expired = false
        var waiters: [CheckedContinuation<Result, Never>]
    }
    private let lock = NSLock()
    private var pending: [String: Pending] = [:]
    private let queue = DispatchQueue(label: "ai.tokenstat.work-cache.keys", qos: .utility, attributes: .concurrent)
    private let timeout: TimeInterval
    private let load: @Sendable (String) -> Result

    init(timeout: TimeInterval = 2, load: @escaping @Sendable (String) -> Result) {
        self.timeout = timeout
        self.load = load
    }

    func read(_ scope: String) async -> Result {
        await withCheckedContinuation { waiter in enqueue(scope, waiter: waiter) }
    }

    private func enqueue(_ scope: String, waiter: CheckedContinuation<Result, Never>) {
        lock.lock()
        if var entry = pending[scope] {
            guard !entry.expired, entry.waiters.count < 64 else {
                lock.unlock()
                waiter.resume(returning: (errSecNotAvailable, nil))
                return
            }
            entry.waiters.append(waiter)
            pending[scope] = entry
            lock.unlock()
            return
        }
        guard pending.count < 4 else {
            lock.unlock()
            waiter.resume(returning: (errSecNotAvailable, nil))
            return
        }
        let entry = Pending(waiters: [waiter])
        pending[scope] = entry
        let id = entry.id
        lock.unlock()
        queue.async {
            self.finish(scope, id: id, result: self.load(scope), completed: true)
        }
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + timeout) {
            self.finish(scope, id: id, result: (errSecNotAvailable, nil), completed: false)
        }
    }

    private func finish(_ scope: String, id: UUID, result: Result, completed: Bool) {
        lock.lock()
        guard var entry = pending[scope], entry.id == id else { lock.unlock(); return }
        let waiters = entry.waiters
        if completed { pending.removeValue(forKey: scope) }
        else {
            entry.expired = true
            entry.waiters.removeAll()
            pending[scope] = entry
        }
        lock.unlock()
        for waiter in waiters { waiter.resume(returning: result) }
    }
}
