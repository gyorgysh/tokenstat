// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
// Compile with WorkCacheKey.swift.
import Foundation
import Security

enum WorkCacheCleanupJournal {
    static func blocks(_ scope: String) -> Bool { false }
}

@main struct WorkCacheKeyTests {
    @MainActor static func main() async {
        let existing = [UInt8](repeating: 1, count: 32)
        let candidate = [UInt8](repeating: 2, count: 32)
        var generated = 0
        var added = 0
        func generate() -> [UInt8] { generated += 1; return candidate }
        func add(_ key: [UInt8]) -> OSStatus {
            precondition(key == candidate)
            added += 1
            return errSecSuccess
        }
        let held = await WorkCacheKey.resolveForSaving(read: { (errSecSuccess, existing) }, canCreate: { true }, add: add, generate: generate)
        precondition(held == existing && generated == 0 && added == 0)
        for status in [errSecInteractionNotAllowed, errSecAuthFailed, errSecDecode, errSecNotAvailable] {
            let refused = await WorkCacheKey.resolveForSaving(read: { (status, nil) }, canCreate: { true }, add: add, generate: generate)
            precondition(refused == nil && generated == 0 && added == 0)
        }
        let created = await WorkCacheKey.resolveForSaving(read: { (errSecItemNotFound, nil) }, canCreate: { true }, add: add, generate: generate)
        precondition(created == candidate && generated == 1 && added == 1)

        // Another caller creates its key after our missing-key read. Its key
        // must win; returning our unused candidate would seal unreadable data.
        var reads = 0
        let winner = await WorkCacheKey.resolveForSaving(read: {
            reads += 1
            return reads == 1 ? (errSecItemNotFound, nil) : (errSecSuccess, existing)
        }, canCreate: { true }, add: { _ in errSecDuplicateItem }, generate: generate)
        precondition(winner == existing && reads == 2)
        reads = 0
        let unavailableWinner = await WorkCacheKey.resolveForSaving(read: {
            reads += 1
            return (reads == 1 ? errSecItemNotFound : errSecInteractionNotAllowed, nil)
        }, canCreate: { true }, add: { _ in errSecDuplicateItem }, generate: generate)
        precondition(unavailableWinner == nil && reads == 2)
        let failedAdd = await WorkCacheKey.resolveForSaving(read: { (errSecItemNotFound, nil) },
            canCreate: { true }, add: { _ in errSecNotAvailable }, generate: generate)
        precondition(failedAdd == nil)
        let invalidRandom = await WorkCacheKey.resolveForSaving(read: { (errSecItemNotFound, nil) },
            canCreate: { true }, add: { _ in preconditionFailure("Invalid random bytes must not be stored") }, generate: { [] })
        precondition(invalidRandom == nil)
        // A lookup can outlive its account. Neither a missing key nor an
        // existing key may be used after authorization changes during the wait.
        var allowed = true
        let addsBeforeRevocation = added
        for status in [errSecItemNotFound, errSecSuccess] {
            allowed = true
            let revoked = await WorkCacheKey.resolveForSaving(read: {
                await Task.yield()
                allowed = false
                return (status, status == errSecSuccess ? existing : nil)
            }, canCreate: { allowed }, add: add, generate: generate)
            precondition(revoked == nil && added == addsBeforeRevocation)
        }
        let unusedRead = await WorkCacheKey.resolveForSaving(
            read: { preconditionFailure("A denied scope must not read Keychain") },
            canCreate: { false }, add: add, generate: generate
        )
        precondition(unusedRead == nil)

        // A second save may have created the scope key while this read was in
        // flight. Re-read the winner rather than returning an unpersisted key.
        reads = 0
        allowed = true
        let asyncWinner = await WorkCacheKey.resolveForSaving(read: {
            await Task.yield()
            reads += 1
            return reads == 1 ? (errSecItemNotFound, nil) : (errSecSuccess, existing)
        }, canCreate: { allowed }, add: { _ in errSecDuplicateItem }, generate: generate)
        precondition(asyncWinner == existing && reads == 2)
        reads = 0
        let revokedWinner = await WorkCacheKey.resolveForSaving(read: {
            await Task.yield()
            reads += 1
            if reads == 2 { allowed = false }
            return reads == 1 ? (errSecItemNotFound, nil) : (errSecSuccess, existing)
        }, canCreate: { allowed }, add: { _ in errSecDuplicateItem }, generate: generate)
        precondition(revokedWinner == nil && reads == 2)
        // A blocked native read releases its callers at the deadline, shares
        // concurrent requests, and never prevents a different scope's lookup.
        let gate = DispatchSemaphore(value: 0)
        let count = ReadCount()
        let readsQueue = WorkCacheKeyReads(timeout: 0.1) { scope in
            precondition(!Thread.isMainThread)
            guard scope == "slow" else { return (errSecSuccess, candidate) }
            if count.increment() == 1 { _ = gate.wait(timeout: .now() + 5) }
            return (errSecSuccess, existing)
        }
        async let first = readsQueue.read("slow")
        async let second = readsQueue.read("slow")
        let other = await readsQueue.read("other")
        precondition(other.key == candidate)
        let timedOut = await [first, second]
        precondition(timedOut.allSatisfy { $0.status == errSecNotAvailable && $0.key == nil })
        precondition(count.value == 1)
        let repeatWhileBlocked = await readsQueue.read("slow")
        precondition(repeatWhileBlocked.status == errSecNotAvailable && count.value == 1)
        gate.signal()
        var retried: [UInt8]?
        for _ in 0..<100 {
            let result = await readsQueue.read("slow")
            if let key = result.key { retried = key; break }
            try? await Task.sleep(for: .milliseconds(10))
        }
        precondition(retried == existing && count.value == 2)
        // A completed key must not be retained as an authorization shortcut.
        _ = await readsQueue.read("slow")
        precondition(count.value == 3)
        print("Cache keys: atomic creation, revoked async reads, bounded waits, coalescing and retry passed")
    }
}

private final class ReadCount: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    var value: Int { lock.lock(); defer { lock.unlock() }; return count }
    func increment() -> Int { lock.lock(); defer { lock.unlock() }; count += 1; return count }
}
