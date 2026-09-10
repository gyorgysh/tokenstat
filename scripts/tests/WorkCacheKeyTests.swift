// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
// Compile with WorkCacheKey.swift.
import Foundation
import Security

enum WorkCacheCleanupJournal {
    static func blocks(_ scope: String) -> Bool { false }
}

@main struct WorkCacheKeyTests {
    static func main() {
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
        let held = WorkCacheKey.getOrCreate(load: { (errSecSuccess, existing) }, add: add, generate: generate)
        precondition(held == existing && generated == 0 && added == 0)
        for status in [errSecInteractionNotAllowed, errSecAuthFailed, errSecDecode, errSecNotAvailable] {
            let refused = WorkCacheKey.getOrCreate(load: { (status, nil) }, add: add, generate: generate)
            precondition(refused == nil && generated == 0 && added == 0)
        }
        let created = WorkCacheKey.getOrCreate(load: { (errSecItemNotFound, nil) }, add: add, generate: generate)
        precondition(created == candidate && generated == 1 && added == 1)

        // Another caller creates its key after our missing-key read. Its key
        // must win; returning our unused candidate would seal unreadable data.
        var reads = 0
        let winner = WorkCacheKey.getOrCreate(load: {
            reads += 1
            return reads == 1 ? (errSecItemNotFound, nil) : (errSecSuccess, existing)
        }, add: { _ in errSecDuplicateItem }, generate: generate)
        precondition(winner == existing && reads == 2)
        reads = 0
        let unavailableWinner = WorkCacheKey.getOrCreate(load: {
            reads += 1
            return (reads == 1 ? errSecItemNotFound : errSecInteractionNotAllowed, nil)
        }, add: { _ in errSecDuplicateItem }, generate: generate)
        precondition(unavailableWinner == nil && reads == 2)
        let failedAdd = WorkCacheKey.getOrCreate(load: { (errSecItemNotFound, nil) },
            add: { _ in errSecNotAvailable }, generate: generate)
        precondition(failedAdd == nil)
        let invalidRandom = WorkCacheKey.getOrCreate(load: { (errSecItemNotFound, nil) },
            add: { _ in preconditionFailure("Invalid random bytes must not be stored") }, generate: { [] })
        precondition(invalidRandom == nil)
        print("Cache keys: existing keys, read failures, atomic creation and concurrent winner passed")
    }
}
