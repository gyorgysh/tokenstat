// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
//
// Source-available: source sharing and own builds are permitted.
// Store and commercial distribution of builds is reserved. See LICENSE.
// "tokenstat" is a trademark of pueev OU. See TRADEMARK.md.

#if os(macOS)
import AppKit
import Foundation
import Observation

@MainActor
@Observable
final class TerminalsModel {
    var sessions: [TerminalSession] = []
    var selectedID: String?
    var errorMessage: String?
    var sshSessions: SSHSessionsModel?
    private var workspaceSSHIDs = UserDefaults.standard.dictionary(forKey: "workspace.sshSessionTabs") as? [String: [String]] ?? [:]

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

    @ObservationIgnored private var closingHostIDs: Set<String> = []
    @ObservationIgnored private var listGeneration: UInt64 = 0
    @ObservationIgnored private var sessionRevision: UInt64 = 0

    init() {
        TerminalWheelForwarder.install()
        TerminalMouseForwarder.install()
    }

    var selected: TerminalSession? {
        sessions.first { $0.id == selectedID }
    }

    func sessions(in workspaceID: String) -> [TerminalSession] {
        sessions.filter {
            $0.workspaceID == workspaceID && !$0.isInspectorShell
        }
    }

    func workspaceTerminals(in workspaceID: String) -> [WorkspaceTerminal] {
        let local = sessions(in: workspaceID).map(WorkspaceTerminal.init)
        let remote = (workspaceSSHIDs[workspaceID] ?? []).compactMap { id in
            sshSessions?.sessions.first { $0.id == id }.map(WorkspaceTerminal.init)
        }
        return local + remote
    }

    func attach(_ session: SSHLiveTerminal, in workspaceID: String) {
        if !(workspaceSSHIDs[workspaceID] ?? []).contains(session.id) {
            workspaceSSHIDs[workspaceID, default: []].append(session.id)
            UserDefaults.standard.set(workspaceSSHIDs, forKey: "workspace.sshSessionTabs")
        }
        select(WorkspaceTerminal(session), in: workspaceID)
    }

    private func paneSelection(in workspaceID: String) -> TerminalPaneSelection {
        TerminalPaneSelection(selectedID: selectedByWorkspace[workspaceID],
                              leadingID: splitLeadingID[workspaceID], trailingID: splitTrailingID[workspaceID])
    }

    private func apply(_ selection: TerminalPaneSelection, in workspaceID: String) {
        selectedByWorkspace[workspaceID] = selection.selectedID
        splitLeadingID[workspaceID] = selection.leadingID
        splitTrailingID[workspaceID] = selection.trailingID
    }

    func activeTerminal(in workspaceID: String) -> WorkspaceTerminal? {
        let available = workspaceTerminals(in: workspaceID)
        let id = paneSelection(in: workspaceID).active(in: available.map(\.id))
        return available.first { $0.id == id }
    }

    func leadingTerminal(in workspaceID: String) -> WorkspaceTerminal? {
        let available = workspaceTerminals(in: workspaceID)
        let id = paneSelection(in: workspaceID).panes(in: available.map(\.id), split: layout(for: workspaceID).isSplit).leading
        return available.first { $0.id == id }
    }

    func trailingTerminal(in workspaceID: String) -> WorkspaceTerminal? {
        let available = workspaceTerminals(in: workspaceID)
        let id = paneSelection(in: workspaceID).panes(in: available.map(\.id), split: layout(for: workspaceID).isSplit).trailing
        return available.first { $0.id == id }
    }

    func reconcilePane(in workspaceID: String) {
        var selection = paneSelection(in: workspaceID)
        if selection.reconcile(available: workspaceTerminals(in: workspaceID).map(\.id)) {
            setLayout(.single, for: workspaceID)
        }
        apply(selection, in: workspaceID)
    }

    private(set) var splitLayout: [String: TerminalSplitLayout] = [:]
    private(set) var splitFraction: [String: Double] = [:]
    private(set) var splitLeadingID: [String: String] = [:]
    private(set) var splitTrailingID: [String: String] = [:]
    private var paneFocusIDs: Set<String> = []
    private var paneFocusClaims = TerminalFocusClaims()

    func layout(for workspaceID: String) -> TerminalSplitLayout {
        if let cached = splitLayout[workspaceID] { return cached }
        let stored = WorkspacePreference.splitLayout(for: workspaceID)
        splitLayout[workspaceID] = stored
        return stored
    }

    func setLayout(_ layout: TerminalSplitLayout, for workspaceID: String) {
        splitLayout[workspaceID] = layout
        WorkspacePreference.setSplitLayout(layout, for: workspaceID)
        var selection = paneSelection(in: workspaceID)
        selection.setSplit(layout.isSplit, available: workspaceTerminals(in: workspaceID).map(\.id))
        apply(selection, in: workspaceID)
    }

