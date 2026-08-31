// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
//
// Source-available for review, NOT open source. See LICENSE: no rights to
// redistribute, publish, or ship a build are granted. Read it, study it, run
// your own build of it.
// "tokenstat" is a trademark of pueev OU. See TRADEMARK.md.

import Foundation

#if !os(macOS)

/// Helpers for the phone machine plane: every call goes to a peer over the
/// tunnel. Local `pty.*` and `workspace.*` do not exist without `local-host`.

/// Copy for a tunnel that is mid-reconnect, not gone.
enum ClientTunnelCopy {
    static func isAbsent(_ message: String) -> Bool {
        let lower = message.lowercased()
        return lower.contains("no_such_peer")
            || lower.contains("not on the tunnel")
            || lower.contains("did not pair the channel")
            || lower.contains("tunnel is not connected")
            || lower.contains("tunnel disconnected")
    }

    static func waiting(_ name: String?) -> String {
        let host = name?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if host.isEmpty {
            return "Waiting for the computer to come back on the tunnel."
        }
        return "Waiting for \(host) to come back on the tunnel."
    }

    static func display(_ message: String, host: String?) -> String {
        isAbsent(message) ? waiting(host) : message
    }
}

/// `todo.remove`'s answer. `Bridge`'s own is private to that file.
private struct TodoRemoved: Codable, Sendable { let removed: Bool }

enum ClientRemote {
    /// Split a folder id from `Bridge.remoteWorkspaces` (`remote:<peer>:<id>`).
    static func parts(of folder: WorkspaceFolder) -> (peer: String, workspace: String)? {
        let parts = folder.id.split(separator: ":", maxSplits: 2).map(String.init)
        guard parts.count == 3, parts[0] == "remote" else { return nil }
        return (parts[1], parts[2])
    }

    static func peerKey(of folder: WorkspaceFolder) -> String? {
        parts(of: folder)?.peer
    }

    static func rawWorkspaceID(of folder: WorkspaceFolder) -> String? {
        parts(of: folder)?.workspace
    }

    // MARK: - Pty on a peer

    static func ptySpawn(
        peer: String,
        workspaceID: String,
        command: String,
        args: [String],
        rows: Int,
        cols: Int,
        dark: Bool
    ) async throws -> PtySessionInfo {
        try await Bridge.onPeer(
            peer,
            "pty.spawn",
            [
                "workspaceId": workspaceID,
                "command": command,
                "args": args,
                "rows": rows,
                "cols": cols,
                "noColor": false,
                "dark": dark,
            ],
            as: PtySessionInfo.self
        )
    }

    static func ptyList(peer: String) async throws -> [PtySessionInfo] {
        try await Bridge.onPeer(peer, "pty.list", ["includeRemote": false], as: [PtySessionInfo].self)
    }

    static func ptyInfo(peer: String, id: String) async throws -> PtySessionInfo {
        try await Bridge.onPeer(
            peer,
            "pty.info",
            ["id": id, "viewer": TerminalViewer.id],
            as: PtySessionInfo.self
        )
    }

    static func ptyRead(
        peer: String,
        id: String,
        offset: UInt64,
        waitMs: Int = 0
    ) async throws -> PtyChunk {
        try await Bridge.onPeer(
            peer,
            "pty.read",
            ["id": id, "offset": offset, "waitMs": waitMs, "viewer": TerminalViewer.id],
            as: PtyChunk.self
        )
    }

    static func ptyWrite(peer: String, id: String, bytes: [UInt8]) async throws {
        struct Ack: Codable, Sendable { let written: Int }
        _ = try await Bridge.onPeer(
            peer,
            "pty.write",
            ["id": id, "data": Data(bytes).base64EncodedString()],
            as: Ack.self
        )
    }

    /// Say what this phone can show, and get back what the session became.
    ///
    /// The Mac that owns the session is usually watching it too, so the answer
    /// is the smaller of the two geometries. Sending the ask rather than a
    /// command is what stops the Mac being left narrow after the phone closes.
    /// See `TerminalViewer`.
    @discardableResult
    static func ptyResize(
        peer: String,
        id: String,
        rows: Int,
        cols: Int
    ) async throws -> PtySizeAck {
        try await Bridge.onPeer(
            peer,
            "pty.resize",
            ["id": id, "rows": rows, "cols": cols, "viewer": TerminalViewer.id],
            as: PtySizeAck.self
        )
    }

    /// Stop showing a session without stopping the process on the Mac.
    static func ptyDetach(peer: String, id: String) async throws {
        struct Ack: Codable, Sendable { let detached: Bool }
        _ = try await Bridge.onPeer(
            peer,
            "pty.detach",
            ["id": id, "viewer": TerminalViewer.id],
            as: Ack.self
        )
    }

