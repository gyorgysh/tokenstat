// SPDX-License-Identifier: LicenseRef-tokenstat-source-available

#if os(macOS)
import SwiftTerm

/// A tab references the existing session and emulator; it does not create a
/// second connection or read loop when a server joins a project split.
@MainActor
final class WorkspaceTerminal: TerminalPresentable {
    nonisolated let id: String
    let local: TerminalSession?
    let ssh: SSHLiveTerminal?

    init(_ session: TerminalSession) { id = session.id; local = session; ssh = nil }
    init(_ session: SSHLiveTerminal) { id = "ssh:" + session.id; local = nil; ssh = session }

    var alive: Bool { local?.alive ?? ssh!.alive }
    var label: String {
        if let local { return local.customName ?? local.title.flatMap { $0.isEmpty ? nil : $0 } ?? local.command }
        return ssh!.title
    }
    var terminalViewIfLoaded: TerminalView? { local?.terminalViewIfLoaded ?? ssh?.terminalViewIfLoaded }
    func terminalReturnedToFront() {
        if let local { local.terminalReturnedToFront() }
        else { ssh?.terminalReturnedToFront() }
    }
}
#endif
