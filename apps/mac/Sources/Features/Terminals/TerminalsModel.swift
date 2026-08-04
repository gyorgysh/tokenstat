// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
//
// Source-available for review, NOT open source. See LICENSE: no rights to
// redistribute, publish, or ship a build are granted. Read it, study it, run
// your own build of it.
// "tokenstat" is a trademark of pueev OU. See TRADEMARK.md.

#if os(macOS)
import Foundation
import Observation

/// The terminal sessions visible in the app.
///
/// The sessions themselves belong to the host process, so this model is a
/// window onto them rather than their owner: it reconciles against `pty.list`,
/// spawns new ones, and closes ones the user is done with. A session that
/// survives all of this stays alive in the host, which is what makes an
/// automation a session and not a tab.
@MainActor
@Observable
final class TerminalsModel {
    var sessions: [TerminalSession] = []
    var selectedID: String?
    var errorMessage: String?

    var selected: TerminalSession? {
        sessions.first { $0.id == selectedID }
    }

    func sessions(in workspaceID: String) -> [TerminalSession] {
        sessions.filter { $0.workspaceID == workspaceID }
    }

    /// Reconcile against the host. Spawned and closed elsewhere show up and
    /// go away rather than being forgotten until relaunch.
    func load() async {
        do {
            let list = try await Bridge.ptyList()
            var byID: [String: PtySessionInfo] = [:]
            for info in list { byID[info.id] = info }

            // Forget sessions the host no longer has.
            let gone = sessions.filter { byID[$0.id] == nil }
            for session in gone {
                session.stop()
                sessions.removeAll { $0.id == session.id }
            }

            // Adopt sessions that appeared since we last looked (another
            // surface, or the host itself).
            let known = Set(sessions.map(\.id))
            for info in list where !known.contains(info.id) {
                sessions.append(TerminalSession(info: info))
            }

            if selectedID == nil { selectedID = sessions.first?.id }
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    /// Launch a command in a workspace's folder and select it.
    @discardableResult
    func start(workspace: WorkspaceFolder, command: String, args: [String]) async -> TerminalSession? {
        do {
            // 24x80 until the view lays out; sizeChanged then resizes the pty
            // to the real surface, which is where the shell gets its SIGWINCH.
            let info = try await Bridge.ptySpawn(
                workspaceID: workspace.id,
                command: command,
                args: args,
                rows: 24,
                cols: 80
            )
            let session = TerminalSession(info: info)
            sessions.append(session)
            selectedID = session.id
            errorMessage = nil
            session.start()
            return session
        } catch {
            errorMessage = error.localizedDescription
            return nil
        }
    }

    /// Kill the process and forget the session. The host's buffer goes with it.
    func close(_ session: TerminalSession) async {
        try? await Bridge.ptyClose(id: session.id)
        session.stop()
        sessions.removeAll { $0.id == session.id }
        if selectedID == session.id { selectedID = sessions.first?.id }
    }
}
#endif