    static func ptyKill(peer: String, id: String) async throws {
        struct Ack: Codable, Sendable { let ok: Bool? }
        _ = try? await Bridge.onPeer(peer, "pty.kill", ["id": id], as: Ack.self)
    }

    static func ptyClose(peer: String, id: String) async throws {
        struct Ack: Codable, Sendable { let closed: Bool? }
        _ = try await Bridge.onPeer(peer, "pty.close", ["id": id], as: Ack.self)
    }

    static func launcherCatalog(peer: String) async throws -> [RemoteLaunchProfile] {
        try await Bridge.onPeer(peer, "launcher.catalog", as: [RemoteLaunchProfile].self)
    }

    /// Run a profile's official installer on the machine that owns this
    /// workspace. The peer's daemon runs its own hardcoded command for the
    /// id, never a string from here.
    static func launcherInstall(peer: String, id: String) async throws -> LauncherInstallResult {
        try await Bridge.onPeer(
            peer,
            "launcher.install",
            ["id": id],
            as: LauncherInstallResult.self
        )
    }

    static func launcherHide(peer: String, id: String) async throws {
        struct Result: Codable, Sendable { var hidden: Bool?; var id: String? }
        _ = try await Bridge.onPeer(peer, "launcher.hide", ["id": id], as: Result.self)
    }

    static func launcherShow(peer: String, id: String) async throws {
        struct Result: Codable, Sendable { var hidden: Bool?; var id: String? }
        _ = try await Bridge.onPeer(peer, "launcher.show", ["id": id], as: Result.self)
    }

    // MARK: - Files on a peer

    static func tree(peer: String, workspace: String, path: String) async throws -> [TreeEntry] {
        try await Bridge.onPeer(
            peer,
            "workspace.tree",
            ["id": workspace, "path": path],
            as: [TreeEntry].self
        )
    }

    static func readFile(peer: String, workspace: String, path: String) async throws -> FileText {
        try await Bridge.onPeer(
            peer,
            "workspace.read",
            ["id": workspace, "path": path],
            as: FileText.self
        )
    }

    /// Re-read one folder's git state on the machine that owns it.
    ///
    /// The peer answers with its own local id, which is not the id this side
    /// uses for a remote folder, so only the parts that go stale are taken and
    /// the caller keeps the identity it already had.
    static func status(peer: String, workspace: String) async throws -> WorkspaceFolder {
        try await Bridge.onPeer(peer, "workspace.status", ["id": workspace], as: WorkspaceFolder.self)
    }

    /// One file's changes against HEAD, on the machine that owns the folder.
    static func diff(peer: String, workspace: String, path: String) async throws -> FileDiff {
        try await Bridge.onPeer(
            peer,
            "workspace.diff",
            ["id": workspace, "path": path],
            as: FileDiff.self
        )
    }

    /// Every badge on the folder screen, in one call instead of five lists.
    static func summaries(peer: String) async throws -> [WorkspaceSummary] {
        try await Bridge.onPeer(peer, "workspace.summary", as: [WorkspaceSummary].self)
    }

    // MARK: - A folder's work, on the machine that owns it

    /// The peer's whole board, list and all. Filtering to one folder happens
    /// on this side: the host answers the same `todo.list` it answers locally,
    /// so the phone cannot see a card the Mac would not.
    static func todoCards(peer: String) async throws -> [TodoCard] {
        try await Bridge.onPeer(peer, "todo.list", ["includeArchived": true], as: [TodoCard].self)
    }

    /// Add a card or a note to the peer's board.
    ///
    /// The same `todo.create` the Mac calls. A note carries a folder like a
    /// task does: unfiled is a choice made in the sheet, never a side effect
    /// of writing it somewhere.
    /// The Mac's default time limit for a delegated run, in seconds.
    ///
    /// Zero means *no limit* on the host, so sending zero from here would have
    /// made every card captured on a phone able to run an agent forever. Three
    /// hours is what the Mac's form starts on.
    static let defaultTaskBudgetSeconds: UInt64 = 180 * 60

    static func todoCreate(
        peer: String,
        title: String,
        kind: TodoKind,
        notes: String,
        workspaceID: String
    ) async throws -> TodoCard {
        try await Bridge.onPeer(
            peer,
            "todo.create",
            [
                "title": title,
                "kind": kind.rawValue,
                "notes": notes,
                "column": "backlog",
                "backend": "",
                "workspaceId": workspaceID,
                // A note is never delegated, so its budget is moot; a task
                // gets the same limit it would have been given on the Mac.
                "budgetSeconds": kind == .note ? 0 : defaultTaskBudgetSeconds,
            ],
            as: TodoCard.self
        )
    }

