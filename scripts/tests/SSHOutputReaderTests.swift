// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
// Compile with SSHOutputReader.swift.
import Foundation

@MainActor private final class Wire {
    var offsets: [UInt64] = []
    var pending: [CheckedContinuation<SSHOutputChunk, Error>?] = []
    var chunks: [SSHOutputChunk] = []
    var errors = 0
    func read(_ offset: UInt64) async throws -> SSHOutputChunk {
        offsets.append(offset)
        return try await withCheckedThrowingContinuation { pending.append($0) }
    }
    func answer(_ index: Int, _ chunk: SSHOutputChunk) {
        let waiter = pending[index]; pending[index] = nil; waiter?.resume(returning: chunk)
    }
    func fail(_ index: Int, _ error: Error) {
        let waiter = pending[index]; pending[index] = nil; waiter?.resume(throwing: error)
    }
    func reader() -> SSHOutputReader {
        SSHOutputReader(read: { [self] in try await read($0) },
                        deliver: { [self] in chunks.append($0) },
                        failed: { [self] _ in errors += 1 }, sleep: { _ in await Task.yield() })
    }
}
private func chunk(_ data: [UInt8] = [], _ offset: UInt64, closed: Bool = false, dropped: Bool = false) -> SSHOutputChunk {
    SSHOutputChunk(data: data, nextOffset: offset, dropped: dropped, closed: closed, error: nil)
}
@MainActor private func until(_ condition: () -> Bool) async {
    for _ in 0..<10_000 { if condition() { return }; await Task.yield() }
    precondition(condition(), "An owned operation never reached its expected boundary")
}
@MainActor private func settle() async { for _ in 0..<100 { await Task.yield() } }

@main struct SSHOutputReaderTests {
    @MainActor static func main() async {
        await pauseAndLateReplies()
        await drainAndClose()
        await errorsAndLifetime()
        print("SSH output reader: 30 pauses, exact cursor, stale replies, input epochs, bounded EOF drain, close retry and lifetime passed")
    }
    @MainActor static func pauseAndLateReplies() async {
        let wire = Wire(), reader: SSHOutputReader
        reader = wire.reader(); reader.start()
        await until { wire.offsets.count == 1 }
        for cycle in 0..<30 {
            let old = wire.offsets.count - 1, offset = reader.offset, epoch = reader.inputEpoch
            reader.setForeground(false)
            precondition(!reader.canInput && !reader.acceptsInput(epoch))
            reader.setForeground(true)
            precondition(reader.canInput && !reader.acceptsInput(epoch))
            await until { wire.offsets.count == old + 2 }
            precondition(wire.offsets.last == offset)
            if cycle % 2 == 0 { wire.answer(old, chunk([99], offset + 100, closed: true)) }
            else { wire.fail(old, SSHOutputReaderError.sessionMissing) }
            await settle()
            precondition(reader.offset == offset && !reader.shellEnded && wire.errors == 0)
            wire.answer(old + 1, chunk([UInt8(cycle)], offset + 1))
            await until { wire.offsets.count == old + 3 }
            precondition(reader.offset == offset + 1)
            precondition(wire.chunks.count == cycle + 1)
        }
        let last = wire.offsets.count - 1
        reader.retire()
        reader.setForeground(true); reader.start()
        wire.answer(last, chunk([88], 500))
        await settle()
        precondition(reader.offset == 30 && wire.chunks.count == 30 && !reader.canInput)
    }
    @MainActor static func drainAndClose() async {
        let wire = Wire(), reader = wire.reader()
        reader.start(); await until { wire.offsets.count == 1 }
        reader.noteShellEnded() // list metadata precedes output
        precondition(!reader.canInput && !reader.drained)
        wire.answer(0, chunk(Array(repeating: 1, count: 65_536), 65_536))
        await until { wire.offsets.count == 2 }
        wire.answer(1, chunk([2, 3], 65_538, closed: true))
        await until { wire.offsets.count == 3 }
        precondition(!reader.drained && wire.offsets[2] == 65_538)
        wire.answer(2, chunk([], 65_538, closed: true))
        await settle()
        precondition(reader.drained && reader.shellEnded && wire.offsets.count == 3)
        precondition(wire.chunks.flatMap(\.data).count == 65_538)
        reader.setForeground(false)
        let end = reader.beginClose()!
        precondition(reader.beginClose() == nil)
        reader.finishClose(UUID(), succeeded: true)
        precondition(!reader.retired)
        reader.finishClose(end, succeeded: false)
        precondition(!reader.retired && wire.offsets.count == 3)
        let retry = reader.beginClose()!
        reader.finishClose(retry, succeeded: true)
        precondition(reader.retired)

        let runningWire = Wire(), running = runningWire.reader()
        running.start(); await until { runningWire.offsets.count == 1 }
        let epoch = running.inputEpoch, close = running.beginClose()!
        precondition(!running.acceptsInput(epoch))
        running.setForeground(false)
        running.finishClose(close, succeeded: false)
        runningWire.answer(0, chunk([10], 1))
        await settle()
        precondition(running.offset == 0 && runningWire.chunks.isEmpty)
        running.setForeground(true)
        await until { runningWire.offsets.count == 2 }
        precondition(!running.acceptsInput(epoch))
        let retryClose = running.beginClose()!
        running.finishClose(retryClose, succeeded: true)
        runningWire.answer(1, chunk([20], 1))
        await settle()
        precondition(running.retired && runningWire.chunks.isEmpty)
    }
    @MainActor static func errorsAndLifetime() async {
        enum Offline: Error { case temporary }
        let wire = Wire(), reader = wire.reader()
        reader.start(); await until { wire.offsets.count == 1 }
        wire.fail(0, Offline.temporary)
        await until { wire.offsets.count == 2 }
        precondition(wire.errors == 1 && !reader.shellEnded && !reader.drained)
        wire.fail(1, SSHOutputReaderError.sessionMissing)
        await settle()
        precondition(wire.errors == 2 && reader.shellEnded && reader.drained && wire.offsets.count == 2)
        reader.setForeground(false); reader.setForeground(true)
        await settle(); precondition(wire.offsets.count == 2)

        let malformed = Wire(), retrying = malformed.reader()
        retrying.start(); await until { malformed.offsets.count == 1 }
        malformed.answer(0, chunk([1], 0))
        await until { malformed.offsets.count == 2 }
        precondition(retrying.offset == 0 && malformed.chunks.isEmpty && malformed.errors == 1)
        malformed.answer(1, chunk([1], 1, closed: true))
        await until { malformed.offsets.count == 3 }
        malformed.answer(2, chunk([], 1, closed: true))
        await settle(); precondition(retrying.drained && retrying.offset == 1)

        let lifetime = Wire()
        var owned: SSHOutputReader? = lifetime.reader()
        weak let weakReader = owned
        owned?.start(); await until { lifetime.offsets.count == 1 }
        owned = nil
        precondition(weakReader == nil, "A pending transport retained its reader")
        lifetime.answer(0, chunk([1], 1))
        await settle(); precondition(lifetime.chunks.isEmpty)
    }
}
