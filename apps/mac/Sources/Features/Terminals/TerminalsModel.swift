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
    private var selectedByWorkspace: [String: String] = [:]

    init() {
        // The wheel is a terminal-wide concern, not a per-session one, so it is
        // wired up once here rather than by whichever session appears first.
        TerminalWheelForwarder.install()
    }

    var selected: TerminalSession? {
        sessions.first { $0.id == selectedID }
    }

    func sessions(in workspaceID: String) -> [TerminalSession] {
        sessions.filter { $0.workspaceID == workspaceID }
    }

    /// The last session selected in a workspace, falling back to its first
    /// session. Selection belongs to the workspace, not the current pane, so
    /// switching projects does not lose the place the user was working in.
    func active(in workspaceID: String) -> TerminalSession? {
        let available = sessions(in: workspaceID)
        if let id = selectedByWorkspace[workspaceID],
           let session = available.first(where: { $0.id == id }) {
            return session
        }
        return available.first
    }

    /// Say which session is on screen, or nil when none is.
    ///
    /// Exactly one at a time: only one workspace pane is mounted, so a second
    /// focused session would be a session nobody can see polling as though
    /// somebody were typing into it.
    func focus(_ id: String?) {
        for session in sessions where session.isFocused != (session.id == id) {
            session.isFocused = session.id == id
        }
    }

    func select(_ session: TerminalSession) {
        selectedID = session.id
        if !session.workspaceID.isEmpty {
            selectedByWorkspace[session.workspaceID] = session.id
        }
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
            // Reading starts here, not when a view first appears. A session
            // nobody has opened yet still has to drain the host's bounded
            // buffer, or its earliest output is dropped before anyone looks.
            let known = Set(sessions.map(\.id))
            for info in list where !known.contains(info.id) {
                let session = TerminalSession(info: info)
                session.start()
                sessions.append(session)
            }

            if selectedID == nil, let first = sessions.first { select(first) }
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    /// Launch a command in a workspace's folder and select it.
    @discardableResult
    func start(
        workspace: WorkspaceFolder,
        command: String,
        args: [String],
        rows: Int = 24,
        cols: Int = 80
    ) async -> TerminalSession? {
        do {
            // The caller measures the pane and passes its grid, so the shell
            // prints its first prompt at the size it will keep. Spawning at
            // 24x80 and letting the first layout correct it makes every session
            // draw once and then repaint, which is the flash on launch.
            let info = try await Bridge.ptySpawn(
                workspaceID: workspace.id,
                command: command,
                args: args,
                rows: rows,
                cols: cols
            )
            let session = TerminalSession(info: info)
            sessions.append(session)
            select(session)
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
        if selectedID == session.id {
            if !session.workspaceID.isEmpty {
                selectedByWorkspace[session.workspaceID] = sessions(in: session.workspaceID).first?.id
            }
            selectedID = sessions.first?.id
        }
    }
}
#endif
