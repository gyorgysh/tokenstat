// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
// Compile with SSHSessionsModel.swift TerminalPaneSelection.swift Singleflight.swift.
import Foundation

private func check(_ condition: Bool, _ message: String = "") { precondition(condition, message) }

struct SSHSummary { let id: String; let hostID: String?; var alive = true }
@MainActor enum Bridge {
    static var reads = 0
    static var reply: Result<[SSHSummary], Error> = .success([])
    static var pending: CheckedContinuation<[SSHSummary], Error>?
    static var hold = false
    static func sshSessions() async throws -> [SSHSummary] {
        reads += 1
        if hold { return try await withCheckedThrowingContinuation { pending = $0 } }
        return try reply.get()
    }
    static func answer(_ summaries: [SSHSummary]) {
        hold = false
        let waiter = pending
        pending = nil
        waiter?.resume(returning: summaries)
    }
}
struct SSHSnippet {
    let command: String
    static func placeholders(in: String) -> [String] { `in`.contains("{{") ? ["value"] : [] }
    static func bytesToRun(_ command: String) -> [UInt8] { Array(command.utf8) }
}
@MainActor final class SSHLiveTerminal {
    let id: String
    let hostID: String?
    var alive = true
    var foreground = true
    var error: String?
    var closeSucceeds = true
    var pendingClose: CheckedContinuation<Bool, Never>?
    var holdClose = false
    var stops = 0
    var detaches = 0
    var writes: [String] = []
    init(id: String, hostID: String) { self.id = id; self.hostID = hostID }
    init(adopting summary: SSHSummary) { id = summary.id; hostID = summary.hostID }
    func markClosed() { alive = false }
    func closeRemote() async -> Bool {
        stops += 1
        let succeeded = holdClose ? await withCheckedContinuation { pendingClose = $0 } : closeSucceeds
        if succeeded { alive = false } else { error = "Close failed" }
        return succeeded
    }
    func setForeground(_ value: Bool) { foreground = value }
    func sendStartupBytes(_ bytes: [UInt8], beforeDispatch: @MainActor () -> Bool) async -> Bool {
        guard foreground, alive, beforeDispatch() else { return false }
        sendBytes(bytes)
        return true
    }
    func detachPoll() { detaches += 1 }
    func sendBytes(_ bytes: [UInt8]) { writes.append(String(decoding: bytes, as: UTF8.self)) }
}
#if os(macOS)
enum TerminalSplitLayout: String { case single, side, stacked; var isSplit: Bool { self != .single } }
#endif

@main struct SSHSessionsModelTests {
    @MainActor static func main() async {
        let firstHost = UUID().uuidString, secondHost = UUID().uuidString
        let model = SSHSessionsModel()
        let a = SSHLiveTerminal(id: "a", hostID: firstHost)
        let b = SSHLiveTerminal(id: "b", hostID: firstHost)
        let c = SSHLiveTerminal(id: "c", hostID: firstHost)
        let other = SSHLiveTerminal(id: "other", hostID: secondHost)
        for session in [a, b, c, other] { model.adopt(session) }
        model.select(a)
        model.select(other)
        check(model.activeSession(for: firstHost) === a,
                     "Opening another host forgot this host's selected terminal")
        #if os(macOS)
        defer {
            for host in [firstHost, secondHost] {
                UserDefaults.standard.removeObject(forKey: "ssh.split.\(host)")
                UserDefaults.standard.removeObject(forKey: "ssh.splitFraction.\(host)")
            }
        }
        model.setLayout(.side, for: firstHost)
        check(model.leadingSession(in: firstHost) === a && model.trailingSession(in: firstHost) === b,
                     "A split used the global selection from a different host")
        model.select(c)
        check(model.leadingSession(in: firstHost) === c && model.trailingSession(in: firstHost) === b,
                     "Selecting a hidden tab left keyboard focus on a terminal outside the visible split")
        model.swapPanes(in: firstHost)
        check(model.leadingSession(in: firstHost) === b && model.trailingSession(in: firstHost) === c
                     && model.activeSession(for: firstHost) === c,
                     "Swapping panes lost focused-terminal identity")
        await model.close(a)
        check(model.layout(for: firstHost) == .side && model.leadingSession(in: firstHost) === b
                     && model.trailingSession(in: firstHost) === c,
                     "Closing an offscreen tab changed the split")
        await model.close(b)
        check(model.layout(for: firstHost) == .single && model.leadingSession(in: firstHost) === c
                     && model.trailingSession(in: firstHost) == nil,
                     "Closing a visible half duplicated the survivor or left an empty split")
        model.setLayout(.side, for: firstHost)
        model.sendToOtherHalf(other, in: firstHost)
        check(model.leadingSession(in: firstHost) === c && model.trailingSession(in: firstHost) == nil,
                     "A server accepted a terminal belonging to another host")
        #endif
        await reconciliationRaces()
        await startupOwnership()
        await foregroundReplacement()
        await closeRetry()
        await pausedStartupProgress()
        await ownerChangesBeforeRootRerenders()
        print("SSH sessions: selection, shared reads, connection/close races, retired readers and startup ownership passed")
    }