    func swapPanes(in workspaceID: String) {
        guard layout(for: workspaceID).isSplit else { return }
        var selection = paneSelection(in: workspaceID)
        selection.swapPanes(available: workspaceTerminals(in: workspaceID).map(\.id))
        apply(selection, in: workspaceID)
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
        leadingTerminal(in: workspaceID)?.local
    }

    func trailingSession(in workspaceID: String) -> TerminalSession? {
        trailingTerminal(in: workspaceID)?.local
    }

    func sendToOtherHalf(_ session: TerminalSession) {
        sendToOtherHalf(WorkspaceTerminal(session), in: session.workspaceID)
    }

    func sendToOtherHalf(_ session: WorkspaceTerminal, in workspaceID: String) {
        guard !workspaceID.isEmpty else { return }
        if !layout(for: workspaceID).isSplit {
            setLayout(.side, for: workspaceID)
        }
        var selection = paneSelection(in: workspaceID)
        selection.sendToOtherHalf(session.id, available: workspaceTerminals(in: workspaceID).map(\.id))
        apply(selection, in: workspaceID)
        selectedID = selection.selectedID
    }

    func collapseIfNeeded(afterClosing session: TerminalSession) {
        reconcilePane(in: session.workspaceID)
    }

    func active(in workspaceID: String) -> TerminalSession? {
        activeTerminal(in: workspaceID)?.local
    }

    func focus(_ ids: Set<String>) {
        paneFocusIDs = ids
        applyFocus()
    }

    func focus(_ id: String?) {
        focus(id.map { [$0] } ?? [])
    }

    func focus(owner: UUID, ids: Set<String>) {
        paneFocusIDs = []
        paneFocusClaims.update(owner: owner, ids: ids)
        applyFocus()
    }

    func acknowledgeVisibleAttention() {
        for session in sessions where session.isFocused {
            session.acknowledgeAttention()
        }
    }

    private func applyFocus() {
        let visible = paneFocusIDs.union(paneFocusClaims.visibleIDs)
        for session in sessions {
            let next = visible.contains(session.id)
            if session.isFocused != next { session.isFocused = next }
        }
    }

    func select(_ session: TerminalSession) {
        let workspaceID = session.workspaceID
        guard !workspaceID.isEmpty else { selectedID = session.id; return }
        select(WorkspaceTerminal(session), in: workspaceID)
    }

    func select(_ session: WorkspaceTerminal, in workspaceID: String) {
        var selection = paneSelection(in: workspaceID)
        selection.select(session.id, available: workspaceTerminals(in: workspaceID).map(\.id), split: layout(for: workspaceID).isSplit)
        apply(selection, in: workspaceID)
        selectedID = session.id
        if let remote = session.ssh { sshSessions?.select(remote) }
    }

    func load() async {
        listGeneration &+= 1
        let generation = listGeneration
        let revision = sessionRevision
        do {
            let list = try await Bridge.ptyList()
            guard !Task.isCancelled, generation == listGeneration, revision == sessionRevision else { return }
            var byHostID: [String: PtySessionInfo] = [:]
            for info in list { byHostID[info.id] = info }

            let gone = sessions.filter {
                !$0.isPending && !$0.isInspectorShell && byHostID[$0.hostID] == nil
            }
            for session in gone {
                session.stop()
                sessions.removeAll { $0.id == session.id }
                reconcilePane(in: session.workspaceID)
            }

            let knownHostIDs = Set(sessions.map(\.hostID))

            for info in list
            where !knownHostIDs.contains(info.id)
                && info.hidden != true
                && !closingHostIDs.contains(info.id) {
                if sessions.contains(where: { $0.isPending }) { continue }
                let session = TerminalSession(info: info)
                session.start()
                sessions.append(session)
            }

            retagInspectorShells()
            if selectedID == nil, let first = sessions.first(where: { !$0.isInspectorShell }) {
                select(first)
            }
            if let selectedID, !selectedID.hasPrefix("ssh:"), !sessions.contains(where: { $0.id == selectedID }) {
                self.selectedID = sessions.first(where: { !$0.isInspectorShell })?.id
            }
            errorMessage = nil
        } catch {
            guard !Task.isCancelled, generation == listGeneration, revision == sessionRevision else { return }
            if Bridge.isHostRecoveryError(error) { return }
            errorMessage = error.localizedDescription
        }
    }