    /// Move a card between columns, including into the archive.
    static func todoMove(peer: String, id: String, column: String) async throws -> TodoCard {
        try await Bridge.onPeer(
            peer,
            "todo.update",
            ["id": id, "column": column],
            as: TodoCard.self
        )
    }

    /// Rewrite a note's text.
    ///
    /// A note is its title, so this is the whole edit. The Mac cannot do this
    /// yet: it captures and archives, and changing what you wrote means
    /// writing it again.
    static func todoRetitle(peer: String, id: String, title: String) async throws -> TodoCard {
        try await Bridge.onPeer(
            peer,
            "todo.update",
            ["id": id, "title": title],
            as: TodoCard.self
        )
    }

    /// Turn a note into a card on this folder's board.
    ///
    /// The same update the Mac makes: the note's text becomes the prompt and
    /// the card lands in the backlog. One card changes kind rather than a new
    /// one appearing beside a note that then has to be cleaned up.
    static func todoConvertToTask(
        peer: String,
        id: String,
        prompt: String,
        workspaceID: String
    ) async throws -> TodoCard {
        try await Bridge.onPeer(
            peer,
            "todo.update",
            [
                "id": id,
                "column": "backlog",
                "kind": TodoKind.task.rawValue,
                "notes": prompt,
                "workspaceId": workspaceID,
            ],
            as: TodoCard.self
        )
    }

    static func todoRemove(peer: String, id: String) async throws {
        _ = try await Bridge.onPeer(peer, "todo.remove", ["id": id], as: TodoRemoved.self)
    }

    static func automations(peer: String) async throws -> [Automation] {
        try await Bridge.onPeer(peer, "automation.list", as: [Automation].self)
    }

    static func automationRuns(peer: String) async throws -> [RunRecord] {
        try await Bridge.onPeer(peer, "automation.runs", as: [RunRecord].self)
    }

    static func workflows(peer: String) async throws -> [WorkflowGraph] {
        try await Bridge.onPeer(peer, "workflow.list", as: [WorkflowGraph].self)
    }

    static func workflowRuns(peer: String) async throws -> [WorkflowRunRecord] {
        try await Bridge.onPeer(peer, "workflow.runs", as: [WorkflowRunRecord].self)
    }

    static func runAutomation(peer: String, id: String) async throws -> Automation {
        try await Bridge.onPeer(peer, "automation.run", ["id": id], as: Automation.self)
    }

    static func setAutomation(peer: String, id: String, enabled: Bool) async throws -> Automation {
        try await Bridge.onPeer(
            peer,
            enabled ? "automation.enable" : "automation.disable",
            ["id": id],
            as: Automation.self
        )
    }

    static func killAutomation(peer: String, runID: String) async throws {
        struct Ack: Codable, Sendable { let killed: Bool? }
        _ = try await Bridge.onPeer(peer, "automation.kill", ["id": runID], as: Ack.self)
    }

    static func automationTranscript(
        peer: String,
        id: String,
        offset: UInt64
    ) async throws -> TranscriptChunk {
        try await Bridge.onPeer(
            peer,
            "automation.transcript",
            ["id": id, "offset": offset],
            as: TranscriptChunk.self
        )
    }

    // MARK: - Chat on a peer

    static func chatBackends(peer: String) async throws -> [ChatBackend] {
        try await Bridge.chatBackends(peer: peer)
    }

    static func chats(peer: String, workspaceID: String) async throws -> [ChatConversation] {
        try await Bridge.chats(workspaceID: workspaceID, peer: peer)
    }

    static func createChat(
        peer: String,
        workspaceID: String,
        backend: String = "claude",
        mode: String = "plan",
        autonomy: String = "standard",
        personaID: String? = nil
    ) async throws -> ChatConversation {
        try await Bridge.createChat(
            workspaceID: workspaceID,
            backend: backend,
            mode: mode,
            autonomy: autonomy,
            personaID: personaID,
            peer: peer
        )
    }

    static func updateChat(
        peer: String,
        id: String,
        title: String? = nil,
        backend: String? = nil,
        model: String? = nil,
        effort: String? = nil,
        mode: String? = nil,
        autonomy: String? = nil,
        personaID: String? = nil,
        systemPrompt: String? = nil
    ) async throws -> ChatConversation {
        try await Bridge.updateChat(
            id: id,
            title: title,
            backend: backend,
            model: model,
            effort: effort,
            mode: mode,
            autonomy: autonomy,
            personaID: personaID,
            systemPrompt: systemPrompt,
            peer: peer
        )
    }