    @MainActor static func ownerChangesBeforeRootRerenders() async {
        var owned = true
        let model = SSHSessionsModel(isOwnerCurrent: { owned })
        let terminal = SSHLiveTerminal(id: "owned", hostID: "host")
        model.adopt(terminal)
        Bridge.hold = true
        let read = Task { await model.reconcile() }
        await waitForRead()
        owned = false
        Bridge.answer([SSHSummary(id: "stale-owner", hostID: "host")])
        let accepted = await read.value
        check(!accepted && model.sessions.count == 1 && terminal.alive)
        let late = SSHLiveTerminal(id: "late-owner", hostID: "host")
        check(model.adopt(late) == nil && late.detaches == 1 && late.stops == 0)
        let closed = await model.close(terminal)
        check(!closed && terminal.stops == 0)
        model.deactivate()
        check(terminal.detaches == 1 && terminal.stops == 0)
    }

    @MainActor static func waitForRead() async {
        while Bridge.pending == nil { await Task.yield() }
    }

    @MainActor static func reconciliationRaces() async {
        let model = SSHSessionsModel()
        let old = SSHLiveTerminal(id: "old", hostID: "host")
        model.adopt(old)
        Bridge.hold = true
        let before = Bridge.reads
        let readers = (0..<30).map { _ in Task { await model.reconcile() } }
        await waitForRead()
        for _ in 0..<50 { await Task.yield() }
        check(Bridge.reads == before + 1, "Concurrent remounts repeated a list read")
        let new = SSHLiveTerminal(id: "new", hostID: "host")
        model.adopt(new)
        Bridge.answer([])
        for reader in readers { check(await reader.value) }
        check(!old.alive && new.alive, "An old snapshot ended a newly adopted connection")

        Bridge.hold = true
        let closingRead = Task { await model.reconcile() }
        await waitForRead()
        await model.close(new)
        Bridge.answer([SSHSummary(id: "new", hostID: "host")])
        check(await closingRead.value)
        check(!model.sessions.contains { $0.id == "new" } && new.stops == 1)
        Bridge.reply = .success([])
        check(await model.reconcile())
        let late = SSHLiveTerminal(id: "new", hostID: "host")
        check(model.adopt(late) == nil && late.detaches == 1 && late.stops == 0,
                     "A late connection callback resurrected a closed handle")

        let duplicate = SSHLiveTerminal(id: "old", hostID: "host")
        check(model.adopt(duplicate) === old && duplicate.detaches == 1 && duplicate.stops == 0)
        let selected = model.selectedID
        model.select(SSHLiveTerminal(id: "foreign", hostID: "host"))
        check(model.selectedID == selected)

        enum Failure: Error { case offline }
        Bridge.reply = .failure(Failure.offline)
        check(!(await model.reconcile()) && model.error != nil && model.loaded)
        check(model.sessions.count == 1, "A failed read erased usable scrollback")
        Bridge.reply = .success([])
        check(await model.reconcile())
        check(model.error == nil)

        Bridge.hold = true
        let retiringRead = Task { await model.reconcile() }
        await waitForRead()
        model.deactivate()
        Bridge.answer([SSHSummary(id: "late-after-retire", hostID: "host")])
        check(!(await retiringRead.value) && model.sessions.count == 1)
        check(old.detaches == 1 && old.stops == 0)
        let rejected = SSHLiveTerminal(id: "retired", hostID: "host")
        check(model.adopt(rejected) == nil && rejected.detaches == 1 && rejected.stops == 0)
    }

    @MainActor static func foregroundReplacement() async {
        let model = SSHSessionsModel()
        let terminal = SSHLiveTerminal(id: "foreground", hostID: "host")
        model.adopt(terminal)
        Bridge.hold = true
        let predecessor = Task { await model.reconcile() }
        await waitForRead()
        let late = Bridge.pending; Bridge.pending = nil
        model.setForeground(false)
        check(!terminal.foreground)
        model.setForeground(true)
        let successor = Task { await model.reconcile() }
        await waitForRead()
        Bridge.answer([SSHSummary(id: "foreground", hostID: "host", alive: false)])
        check(await successor.value)
        late?.resume(returning: [SSHSummary(id: "foreign", hostID: "host")])
        check(!(await predecessor.value))
        check(model.sessions.count == 1 && model.sessions[0] === terminal && !terminal.alive)
        check(terminal.detaches == 0 && terminal.foreground)
        for _ in 0..<30 { model.setForeground(false); model.setForeground(true) }
        check(model.sessions[0] === terminal)
        model.deactivate()
    }

