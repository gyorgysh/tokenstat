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
    }

    var selected: TerminalSession? {
        sessions.first { $0.id == selectedID }
    }

    func sessions(in workspaceID: String, includeInspector: Bool = false) -> [TerminalSession] {
        sessions.filter {
            $0.workspaceID == workspaceID && (includeInspector || !$0.isInspectorShell)
        }
    }

    /// Layout of the terminal column in this folder.
    private(set) var splitLayout: [String: TerminalSplitLayout] = [:]
    /// Divider position, 0.2...0.8, leading share of the column.
    private(set) var splitFraction: [String: Double] = [:]
    /// Left / top session when split. Positions stay put when focus moves.
    private(set) var splitLeadingID: [String: String] = [:]
    /// Right / bottom session when split.
    private(set) var splitTrailingID: [String: String] = [:]
    /// Inspector bottom console, per folder.
    private(set) var inspectorConsoleOn: [String: Bool] = [:]
    /// Follow the focused session, or a tiny shell.
    private(set) var inspectorConsoleModes: [String: InspectorConsoleMode] = [:]
    /// Sessions the main pane is showing. Combined with the console set.
    private var paneFocusIDs: Set<String> = []
    /// Sessions the inspector console is watching.
    private var consoleFocusIDs: Set<String> = []

    func layout(for workspaceID: String) -> TerminalSplitLayout {
        if let cached = splitLayout[workspaceID] { return cached }
        let stored = WorkspacePreference.splitLayout(for: workspaceID)
        splitLayout[workspaceID] = stored
        return stored
    }

    func setLayout(_ layout: TerminalSplitLayout, for workspaceID: String) {
        splitLayout[workspaceID] = layout
        WorkspacePreference.setSplitLayout(layout, for: workspaceID)
        if !layout.isSplit {
            splitLeadingID[workspaceID] = nil
            splitTrailingID[workspaceID] = nil
            return
        }
        if splitLeadingID[workspaceID] == nil {
            splitLeadingID[workspaceID] = active(in: workspaceID)?.id
        }
        if splitTrailingID[workspaceID] == nil {
            let lead = splitLeadingID[workspaceID]
            splitTrailingID[workspaceID] = sessions(in: workspaceID)
                .first { $0.id != lead }?.id
        }
    }

    func fraction(for workspaceID: String) -> Double {
        if let cached = splitFraction[workspaceID] { return cached }
        let stored = WorkspacePreference.splitFraction(for: workspaceID)
        splitFraction[workspaceID] = stored
        return stored
    }

    func setFraction(_ fraction: Double, for workspaceID: String) {
        let clamped = min(0.8, max(0.2, fraction))
        splitFraction[workspaceID] = clamped
        WorkspacePreference.setSplitFraction(clamped, for: workspaceID)
    }

    func leadingSession(in workspaceID: String) -> TerminalSession? {
        guard layout(for: workspaceID).isSplit,
              let id = splitLeadingID[workspaceID]
        else { return active(in: workspaceID) }
        return sessions(in: workspaceID).first { $0.id == id } ?? active(in: workspaceID)
    }

    func trailingSession(in workspaceID: String) -> TerminalSession? {
        guard layout(for: workspaceID).isSplit,
              let id = splitTrailingID[workspaceID]
        else { return nil }
        return sessions(in: workspaceID).first { $0.id == id }
    }

    /// Put `session` in the half that is not focused, opening a side split
    /// when the column is still single.
    func sendToOtherHalf(_ session: TerminalSession) {
        let workspaceID = session.workspaceID
        guard !workspaceID.isEmpty else { return }
        if !layout(for: workspaceID).isSplit {
            setLayout(.side, for: workspaceID)
        }
        let focused = active(in: workspaceID)
        if session.id == focused?.id {
            return
        }
        if session.id == splitLeadingID[workspaceID] || session.id == splitTrailingID[workspaceID] {
            select(session)
            return
        }
        if focused?.id == splitLeadingID[workspaceID] {
            splitTrailingID[workspaceID] = session.id
        } else {
            splitLeadingID[workspaceID] = session.id
        }
    }

    /// The last session in a half closed: collapse back to one pane.
    func collapseIfNeeded(afterClosing session: TerminalSession) {
        let workspaceID = session.workspaceID
        guard layout(for: workspaceID).isSplit else { return }
        let lead = splitLeadingID[workspaceID]
        let trail = splitTrailingID[workspaceID]
        if session.id == lead || session.id == trail {
            if session.id == lead, let trail {
                select(sessions(in: workspaceID).first { $0.id == trail } ?? session)
            } else if session.id == trail, let lead {
                select(sessions(in: workspaceID).first { $0.id == lead } ?? session)
            }
            setLayout(.single, for: workspaceID)
        }
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

    /// Say which sessions are on screen.
    ///
    /// A split shows two, and both have to drain at the visible rate or the
    /// half you are only watching freezes. First responder is a separate
    /// question, answered by the stack. The inspector console is a second
    /// owner: the pane must not un-focus a shell it is not looking at.
    func focus(_ ids: Set<String>) {
        paneFocusIDs = ids
        applyFocus()
    }

    func focus(_ id: String?) {
        focus(id.map { [$0] } ?? [])
    }

    func focusConsole(_ ids: Set<String>) {
        consoleFocusIDs = ids
        applyFocus()
    }

    private func applyFocus() {
        let ids = paneFocusIDs.union(consoleFocusIDs)
        for session in sessions {
            let next = ids.contains(session.id)
            if session.isFocused != next { session.isFocused = next }
        }
    }

    func inspectorConsole(for workspaceID: String) -> Bool {
        if let cached = inspectorConsoleOn[workspaceID] { return cached }
        let stored = WorkspacePreference.inspectorConsole(for: workspaceID)
        inspectorConsoleOn[workspaceID] = stored
        return stored
    }

    func setInspectorConsole(_ on: Bool, for workspaceID: String) {
        inspectorConsoleOn[workspaceID] = on
        WorkspacePreference.setInspectorConsole(on, for: workspaceID)
        if !on {
            focusConsole([])
        }
    }

    func inspectorConsoleMode(for workspaceID: String) -> InspectorConsoleMode {
        if let cached = inspectorConsoleModes[workspaceID] { return cached }
        let stored = WorkspacePreference.inspectorConsoleMode(for: workspaceID)
        inspectorConsoleModes[workspaceID] = stored
        return stored
    }

    func setInspectorConsoleMode(_ mode: InspectorConsoleMode, for workspaceID: String) {
        inspectorConsoleModes[workspaceID] = mode
        WorkspacePreference.setInspectorConsoleMode(mode, for: workspaceID)
    }

    func select(_ session: TerminalSession) {
        let workspaceID = session.workspaceID
        if !workspaceID.isEmpty, layout(for: workspaceID).isSplit {
            let lead = splitLeadingID[workspaceID]
            let trail = splitTrailingID[workspaceID]
            // What the leading half is actually showing. It falls back to the
            // workspace's active session when nothing has been pinned there,
            // so a nil `splitLeadingID` is not an empty pane.
            let showingLead = lead ?? active(in: workspaceID)?.id
            if session.id != lead, session.id != trail {
                if trail == nil, let showingLead, showingLead != session.id {
                    // The split opened a second pane and has been showing
                    // "Another session" ever since. This is that session.
                    // Filling the empty half is what the placeholder asked
                    // for, and replacing the half already in front of the
                    // user meant the split had to be redone by hand.
                    splitLeadingID[workspaceID] = showingLead
                    splitTrailingID[workspaceID] = session.id
                } else {
                    // Both halves are taken: the tab replaces the focused one.
                    let previous = selectedByWorkspace[workspaceID] ?? selectedID
                    if previous == trail {
                        splitTrailingID[workspaceID] = session.id
                    } else {
                        splitLeadingID[workspaceID] = session.id
                    }
                }
            }
        }
        selectedID = session.id
        if !workspaceID.isEmpty {
            selectedByWorkspace[workspaceID] = session.id
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
            // Inspector shells are hidden from `pty.list`, so missing there
            // is not gone.
            let gone = sessions.filter {
                !$0.isPending && !$0.isInspectorShell && byHostID[$0.hostID] == nil
            }
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
            for info in list where !knownHostIDs.contains(info.id) && info.hidden != true {
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

            retagInspectorShells()
            if selectedID == nil, let first = sessions.first(where: { !$0.isInspectorShell }) {
                select(first)
            }
            // Selection can point at a session that was removed as gone.
            if let selectedID, !sessions.contains(where: { $0.id == selectedID }) {
                self.selectedID = sessions.first(where: { !$0.isInspectorShell })?.id
            }
            errorMessage = nil
        } catch {
            // A quiet or unreachable host is not a failed launch. The sidebar
            // footer owns that state. Putting it on `errorMessage` used to
            // raise "Could not start session" every time this 10-second
            // reconcile timed out, which is how a network flap looked like
            // a spawn error on a timer.
            if Bridge.isHostRecoveryError(error) { return }
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
        cols: Int = 80,
        selectAfter: Bool = true
    ) -> TerminalSession {
        let session = TerminalSession(
            pendingCommand: command,
            workspace: workspace,
            rows: rows,
            cols: cols
        )
        sessions.append(session)
        if selectAfter {
            select(session)
            // Focus now, not when the pane's onChange fires next turn. Poll floor
            // is 16ms for focused sessions and 150ms otherwise; the first agent
            // bytes after spawn would otherwise sit in the host buffer for an
            // extra frame or two before the reader noticed.
            focus(session.id)
        }
        return session
    }

    /// Finish a `begin` by talking to the host. Safe if list reconcile already
    /// attached the pending session.
    @discardableResult
    func complete(
        _ session: TerminalSession,
        args: [String],
        rows: Int,
        cols: Int,
        modelProvider: String? = nil,
        modelID: String? = nil,
        hidden: Bool = false,
        selectAfter: Bool = true
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
                dark: Self.isDarkAppearance,
                modelProvider: modelProvider,
                modelID: modelID,
                hidden: hidden
            )
            session.attach(info: info)
            dedupe(hostID: info.id, keeping: session)
            if selectAfter {
                select(session)
            }
            errorMessage = nil
            return session
        } catch {
            // Host silence belongs on the footer card. A real spawn rejection
            // (missing binary, bad args) stays on the launch surface.
            if !Bridge.isHostRecoveryError(error) {
                errorMessage = error.localizedDescription
            }
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
        cols: Int = 80,
        modelProvider: String? = nil,
        modelID: String? = nil
    ) async -> TerminalSession? {
        let session = begin(workspace: workspace, command: command, rows: rows, cols: cols)
        return await complete(
            session,
            args: args,
            rows: rows,
            cols: cols,
            modelProvider: modelProvider,
            modelID: modelID
        )
    }

    /// Kill the process and forget the session. The host's buffer goes with it.
    func close(_ session: TerminalSession) async {
        if !session.isPending {
            try? await Bridge.ptyClose(id: session.hostID)
        }
        session.stop()
        sessions.removeAll { $0.id == session.id }
        collapseIfNeeded(afterClosing: session)
        if selectedID == session.id {
            if !session.workspaceID.isEmpty {
                selectedByWorkspace[session.workspaceID] = sessions(in: session.workspaceID).first?.id
            }
            selectedID = sessions.first(where: { !$0.isInspectorShell })?.id
        }
        if session.isInspectorShell {
            WorkspacePreference.setInspectorShellHostID(nil, for: session.workspaceID)
        }
    }

    /// Re-apply the inspector-shell mark after a host reconcile. The flag is
    /// local. The host only knows a hidden-or-not pty, and this shell is a
    /// normal one that we keep off the strip.
    func retagInspectorShells() {
        for session in sessions where !session.isInspectorShell {
            let host = WorkspacePreference.inspectorShellHostID(for: session.workspaceID)
            if let host, session.hostID == host {
                session.isInspectorShell = true
            }
        }
    }

    /// A small login shell for the inspector console. Not an agent TUI.
    @discardableResult
    func startInspectorShell(workspace: WorkspaceFolder, rows: Int, cols: Int) async -> TerminalSession? {
        if let existing = sessions(in: workspace.id, includeInspector: true)
            .first(where: \.isInspectorShell)
        {
            return existing
        }
        if let host = WorkspacePreference.inspectorShellHostID(for: workspace.id),
           let info = try? await Bridge.ptyInfo(id: host),
           info.alive
        {
            let session = TerminalSession(info: info)
            session.isInspectorShell = true
            sessions.append(session)
            return session
        }
        let shell = ProcessInfo.processInfo.environment["SHELL"].flatMap { $0.isEmpty ? nil : $0 }
            ?? "/bin/zsh"
        let session = begin(
            workspace: workspace,
            command: shell,
            rows: rows,
            cols: cols,
            selectAfter: false
        )
        session.isInspectorShell = true
        let started = await complete(
            session,
            args: [],
            rows: rows,
            cols: cols,
            hidden: true,
            selectAfter: false
        )
        if let started, !started.isPending {
            WorkspacePreference.setInspectorShellHostID(started.hostID, for: workspace.id)
        }
        return started
    }
}
#endif