    private func dedupe(hostID: String, keeping keeper: TerminalSession) {
        let extras = sessions.filter { $0.hostID == hostID && $0.id != keeper.id }
        for extra in extras {
            extra.stop()
            sessions.removeAll { $0.id == extra.id }
            if selectedID == extra.id { select(keeper) }
        }
    }

    @discardableResult
    func open(_ info: PtySessionInfo) -> TerminalSession {
        sessionRevision &+= 1
        if let existing = sessions.first(where: { $0.hostID == info.id }) {
            select(existing)
            focus(existing.id)
            return existing
        }
        let session = TerminalSession(info: info)
        session.start()
        sessions.append(session)
        select(session)
        focus(session.id)
        return session
    }

    func watch() async {
        while !Task.isCancelled {
            try? await Task.sleep(for: .seconds(10))
            guard !Task.isCancelled else { return }
            await load()
        }
    }

    @discardableResult
    func begin(
        workspace: WorkspaceFolder,
        command: String,
        rows: Int = 24,
        cols: Int = 80,
        selectAfter: Bool = true
    ) -> TerminalSession {
        sessionRevision &+= 1
        let session = TerminalSession(
            pendingCommand: command,
            workspace: workspace,
            rows: rows,
            cols: cols
        )
        sessions.append(session)
        if selectAfter {
            select(session)
            focus(session.id)
        }
        return session
    }

    @discardableResult
    func complete(
        _ session: TerminalSession,
        args: [String],
        rows: Int,
        cols: Int,
        modelProvider: String? = nil,
        modelID: String? = nil,
        profileID: String? = nil,
        hidden: Bool = false,
        selectAfter: Bool = true
    ) async -> TerminalSession? {
        guard sessions.contains(where: { $0.id == session.id }) else { return nil }
        do {
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
                profileID: profileID,
                hidden: hidden
            )
            guard sessions.contains(where: { $0.id == session.id }) else {
                closingHostIDs.insert(info.id)
                defer { closingHostIDs.remove(info.id) }
                try? await Bridge.ptyClose(id: info.id)
                return nil
            }
            sessionRevision &+= 1
            session.attach(info: info)
            dedupe(hostID: info.id, keeping: session)
            if selectAfter {
                select(session)
            }
            errorMessage = nil
            return session
        } catch {
            if !Bridge.isHostRecoveryError(error) {
                errorMessage = error.localizedDescription
            }
            sessionRevision &+= 1
            session.stop()
            sessions.removeAll { $0.id == session.id }
            reconcilePane(in: session.workspaceID)
            return nil
        }
    }

    @discardableResult
    func start(
        workspace: WorkspaceFolder,
        command: String,
        args: [String],
        rows: Int = 24,
        cols: Int = 80,
        modelProvider: String? = nil,
        modelID: String? = nil,
        profileID: String? = nil
    ) async -> TerminalSession? {
        let session = begin(workspace: workspace, command: command, rows: rows, cols: cols)
        return await complete(
            session,
            args: args,
            rows: rows,
            cols: cols,
            modelProvider: modelProvider,
            modelID: modelID,
            profileID: profileID
        )
    }

    func close(_ session: TerminalSession) async {
        sessionRevision &+= 1
        session.stop()
        sessions.removeAll { $0.id == session.id }
        if !session.isPending {
            let hostID = session.hostID
            closingHostIDs.insert(hostID)
            Task {
                defer { closingHostIDs.remove(hostID) }
                try? await Bridge.ptyClose(id: hostID)
            }
        }
        collapseIfNeeded(afterClosing: session)
        if selectedID == session.id {
            if !session.workspaceID.isEmpty {
                selectedID = activeTerminal(in: session.workspaceID)?.id
            } else {
                selectedID = sessions.first(where: { !$0.isInspectorShell })?.id
            }
        }
        if session.isInspectorShell {
            WorkspacePreference.setInspectorShellHostID(nil, for: session.workspaceID)
        }
    }

    func close(_ session: WorkspaceTerminal, in workspaceID: String) async {
        if let local = session.local {
            await close(local)
            return
        }
        guard let remote = session.ssh else { return }
        for workspace in Array(workspaceSSHIDs.keys) {
            workspaceSSHIDs[workspace]?.removeAll { $0 == remote.id }
            reconcilePane(in: workspace)
        }
        UserDefaults.standard.set(workspaceSSHIDs, forKey: "workspace.sshSessionTabs")
        if selectedID == session.id { selectedID = activeTerminal(in: workspaceID)?.id }
        await sshSessions?.close(remote)
    }

    func retagInspectorShells() {
        for session in sessions where !session.isInspectorShell {
            let host = WorkspacePreference.inspectorShellHostID(for: session.workspaceID)
            if let host, session.hostID == host {
                session.isInspectorShell = true
            }
        }
    }
}
#endif
