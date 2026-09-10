// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
// Compile with WorkCacheMutationQueue.swift.
import Foundation
actor MutationGate {
    var started = false
    var continuation: CheckedContinuation<Void, Never>?
    var observers: [CheckedContinuation<Void, Never>] = []
    func hold() async {
        started = true
        observers.forEach { $0.resume() }; observers = []
        await withCheckedContinuation { continuation = $0 }
    }
    func waitForStart() async { if !started { await withCheckedContinuation { observers.append($0) } } }
    func release() { continuation?.resume(); continuation = nil }
}
actor MutationLog {
    var values: [String] = []
    func add(_ value: String) { values.append(value) }
}
@main struct WorkCacheMutationQueueTests {
    static func main() async throws {
        let queue = WorkCacheMutationQueue()
        let gate = MutationGate()
        let log = MutationLog()
        let before = await queue.generation(scope: "one")
        let write = Task {
            try await queue.run(scope: "one", expectedGeneration: before) {
                await gate.hold()
                await log.add("write")
            }
        }
        await gate.waitForStart()
        // Another account can complete while this transport is suspended.
        try await queue.run(scope: "two") { await log.add("other scope") }
        let clear = Task { try await queue.run(scope: "one", invalidating: true) { await log.add("clear") } }
        while await queue.generation(scope: "one") == before { await Task.yield() }
        let whileSuspended = await log.values
        assert(whileSuspended == ["other scope"], "Clear must still be waiting for the suspended write")
        await gate.release()
        try await clear.value
        try await write.value
        let values = await log.values
        assert(values == ["other scope", "write", "clear"])
        do {
            try await queue.run(scope: "one", expectedGeneration: before) { await log.add("stale write") }
            assertionFailure("A write prepared before clear ran afterwards")
        } catch is CancellationError {}
        let after = await queue.generation(scope: "one")
        try await queue.run(scope: "one", expectedGeneration: after) { await log.add("fresh write") }
        let final = await log.values
        assert(final.last == "fresh write" && !final.contains("stale write"))
        enum Refused: Error { case expected }
        do { try await queue.run(scope: "one") { throw Refused.expected }; assertionFailure() } catch Refused.expected {}
        try await queue.run(scope: "one") { await log.add("after failure") }
        print("Cache mutations: suspended write before clear, cross-scope independence, stale preparation refusal and error recovery passed")
    }
}
