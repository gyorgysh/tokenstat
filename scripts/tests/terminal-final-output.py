#!/usr/bin/env python3
# SPDX-License-Identifier: LicenseRef-tokenstat-source-available
"""Exercise the production terminal exit/read method with an inert paged host."""
from pathlib import Path
import subprocess
import tempfile

root = Path(__file__).resolve().parents[2]
source = (root / 'apps/mac/Sources/Features/Terminals/TerminalSession.swift').read_text()
start = source.index('    @MainActor\n    private func afterPollNapMilliseconds')
end = source.index('    /// Bytes read from the host', start)
method = source[start:end].replace('private func', 'func')
fixture = r'''
import Foundation
enum State { case none, working, stopped }
struct Info {
    var rows = 24; var cols = 80; var alive = false; var exitCode: Int? = 0
    var activity: String?; var cpuPercent: Double?; var memoryMb: Double?; var attention: String?
    var programStatus: String?
}
struct Chunk { var dropped = 0; var nextOffset: UInt64; var bytes: Data }
@MainActor enum Bridge {
    static var output = Data((0..<(400 * 1024)).map { UInt8($0 % 251) })
    static var holdInfo = false
    static var waiter: CheckedContinuation<Info, Never>?
    static var reads = 0
    static func ptyInfo(id: String) async throws -> Info {
        if holdInfo { return await withCheckedContinuation { waiter = $0 } }
        return Info()
    }
    static func ptyRead(id: String, offset: UInt64) async throws -> Chunk {
        reads += 1
        let start = Int(offset), end = min(output.count, Int(offset) + 64 * 1024)
        return Chunk(nextOffset: UInt64(end), bytes: output.subdata(in: start..<end))
    }
}
@MainActor final class Session {
    var removed = false, isFocused = true, alive = true, droppedOutput = false
    var sinceInfo = 250, pollDelay = 16, rows = 24, cols = 80, pendingFeedBytes = 0
    var lastLoopAt = Date(), hotUntil = Date.distantPast
    var hostID = "pty", offset: UInt64 = 0, exitCode: Int?
    var state = State.working, idleCheckTask: Task<Void, Never>?
    static let maxPollDelay = 400, minPollDelay = 16, renderHighWater = 8 * 1024 * 1024
    var received = Data()
    func applyActivity(_ activity: String?, cpuPercent: Double?, memoryMb: Double?, attention: String?, programStatus: String?) {}
    func clearAttention() {}
    func applyMeter(from info: Info) {}
    func acceptBytes(_ bytes: Data) { received.append(bytes) }
METHOD
}
@main struct Test {
    @MainActor static func main() async throws {
        let session = Session()
        let nap = await session.afterPollNapMilliseconds(unheld: false)
        assert(nap == nil && session.received == Bridge.output && Bridge.reads > 2,
               "terminal exit drains every buffered page")
        Bridge.holdInfo = true
        let stopped = Session()
        let reading = Task { await stopped.afterPollNapMilliseconds(unheld: false) }
        while Bridge.waiter == nil { await Task.yield() }
        stopped.removed = true
        Bridge.waiter?.resume(returning: Info()); Bridge.waiter = nil
        _ = await reading.value
        assert(stopped.received.isEmpty && stopped.exitCode == nil,
               "late info cannot modify or read a stopped terminal")
        print("Terminal final multi-page output and late info passed")
    }
}
'''.replace('METHOD', method)
with tempfile.TemporaryDirectory(prefix='tokenstat-terminal-review-') as directory:
    path = Path(directory)
    (path / 'Fixture.swift').write_text(fixture)
    subprocess.run(['swiftc', '-parse-as-library', str(path / 'Fixture.swift'), '-o', str(path / 'test')], check=True)
    subprocess.run([str(path / 'test')], check=True)

