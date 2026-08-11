// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
//
// Source-available for review, NOT open source. See LICENSE: no rights to
// redistribute, publish, or ship a build are granted. Read it, study it, run
// your own build of it.
// "tokenstat" is a trademark of pueev OU. See TRADEMARK.md.

#if os(macOS)
import AppKit
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
    /// Client id of the selected session (stable; never the host's `pty-N`).
    var selectedID: String?
    var errorMessage: String?

    /// Whether the app is painting dark right now, so a spawning agent can be
    /// told which background it is drawing on.
    ///
    /// Read from the effective appearance rather than from a SwiftUI
    /// environment: this runs at spawn time, in a model, and the effective
    /// appearance also accounts for an appearance the app forces on itself.
    ///
    /// Only ever read at spawn. A program that reads its background does so
    /// once at startup, so switching the system theme under a running agent
    /// cannot repaint it, and pretending otherwise would be a lie in the UI.
    static var isDarkAppearance: Bool {
        NSApp.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
    }
    private var selectedByWorkspace: [String: String] = [:]

    init() {
        // The wheel is a terminal-wide concern, not a per-session one, so it is
        // wired up once here rather than by whichever session appears first.
        TerminalWheelForwarder.install()
        observeReturn()
    }

    /// Notification tokens for the return observers.
    ///
    /// Kept rather than discarded so it is visible that they are never
    /// removed, which is correct here: this model is created once and lives as
    /// long as the app, and the blocks hold `self` weakly, so there is nothing
    /// to break and nothing kept alive by the registration.
    private var returnObservers: [NSObjectProtocol] = []

    /// Put every session back on the fast path when the user comes back to the
    /// app or uncovers the window.
    ///
    /// In-app focus already drives the read loop: switching sessions, opening a
    /// file over the terminal, leaving for Home. None of that fires when the
    /// user Cmd-Tabs away, or puts another window in front, which is the far
    /// more common way to leave a terminal and come back to it. Without this
    /// the app learned it was in front again only when something happened to
    /// touch the pane.
    private func observeReturn() {
        let center = NotificationCenter.default
        let appIsBack = [
            NSApplication.didBecomeActiveNotification,
            NSApplication.didUnhideNotification,
        ]
        for name in appIsBack {
            returnObservers.append(
                center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                    MainActor.assumeIsolated { self?.resumeAll() }
                }
            )
        }
        // Occlusion fires in both directions and for every window. Only a
        // window that just became visible is a return.
        returnObservers.append(
            center.addObserver(
                forName: NSWindow.didChangeOcclusionStateNotification,
                object: nil,
                queue: .main
            ) { [weak self] note in
                guard let window = note.object as? NSWindow,
                      window.occlusionState.contains(.visible)
                else { return }
                MainActor.assumeIsolated { self?.resumeAll() }
            }
        )
    }

    /// Wake every live session. Cheap: a session with nothing to say goes back
    /// to its own floor within a couple of reads.
    func resumeAll() {
        for session in sessions {
            session.resume()
        }
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
            var byHostID: [String: PtySessionInfo] = [:]
            for info in list { byHostID[info.id] = info }

            // Forget sessions the host no longer has.
            // A pending session is not on the host yet: the spawn is in
            // flight, so it must not be treated as a session that vanished.
            let gone = sessions.filter { !$0.isPending && byHostID[$0.hostID] == nil }
            for session in gone {
                session.stop()
                sessions.removeAll { $0.id == session.id }
            }

            // Host ids already represented by a local session (pending ones
            // still use a synthetic host id, so they never match).
            let knownHostIDs = Set(sessions.map(\.hostID))

            // Adopt sessions that appeared since we last looked (another
            // surface, or the host itself). Prefer attaching a pending local
            // spawn over creating a second session: spawn completion and this
            // list can race, and creating both was the "session appears,
            // vanishes, comes back" glitch.
            for info in list where !knownHostIDs.contains(info.id) {
                if let pending = pendingMatch(for: info) {
                    pending.attach(info: info)
                    // Drop any accidental second copy with the same host id.
                    dedupe(hostID: info.id, keeping: pending)
                    continue
                }
                let session = TerminalSession(info: info)
                session.start()
                sessions.append(session)
            }

            if selectedID == nil, let first = sessions.first { select(first) }
            // Selection can point at a session that was removed as gone.
            if let selectedID, !sessions.contains(where: { $0.id == selectedID }) {
                self.selectedID = sessions.first?.id
            }
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    /// A pending local spawn that should absorb this host session rather than
    /// becoming a second tab.
    private func pendingMatch(for info: PtySessionInfo) -> TerminalSession? {
        let workspace = info.workspaceID ?? ""
        let pending = sessions.filter {
            $0.isPending && ($0.workspaceID == workspace || workspace.isEmpty)
        }
        guard !pending.isEmpty else { return nil }
        // Prefer the same command when several pendings share a workspace.
        if let exact = pending.first(where: { commandMatches($0.command, info.command) }) {
            return exact
        }
        // One pending in this workspace: it is almost certainly this spawn.
        if pending.count == 1 { return pending[0] }
        return pending.first
    }

    private func commandMatches(_ local: String, _ host: String) -> Bool {
        if local == host { return true }
        // Catalog may send a basename; the host reports the path it exec'd.
        let localBase = URL(fileURLWithPath: local).lastPathComponent
        let hostBase = URL(fileURLWithPath: host).lastPathComponent
        return localBase == hostBase
    }

    /// Keep one session per host id. The list reconcile and spawn completion
    /// can both claim the same pty; the keeper is the one the user already has
    /// on screen.
    private func dedupe(hostID: String, keeping keeper: TerminalSession) {
        let extras = sessions.filter { $0.hostID == hostID && $0.id != keeper.id }
        for extra in extras {
            extra.stop()
            sessions.removeAll { $0.id == extra.id }
            if selectedID == extra.id { select(keeper) }
        }
    }

    /// Keep the session list in step with the host while the app is open.
    ///
    /// Sessions do not only start from this window: another machine can spawn
    /// one on this host, and an automation can too. Without a slow reconcile
    /// loop the host's own window would never learn about them, which is the
    /// parity failure of "I started a session remotely and it did not appear
    /// on the machine it runs on".
    func watch() async {
        while !Task.isCancelled {
            try? await Task.sleep(for: .seconds(10))
            guard !Task.isCancelled else { return }
            await load()
        }
    }

    /// Put a pending session on screen **now**, before any host call.
    ///
    /// The click handler must call this synchronously. Waiting until an
    /// `async` `Task` starts left the launcher up for a frame (or longer under
    /// main-actor load), which is the blink before the tty pane appears.
    @discardableResult
    func begin(
        workspace: WorkspaceFolder,
        command: String,
        rows: Int = 24,
        cols: Int = 80
    ) -> TerminalSession {
        let session = TerminalSession(
            pendingCommand: command,
            workspace: workspace,
            rows: rows,
            cols: cols
        )
        sessions.append(session)
        select(session)
        // Focus now, not when the pane's onChange fires next turn. Poll floor
        // is 16ms for focused sessions and 150ms otherwise; the first agent
        // bytes after spawn would otherwise sit in the host buffer for an
        // extra frame or two before the reader noticed.
        focus(session.id)
        return session
    }

    /// Finish a `begin` by talking to the host. Safe if list reconcile already
    /// attached the pending session.
    @discardableResult
    func complete(
        _ session: TerminalSession,
        args: [String],
        rows: Int,
        cols: Int
    ) async -> TerminalSession? {
        guard sessions.contains(where: { $0.id == session.id }) else { return nil }
        do {
            // The caller measured the pane; spawn at that grid so the first
            // paint is not a 24×80 flash.
            let info = try await Bridge.ptySpawn(
                workspaceID: session.workspaceID,
                command: session.command,
                args: args,
                rows: rows,
                cols: cols,
                noColor: TerminalPreferences.disablesColor,
                dark: Self.isDarkAppearance
            )
            session.attach(info: info)
            dedupe(hostID: info.id, keeping: session)
            select(session)
            errorMessage = nil
            return session
        } catch {
            errorMessage = error.localizedDescription
            session.stop()
            sessions.removeAll { $0.id == session.id }
            return nil
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
        let session = begin(workspace: workspace, command: command, rows: rows, cols: cols)
        return await complete(session, args: args, rows: rows, cols: cols)
    }

    /// Kill the process and forget the session. The host's buffer goes with it.
    func close(_ session: TerminalSession) async {
        if !session.isPending {
            try? await Bridge.ptyClose(id: session.hostID)
        }
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
