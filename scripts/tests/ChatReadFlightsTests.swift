// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
// Compile with ChatReadFlights.swift.
import Foundation
@MainActor private final class Wire {
    var reads = 0
    var pending: [CheckedContinuation<String, Error>?] = []
    func read() async throws -> String {
        reads += 1
        return try await withCheckedThrowingContinuation { pending.append($0) }
    }
    func answer(_ index: Int, _ result: Result<String, Error>) {
        let waiter = pending[index]; pending[index] = nil; waiter?.resume(with: result)
    }
}
@MainActor private func until(_ condition: () -> Bool) async {
    for _ in 0..<10_000 { if condition() { return }; await Task.yield() }
    precondition(condition())
}
private func key(_ owner: String = "account-a", _ peer: String? = "computer-a", _ parameters: String = "offset=0") -> ChatReadKey {
    ChatReadKey(owner: Data(owner.utf8), peer: peer, method: "chat.events", parameters: Data(parameters.utf8), patience: 5)
}
@main struct ChatReadFlightsTests {
    @MainActor static func main() async throws {
        let flights = ChatReadFlights(), wire = Wire(), request = key()
        let readers = (0..<30).map { _ in Task { try await flights.run(request) { try await wire.read() } } }
        await until { wire.reads == 1 }
        for _ in 0..<100 { await Task.yield() }
        precondition(wire.reads == 1)
        readers[0].cancel()
        wire.answer(0, .success("first"))
        do { _ = try await readers[0].value; preconditionFailure("Canceled waiter used a reply") } catch is CancellationError {}
        for reader in readers.dropFirst() { let value = try await reader.value; precondition(value == "first") }
        let fresh = Task { try await flights.run(request) { try await wire.read() } }
        await until { wire.reads == 2 }
        wire.answer(1, .success("fresh")); let freshValue = try await fresh.value
        precondition(freshValue == "fresh", "A completed value became a cache")

        let stale = Task { try await flights.run(request) { try await wire.read() } }
        await until { wire.reads == 3 }
        await flights.invalidate(owner: request.owner, peer: request.peer)
        let successor = Task { try await flights.run(request) { try await wire.read() } }
        await until { wire.reads == 4 }
        wire.answer(2, .success("old"))
        let joining = Task { try await flights.run(request) { try await wire.read() } }
        for _ in 0..<100 { await Task.yield() }
        precondition(wire.reads == 4, "Old teardown erased the successor's slot")
        wire.answer(3, .success("new"))
        let newer = try await successor.value, joined = try await joining.value, refreshed = try await stale.value
        precondition(newer == "new" && joined == "new" && refreshed == "new")

        let isolated = [key("account-b"), key("account-a", "computer-b"), key("account-a", nil), key("account-a", "computer-a", "offset=1")]
        let separate = isolated.map { request in Task { try await flights.run(request) { try await wire.read() } } }
        await until { wire.reads == 8 }
        for n in 4..<8 { wire.answer(n, .success("isolated")) }
        for read in separate { _ = try await read.value }
        enum Failure: Error { case temporary }
        let failed = Task { try await flights.run(request) { try await wire.read() } }
        await until { wire.reads == 9 }; wire.answer(8, .failure(Failure.temporary))
        do { _ = try await failed.value; preconditionFailure() } catch Failure.temporary {}
        let retry = Task { try await flights.run(request) { try await wire.read() } }
        await until { wire.reads == 10 }; wire.answer(9, .success("retry")); _ = try await retry.value
        let obsoleteFailure = Task { try await flights.run(request) { try await wire.read() } }
        await until { wire.reads == 11 }
        await flights.invalidate(owner: request.owner, peer: request.peer)
        wire.answer(10, .failure(Failure.temporary))
        await until { wire.reads == 12 }
        wire.answer(11, .success("after failure"))
        let recovered = try await obsoleteFailure.value; precondition(recovered == "after failure")
        let canceledFailure = Task { try await flights.run(request) { try await wire.read() } }
        await until { wire.reads == 13 }
        canceledFailure.cancel(); wire.answer(12, .failure(Failure.temporary))
        do { _ = try await canceledFailure.value; preconditionFailure() } catch is CancellationError {}
        let canceledEntry = Task { try await flights.run(request) { try await wire.read() } }
        canceledEntry.cancel()
        do { _ = try await canceledEntry.value; preconditionFailure() } catch is CancellationError {}
        precondition(wire.reads == 13, "A caller canceled before entry dispatched a read")
        let typed: Int = try await flights.run(request) { 42 }; precondition(typed == 42)
        precondition(!ChatReadFlights.reads.contains("chat.send") && !ChatReadFlights.reads.contains("chat.receipt"))
        precondition(ChatReadFlights.mutations.contains("chat.send") && ChatReadFlights.mutations.contains("chat.remove"))
        print("Chat reads: 30 shared waiters, cancellation, mutation invalidation, exact account/peer/cursor isolation, failure retry and no completed cache passed")
    }
}
