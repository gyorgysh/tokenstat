// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
// Compile with SSHSessionsModel.swift and TerminalPaneSelection.swift.
import Foundation

struct SSHSummary { let id: String; let hostID: String? }
@MainActor enum Bridge {
    static func sshSessions() async throws -> [SSHSummary] { [] }
}
struct SSHSnippet {
    let command: String
    static func placeholders(in: String) -> [String] { [] }
    static func bytesToRun(_ command: String) -> [UInt8] { Array(command.utf8) }
}
@MainActor final class SSHLiveTerminal {
    let id: String
    let hostID: String?
    var alive = true
    init(id: String, hostID: String) { self.id = id; self.hostID = hostID }
    init(adopting summary: SSHSummary) { id = summary.id; hostID = summary.hostID }
    func markClosed() { alive = false }
    func stop() { alive = false }
    func detachPoll() {}
    func sendBytes(_ bytes: [UInt8]) {}
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
        precondition(model.activeSession(for: firstHost) === a,
                     "Opening another host forgot this host's selected terminal")
        #if os(macOS)
        defer {
            for host in [firstHost, secondHost] {
                UserDefaults.standard.removeObject(forKey: "ssh.split.\(host)")
                UserDefaults.standard.removeObject(forKey: "ssh.splitFraction.\(host)")
            }
        }
        model.setLayout(.side, for: firstHost)
        precondition(model.leadingSession(in: firstHost) === a && model.trailingSession(in: firstHost) === b,
                     "A split used the global selection from a different host")
        model.select(c)
        precondition(model.leadingSession(in: firstHost) === c && model.trailingSession(in: firstHost) === b,
                     "Selecting a hidden tab left keyboard focus on a terminal outside the visible split")
        model.swapPanes(in: firstHost)
        precondition(model.leadingSession(in: firstHost) === b && model.trailingSession(in: firstHost) === c
                     && model.activeSession(for: firstHost) === c,
                     "Swapping panes lost focused-terminal identity")
        await model.close(a)
        precondition(model.layout(for: firstHost) == .side && model.leadingSession(in: firstHost) === b
                     && model.trailingSession(in: firstHost) === c,
                     "Closing an offscreen tab changed the split")
        await model.close(b)
        precondition(model.layout(for: firstHost) == .single && model.leadingSession(in: firstHost) === c
                     && model.trailingSession(in: firstHost) == nil,
                     "Closing a visible half duplicated the survivor or left an empty split")
        model.setLayout(.side, for: firstHost)
        model.sendToOtherHalf(other, in: firstHost)
        precondition(model.leadingSession(in: firstHost) === c && model.trailingSession(in: firstHost) == nil,
                     "A server accepted a terminal belonging to another host")
        #endif
        print("SSH sessions: host selection, visible focus, swaps and split close passed")
    }
}