    static func removeChat(peer: String, id: String) async throws {
        try await Bridge.removeChat(id: id, peer: peer)
    }

    static func sendChat(peer: String, id: String, text: String, attachmentIDs: [String] = []) async throws -> ChatConversation {
        try await Bridge.sendChat(id: id, text: text, attachmentIDs: attachmentIDs, peer: peer)
    }

    static func stopChat(peer: String, id: String) async throws {
        try await Bridge.stopChat(id: id, peer: peer)
    }

    static func chatEvents(peer: String, id: String, offset: UInt64) async throws -> ChatEventChunk {
        try await Bridge.chatEvents(id: id, offset: offset, peer: peer)
    }

    static func chatApprovals(peer: String, id: String) async throws -> [ChatApproval] {
        try await Bridge.chatApprovals(id: id, peer: peer)
    }

    static func resolveChatApproval(peer: String, id: String, choice: String) async throws -> ChatApproval {
        try await Bridge.resolveChatApproval(id: id, choice: choice, peer: peer)
    }

    static func chatPersonas(peer: String, workspaceID: String) async throws -> ChatPersonaList {
        try await Bridge.chatPersonas(workspaceID: workspaceID, peer: peer)
    }

    static func saveChatPersona(
        peer: String,
        workspaceID: String,
        persona: ChatPersona
    ) async throws -> ChatPersona {
        try await Bridge.saveChatPersona(persona, workspaceID: workspaceID, peer: peer)
    }

    /// Nil when the workspace chose to have no default at all.
    static func setDefaultChatPersona(
        peer: String,
        workspaceID: String,
        personaID: String
    ) async throws -> ChatPersona? {
        try await Bridge.setDefaultChatPersona(
            workspaceID: workspaceID,
            personaID: personaID,
            peer: peer
        )
    }

    static func removeChatPersona(peer: String, id: String) async throws {
        try await Bridge.removeChatPersona(id: id, peer: peer)
    }

    static func attachToChat(
        peer: String,
        id: String,
        name: String,
        data: Data,
        mediaType: String?
    ) async throws -> ChatAttachment {
        try await Bridge.attachToChat(
            id: id,
            name: name,
            data: data,
            mediaType: mediaType,
            peer: peer
        )
    }

    static func attachToChat(peer: String, id: String, file: URL) async throws -> ChatAttachment {
        try await Bridge.attachToChat(id: id, file: file, peer: peer)
    }

    static func runWorkflow(
        peer: String,
        id: String,
        input: String,
        workspaceID: String
    ) async throws -> WorkflowRunRecord {
        try await Bridge.onPeer(
            peer,
            "workflow.run",
            ["id": id, "input": input, "workspaceId": workspaceID],
            as: WorkflowRunRecord.self
        )
    }

    static func updateWorkflow(peer: String, graph: WorkflowGraph) async throws -> WorkflowGraph {
        try await Bridge.onPeer(
            peer,
            "workflow.update",
            ["workflow": try ClientJSON.object(graph)],
            as: WorkflowGraph.self
        )
    }

    static func killWorkflow(peer: String, runID: String) async throws {
        struct Ack: Codable, Sendable { let killed: Bool? }
        _ = try await Bridge.onPeer(peer, "workflow.kill", ["id": runID], as: Ack.self)
    }

    static func continueWorkflow(peer: String, runID: String) async throws -> WorkflowRunRecord {
        try await Bridge.onPeer(peer, "workflow.continue", ["id": runID], as: WorkflowRunRecord.self)
    }

    static func workflowTranscript(
        peer: String,
        runID: String,
        nodeID: String,
        offset: UInt64
    ) async throws -> TranscriptChunk {
        try await Bridge.onPeer(
            peer,
            "workflow.transcript",
            ["id": runID, "nodeId": nodeID, "offset": offset],
            as: TranscriptChunk.self
        )
    }

    static func writeFile(
        peer: String,
        workspace: String,
        path: String,
        content: String
    ) async throws {
        struct Outcome: Codable, Sendable { let ok: Bool? }
        _ = try await Bridge.onPeer(
            peer,
            "workspace.write",
            ["id": workspace, "path": path, "content": content],
            as: Outcome.self
        )
    }
}


/// How long this device waits for another computer to answer a request.
///
/// The host drops an unanswered request after fifteen minutes
/// (`PENDING_TTL` in `screen_policy`), so a watch that outlived that would be
/// polling for an answer to a question nobody can see any more. Kept in step
/// with it deliberately: two different windows would mean a card that says it
/// is waiting for something that is already gone.
enum ClientAccessWatch {
    static let interval: Duration = .seconds(5)
    /// Fifteen minutes at the interval above.
    static let attempts = 180
}

#endif