phone_source = (root / 'apps/mac/Sources/Client/ClientTerminalSession.swift').read_text()
start = phone_source.index('    nonisolated private func poll(')
end = phone_source.index('    private static func makeView(', start)
phone_methods = phone_source[start:end].replace('private func', 'func').replace('private struct Plan', 'struct Plan')
phone_fixture = r'''
import Foundation
struct Info: Sendable {
    var id = "pty"
    var rows = 24, cols = 80, alive = false
    var exitCode: Int? = 0
    var sessionIdentities: String?
}
struct PtyChunk: Sendable {
    var bytes: Data
    var nextOffset: UInt64
    var dropped: UInt64 = 0
    var paused = false
}
@MainActor enum ClientRemote {
    static let output = Data(String(repeating: "café 日本語 terminal output\n", count: 16_000).utf8)
    static var reads = 0
    static var failuresRemaining = 0
    static var holdInfo = false
    static var waiter: CheckedContinuation<Info, Never>?
    static func ptyInfo(peer: String, id: String) async throws -> Info {
        if holdInfo { return await withCheckedContinuation { waiter = $0 } }
        return Info()
    }
    static func ptyRead(peer: String, id: String, offset: UInt64, waitMs: Int) async throws -> PtyChunk {
        reads += 1
        if offset > 0 && failuresRemaining > 0 {
            failuresRemaining -= 1
            throw CocoaError(.fileReadUnknown)
        }
        let start = min(Int(offset), output.count), end = min(output.count, Int(offset) + 64 * 1024)
        return PtyChunk(bytes: output.subdata(in: start..<end), nextOffset: UInt64(end))
    }
    static func ptyList(peer: String) async throws -> [Info] { [Info()] }
}
@MainActor final class Emulator {
    var received = Data()
    func feedOutput(_ bytes: ArraySlice<UInt8>) { received.append(contentsOf: bytes) }
}
@MainActor final class Session {
    var mayOperate = true, inForeground = true, hasOutput = false
    var alive = true, droppedOutput = false, outputPaused = false
    var rows = 24, cols = 80
    var exitCode: Int?
    var transportError: String?, sessionIdentities: String?
    var lastInfoAt = Date.distantPast
    var liveInfo: Info?
    var offset: UInt64 = 0
    var pollTask: Task<Void, Never>?
    var outputFilter = TerminalOutputFilter()
    let view = Emulator()
    func updateLiveActivity(stopped: Bool) async {}
METHOD
}
@main struct Test {
    @MainActor static func main() async {
        let dropped = Session()
        let stoppedOnDrop = await dropped.apply(PtyChunk(bytes: Data(), nextOffset: 77, dropped: 77))
        precondition(!stoppedOnDrop && dropped.offset == 77 && dropped.droppedOutput,
            "An empty dropped-output notice must advance its reader without ending a live session")
        for failures in [0, 2, 8] {
            ClientRemote.failuresRemaining = failures
            ClientRemote.reads = 0
            let session = Session()
            await session.poll(peer: "host", id: "pty")
            precondition(session.view.received == ClientRemote.output && ClientRemote.reads > 2,
                "iOS terminal must drain every page after the process exits: received \(session.view.received.count) of \(ClientRemote.output.count)")
            precondition(session.transportError == nil && ClientRemote.failuresRemaining == 0,
                "Final-output recovery must clear its transient error")
        }
        ClientRemote.holdInfo = true
        let stopped = Session()
        let reading = Task { await stopped.checkLiveness(peer: "host", id: "pty") }
        while ClientRemote.waiter == nil { await Task.yield() }
        stopped.mayOperate = false
        ClientRemote.waiter?.resume(returning: Info()); ClientRemote.waiter = nil
        let keepReading = await reading.value
        precondition(!keepReading && stopped.exitCode == nil && stopped.view.received.isEmpty,
            "Late process info cannot restart a dismissed terminal")
        print("iOS terminal final multi-page Unicode output and late info passed")
    }
}
'''.replace('METHOD', phone_methods)
with tempfile.TemporaryDirectory(prefix='tokenstat-phone-terminal-review-') as directory:
    path = Path(directory)
    (path / 'Fixture.swift').write_text(phone_fixture)
    output_filter = root / 'apps/mac/Sources/Features/Terminals/TerminalOutputFilter.swift'
    subprocess.run(['swiftc', '-parse-as-library', str(path / 'Fixture.swift'), str(output_filter), '-o', str(path / 'test')], check=True)
    subprocess.run([str(path / 'test')], check=True, timeout=15)
