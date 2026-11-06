// SPDX-License-Identifier: LicenseRef-tokenstat-source-available

import Foundation
import Security
import LocalAuthentication

/// The per-scope key that seals saved work, held by the system keychain.
///
/// One 256-bit key per account scope (or the local installation), generated
/// on first save and never leaving the keychain except into the sealing call
/// that needs it. The cache file holds ciphertext beside record ids; without
/// this key those rows are sizes and timestamps. Deleting the key is what
/// makes a sign-out purge unrecoverable rather than merely unlisted.
enum WorkCacheKey {
    @MainActor private static var creating: Set<String> = []
    private static let service = "ai.tokenstat.work-cache"

    /// Keychain reads may wait for the security service or an unlock prompt.
    /// Never make the UI executor wait with them. Creation uses the main
    /// actor only for authorization checks; mutations share a background queue
    /// so sign-out deletion cannot be overtaken by an unfinished creation.
    @MainActor
    static func keyForSaving(for scope: String, canCreate: () -> Bool) async -> [UInt8]? {
        await resolveForSaving(
            read: { await readInBackground(scope: scope) },
            canCreate: { canCreate() && !WorkCacheCleanupJournal.blocks(scope) },
            add: { key in
                guard creating.count < 4, creating.insert(scope).inserted else { return errSecNotAvailable }
                defer { creating.remove(scope) }
                return await mutate {
                    guard !WorkCacheCleanupJournal.blocks(scope) else { return errSecInteractionNotAllowed }
                    return store(scope: scope, key: key)
                }
            }, generate: randomBytes
        )
    }