    @MainActor static func closeRetry() async {
        let model = SSHSessionsModel()
        let terminal = SSHLiveTerminal(id: "retry", hostID: "host")
        model.adopt(terminal); model.setForeground(false)
        terminal.closeSucceeds = false
        await model.close(terminal)
        check(model.sessions.first === terminal && terminal.alive && model.closeErrors[terminal.id] != nil)
        model.setForeground(true)
        Bridge.reply = .success([SSHSummary(id: terminal.id, hostID: "host")])
        check(await model.reconcile())
        terminal.error = nil // successful output may clear the transient read error
        check(model.closeErrors[terminal.id] != nil)
        terminal.holdClose = true
        let close = Task { await model.close(terminal) }
        while terminal.pendingClose == nil { await Task.yield() }
        check(model.sessions.first === terminal, "End removed the emulator before acknowledgement")
        await model.close(terminal)
        check(terminal.stops == 2, "Repeated End dispatched another close")
        terminal.pendingClose?.resume(returning: true); terminal.pendingClose = nil
        check(await close.value)
        check(model.sessions.isEmpty && model.closeErrors.isEmpty)
        let late = SSHLiveTerminal(id: terminal.id, hostID: "host")
        check(model.adopt(late) == nil)

        let retiring = SSHSessionsModel(), old = SSHLiveTerminal(id: "retiring-close", hostID: "host")
        retiring.adopt(old); old.holdClose = true
        let retiringClose = Task { await retiring.close(old) }
        while old.pendingClose == nil { await Task.yield() }
        retiring.deactivate()
        old.pendingClose?.resume(returning: false); old.pendingClose = nil
        check(!(await retiringClose.value))
        check(retiring.closeErrors.isEmpty && old.detaches == 1)
    }

    @MainActor static func pausedStartupProgress() async {
        let delay = StartupDelay()
        let model = SSHSessionsModel(startupSleep: { try await delay.sleep($0) })
        let session = SSHLiveTerminal(id: "paused-startup", hostID: "host")
        Bridge.reply = .success([SSHSummary(id: session.id, hostID: "host")])
        model.adopt(session, startup: [SSHSnippet(command: "one"), SSHSnippet(command: "two"), SSHSnippet(command: "three")])
        await delay.wait(1)
        delay.resume(0)
        await delay.wait(2)
        check(session.writes == ["one"])
        model.setForeground(false); model.setForeground(true)
        await delay.wait(3)
        delay.resume(1) // canceled predecessor wakes after its successor exists
        for _ in 0..<50 { await Task.yield() }
        check(session.writes == ["one"])
        delay.resume(2)
        await delay.wait(4)
        check(session.writes == ["one", "two"])
        delay.resume(3)
        await delay.wait(5)
        check(session.writes == ["one", "two", "three"])
        delay.resume(4)
        for _ in 0..<50 { await Task.yield() }
        for _ in 0..<30 { model.adopt(session, startup: [SSHSnippet(command: "wrong")]); model.setForeground(false); model.setForeground(true) }
        check(session.writes == ["one", "two", "three"])
        model.deactivate()
    }

    @MainActor static func startupOwnership() async {
        let model = SSHSessionsModel()
        let session = SSHLiveTerminal(id: "startup", hostID: "host")
        let startup = [SSHSnippet(command: "echo ready"), SSHSnippet(command: "echo {{value}}")]
        for _ in 0..<30 { model.adopt(session, startup: startup) }
        try? await Task.sleep(for: .milliseconds(800))
        check(session.writes == ["echo ready"], "Repeated adoption replayed startup input")
        let closing = SSHLiveTerminal(id: "closing-startup", hostID: "host")
        model.adopt(closing, startup: startup)
        await model.close(closing)
        let retiring = SSHLiveTerminal(id: "retiring-startup", hostID: "host")
        model.adopt(retiring, startup: startup)
        model.deactivate()
        try? await Task.sleep(for: .milliseconds(800))
        check(closing.writes.isEmpty && retiring.writes.isEmpty,
                     "Cancelled startup input reached a closed or retired terminal")
    }
}

@MainActor private final class StartupDelay {
    var pending: [CheckedContinuation<Void, Error>?] = []
    func sleep(_ milliseconds: UInt64) async throws {
        try await withCheckedThrowingContinuation { pending.append($0) }
    }
    func resume(_ index: Int) { let waiter = pending[index]; pending[index] = nil; waiter?.resume() }
    func wait(_ count: Int) async {
        for _ in 0..<10_000 { if pending.count >= count { return }; await Task.yield() }
        precondition(pending.count >= count)
    }
}
