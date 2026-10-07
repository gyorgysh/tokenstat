// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
// Compile with ClientProjectChats.swift StableListOrder.swift Singleflight.swift.
import Foundation
import Observation

struct ChatConversation: Identifiable, Equatable, Sendable {
    var id: String
    var workspaceID = "project"
    var title = "Chat"
    var lastMessageAtMs: Int64?
    var updatedAtMs: Int64 = 0
}

@MainActor private final class Clock {
    var now = Date(timeIntervalSince1970: 100)
    var current = true
    var reads = 0
}
@MainActor private final class Gate {
    var waiting: CheckedContinuation<Void, Never>?
    func wait() async { await withCheckedContinuation { waiting = $0 } }
    func release() { waiting?.resume(); waiting = nil }
}
private final class Changes: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0
    func note() { lock.lock(); defer { lock.unlock() }; value += 1 }
    var count: Int { lock.lock(); defer { lock.unlock() }; return value }
}

@main struct ClientProjectChatsTests {
    @MainActor static func main() async {
        let clock = Clock()
        let cache = ClientProjectChats(limit: 2)
        let entry = cache.entry(peer: "mac", workspace: "project")
        let reader = UUID()
        entry.appear(reader)
        let first = ChatConversation(id: "a", updatedAtMs: 20)
        let second = ChatConversation(id: "b", updatedAtMs: 10)
        await entry.load(clock: { clock.now }) { clock.reads += 1; return [second, first] }
        precondition(entry.loaded && entry.error == nil && entry.chats.map(\.id) == ["a", "b"])
        for _ in 0..<30 {
            let remount = cache.entry(peer: "mac", workspace: "project")
            precondition(remount === entry)
            await remount.load(clock: { clock.now }) { clock.reads += 1; return [] }
        }
        precondition(clock.reads == 1 && entry.chats.count == 2)

        // Identical replies do not publish a new array into the sidebar.
        let invalidations = Changes()
        withObservationTracking { _ = entry.chats } onChange: { invalidations.note() }
        await entry.load(refresh: true, clock: { clock.now }) { [first, second] }
        precondition(invalidations.count == 0)

        let pointer = UUID()
        entry.interacting(true, owner: pointer, now: clock.now)
        var newerSecond = second
        newerSecond.updatedAtMs = 100
        newerSecond.title = "New title"
        let third = ChatConversation(id: "c", updatedAtMs: 200)
        await entry.load(refresh: true, clock: { clock.now }) { [third, newerSecond, first, first] }
        precondition(entry.chats.map(\.id) == ["a", "b", "c"])
        precondition(entry.chats[1].title == "New title")
        entry.interacting(false, owner: pointer, now: clock.now)
        clock.now += 1
        await entry.load(refresh: true, clock: { clock.now }) { [third, newerSecond, first] }
        precondition(entry.chats.map(\.id) == ["a", "b", "c"])
        clock.now += 2
        await entry.load(refresh: true, clock: { clock.now }) { [third, newerSecond, first] }
        precondition(entry.chats.map(\.id) == ["c", "b", "a"])

        // Failures retain usable rows and are distinct from an empty answer.
        enum Failure: Error { case offline }
        await entry.load(refresh: true, clock: { clock.now }) { throw Failure.offline }
        precondition(entry.loaded && entry.error != nil && entry.chats.count == 3)
        await entry.load(clock: { clock.now }) { [] }
        precondition(entry.loaded && entry.error == nil && entry.chats.isEmpty)

        let flightEntry = cache.entry(peer: "mac", workspace: "flight")
        let gate = Gate()
        let cancelled = Task { @MainActor in
            await flightEntry.load(clock: { clock.now }) {
                clock.reads += 1
                await gate.wait()
                return [ChatConversation(id: "shared", workspaceID: "flight")]
            }
        }
        while gate.waiting == nil { await Task.yield() }
        let successor = Task { @MainActor in
            await flightEntry.load(clock: { clock.now }) {
                preconditionFailure("duplicate read after layout cancellation")
            }
        }
        cancelled.cancel()
        await Task.yield()
        gate.release()
        await cancelled.value
        await successor.value
        precondition(flightEntry.chats.map(\.id) == ["shared"])

        let lateGate = Gate()
        let stale = Task { @MainActor in
            await flightEntry.load(refresh: true, clock: { clock.now }) {
                await lateGate.wait()
                return [ChatConversation(id: "shared", workspaceID: "flight")]
            }
        }
        while lateGate.waiting == nil { await Task.yield() }
        flightEntry.remove("shared")
        lateGate.release()
        await stale.value
        precondition(flightEntry.chats.isEmpty, "late read must not resurrect a deleted row")

        let ownerGate = Gate()
        let wrongOwner = Task { @MainActor in
            await flightEntry.load(refresh: true, clock: { clock.now }, isCurrent: { clock.current }) {
                await ownerGate.wait()
                return [ChatConversation(id: "wrong-account", workspaceID: "flight")]
            }
        }
        while ownerGate.waiting == nil { await Task.yield() }
        clock.current = false
        ownerGate.release()
        await wrongOwner.value
        precondition(flightEntry.chats.isEmpty)

        let hostTwo = cache.entry(peer: "another-mac", workspace: "project")
        precondition(hostTwo !== entry)
        let otherAccount = ClientProjectChats().entry(peer: "mac", workspace: "project")
        precondition(otherAccount !== entry)
        _ = cache.entry(peer: "mac", workspace: "another-project")
        precondition(cache.entry(peer: "mac", workspace: "project") === entry,
            "active metadata must not be evicted")
        entry.disappear(reader)
        print("Project chats: 30 remounts, shared reads, stable touch order, unchanged publication, failure/retry, stale owner/mutation and cache isolation passed")
    }
}