    @MainActor
    static func resolveForSaving(
        read: () async -> (status: OSStatus, key: [UInt8]?),
        canCreate: () -> Bool, add: ([UInt8]) async -> OSStatus,
        generate: () -> [UInt8]
    ) async -> [UInt8]? {
        guard canCreate(), !Task.isCancelled else { return nil }
        let existing = await read()
        guard canCreate(), !Task.isCancelled else { return nil }
        if existing.status == errSecSuccess { return existing.key }
        guard existing.status == errSecItemNotFound else { return nil }
        let fresh = generate()
        guard fresh.count == 32 else { return nil }
        let status = await add(fresh)
        guard canCreate(), !Task.isCancelled else { return nil }
        switch status {
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

    private static let mutations = WorkCacheKeyMutations()

    private static func mutate(_ operation: @escaping @Sendable () -> OSStatus) async -> OSStatus {
        await mutations.run(operation)
    }

    @discardableResult
    static func delete(for scope: String) async -> Bool {
        let status = await mutate {
            #if os(macOS)
            return helperRequest(action: "delete", scope: scope).status
            #else
            return nativeDelete(scope: scope)
            #endif
        }
        return status == errSecSuccess || status == errSecItemNotFound
    }

    private static func nativeDelete(scope: String) -> OSStatus {
        SecItemDelete([
                kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: service,
                kSecAttrAccount as String: scope,
                kSecUseAuthenticationContext as String: silentContext(),
        ] as CFDictionary)
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

    private static func silentContext() -> LAContext {
        let context = LAContext()
        context.interactionNotAllowed = true
        return context
    }

    private static func load(scope: String) -> (status: OSStatus, key: [UInt8]?) {
        #if os(macOS)
        return helperRequest(action: "read", scope: scope)
        #else
        return nativeLoad(scope: scope)
        #endif
    }

    private static func nativeLoad(scope: String) -> (status: OSStatus, key: [UInt8]?) {
        var result: CFTypeRef?
        let status = SecItemCopyMatching([
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: scope,
            kSecUseAuthenticationContext as String: silentContext(),
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ] as CFDictionary, &result)
        guard status == errSecSuccess else { return (status, nil) }
        guard let data = result as? Data, data.count == 32 else { return (errSecDecode, nil) }
        return (errSecSuccess, Array(data))
    }

    private static func store(scope: String, key: [UInt8]) -> OSStatus {
        #if os(macOS)
        return helperRequest(action: "create", scope: scope, key: key).status
        #else
        return nativeStore(scope: scope, key: key)
        #endif
    }

    private static func nativeStore(scope: String, key: [UInt8]) -> OSStatus {
        // Readable after first unlock so a cold open in airplane mode still
        // finds its copies; this device only, so a backup never carries it.
        let status = SecItemAdd([
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: scope,
            kSecUseAuthenticationContext as String: silentContext(),
            kSecValueData as String: Data(key),
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
        ] as CFDictionary, nil)
        return status
    }

    #if os(macOS)
    private struct HelperRequest: Codable { let action, scope: String; let key: [UInt8]? }
    private struct HelperReply: Codable { let status: OSStatus; let key: [UInt8]? }

    /// Run before SwiftUI/AppKit starts. The same signed executable preserves
    /// existing Keychain access rules, but disabling interaction affects only
    /// this short-lived process, never the app's deliberate authentication.
    static func helperMainIfRequested() -> Int32? {
        guard CommandLine.arguments.dropFirst().first == "--work-cache-keychain" else { return nil }
        guard CommandLine.arguments.count == 2,
              SecKeychainSetUserInteractionAllowed(false) == errSecSuccess,
              let data = boundedInput(),
              let request = try? JSONDecoder().decode(HelperRequest.self, from: data),
              !request.scope.isEmpty, request.scope.utf8.count <= 4096 else { return 1 }
        let result: HelperReply
        switch request.action {
        case "read":
            let value = nativeLoad(scope: request.scope)
            result = HelperReply(status: value.status, key: value.key)
        case "create":
            guard let key = request.key, key.count == 32 else { return 1 }
            result = HelperReply(status: nativeStore(scope: request.scope, key: key), key: nil)
        case "delete":
            result = HelperReply(status: nativeDelete(scope: request.scope), key: nil)
        default: return 1
        }
        guard let encoded = try? JSONEncoder().encode(result) else { return 1 }
        do { try FileHandle.standardOutput.write(contentsOf: encoded); return 0 }
        catch { return 1 }
    }

    private static func boundedInput() -> Data? {
        var data = Data()
        do {
            while let chunk = try FileHandle.standardInput.read(upToCount: 16_385 - data.count), !chunk.isEmpty {
                data.append(chunk)
                guard data.count <= 16_384 else { return nil }
            }
            return data
        } catch { return nil }
    }

    private static func helperRequest(action: String, scope: String, key: [UInt8]? = nil) -> (status: OSStatus, key: [UInt8]?) {
        guard let executable = Bundle.main.executableURL,
              let bytes = try? JSONEncoder().encode(HelperRequest(action: action, scope: scope, key: key)),
              bytes.count <= 16_384 else { return (errSecNotAvailable, nil) }
        let process = Process()
        process.executableURL = executable
        process.arguments = ["--work-cache-keychain"]
        let input = Pipe(), output = Pipe()
        process.standardInput = input
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
            try input.fileHandleForWriting.write(contentsOf: bytes)
            try input.fileHandleForWriting.close()
            // The reply is at most a 32-byte key. It cannot fill the pipe while
            // we wait. A wedged security service must not retain this child.
            let deadline = ProcessInfo.processInfo.systemUptime + 3
            while process.isRunning && ProcessInfo.processInfo.systemUptime < deadline { Thread.sleep(forTimeInterval: 0.01) }
            if process.isRunning { kill(process.processIdentifier, SIGKILL); process.waitUntilExit(); return (errSecNotAvailable, nil) }
            guard process.terminationStatus == 0,
                  let data = try output.fileHandleForReading.read(upToCount: 4097), data.count <= 4096,
                  let reply = try? JSONDecoder().decode(HelperReply.self, from: data) else { return (errSecNotAvailable, nil) }
            return (reply.status, reply.key)
        } catch {
            if process.isRunning { kill(process.processIdentifier, SIGKILL); process.waitUntilExit() }
            return (errSecNotAvailable, nil)
        }
    }
    #endif

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

/// Creation and deletion must reach Keychain in order, even when its service
/// stalls. The cleanup journal blocks new saves until deletion returns.
final class WorkCacheKeyMutations: @unchecked Sendable {
    private let queue = DispatchQueue(label: "ai.tokenstat.work-cache.key-mutations", qos: .utility)

    func run(_ operation: @escaping @Sendable () -> OSStatus) async -> OSStatus {
        await withCheckedContinuation { continuation in
            queue.async { continuation.resume(returning: operation()) }
        }
    }
}
