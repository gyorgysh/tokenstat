// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
//
// Source-available: source sharing and own builds are permitted.
// Store and commercial distribution of builds is reserved. See LICENSE.
// "tokenstat" is a trademark of pueev OU. See TRADEMARK.md.

import Foundation

#if !os(macOS)


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
            return L10n.text("apple.clientremote.waiting_for_the_computer_to_come_back_on_t.cab8d5a0")
        }
        return L10n.text("apple.clientremote.waiting_for_0_to_come_back_on_the_tunnel.0f402193", "\(host)")
    }

    static func display(_ message: String, host: String?) -> String {
        isAbsent(message) ? waiting(host) : message
    }
}

private struct TodoRemoved: Codable, Sendable { let removed: Bool }

enum ClientRemote {
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


    static func ptySpawn(
        peer: String,
        workspaceID: String,
        command: String,
        args: [String],
        rows: Int,
        cols: Int,
        dark: Bool,
        profileID: String? = nil,
        modelProvider: String? = nil,
        modelID: String? = nil
    ) async throws -> PtySessionInfo {
        var params: [String: Any] = [
            "workspaceId": workspaceID,
            "command": command,
            "args": args,
            "rows": rows,
            "cols": cols,
            "noColor": false,
            "dark": dark,
        ]
        if let profileID { params["profileId"] = profileID }
        if let modelProvider, let modelID {
            params["modelProvider"] = modelProvider
            params["modelId"] = modelID
        }
        return try await Bridge.onPeer(peer, "pty.spawn", params, as: PtySessionInfo.self)
    }

    static func launcherSignIn(
        peer: String,
        id: String,
        rows: Int,
        cols: Int,
        dark: Bool
    ) async throws -> PtySessionInfo {
        try await Bridge.onPeer(
            peer,
            "launcher.signIn",
            ["id": id, "rows": rows, "cols": cols, "dark": dark],
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
        _ = try await Bridge.onPeer(peer, "pty.kill", ["id": id], as: Ack.self)
    }

    static func ptyClose(peer: String, id: String) async throws {
        struct Ack: Codable, Sendable { let closed: Bool? }
        _ = try await Bridge.onPeer(peer, "pty.close", ["id": id], as: Ack.self)
    }

    static func launcherCatalog(peer: String) async throws -> [RemoteLaunchProfile] {
        try await Bridge.onPeer(peer, "launcher.catalog", as: [RemoteLaunchProfile].self)
    }

    static func launcherInstall(peer: String, id: String) async throws -> LauncherInstallResult {
        try await Bridge.onPeer(
            peer,
            "launcher.install",
            ["id": id],
            patience: Bridge.Patience.installer,
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

    static func status(peer: String, workspace: String) async throws -> WorkspaceFolder {
        try await Bridge.onPeer(peer, "workspace.status", ["id": workspace], as: WorkspaceFolder.self)
    }

    static func diff(peer: String, workspace: String, path: String) async throws -> FileDiff {
        try await Bridge.onPeer(
            peer,
            "workspace.diff",
            ["id": workspace, "path": path],
            as: FileDiff.self
        )
    }

    static func log(peer: String, workspace: String, limit: Int = 100) async throws -> [Commit] {
        try await Bridge.onPeer(
            peer,
            "workspace.log",
            ["id": workspace, "limit": limit],
            as: [Commit].self
        )
    }

    static func showCommit(peer: String, workspace: String, commit: String) async throws -> CommitDetail {
        try await Bridge.onPeer(
            peer,
            "workspace.show",
            ["id": workspace, "path": commit],
            as: CommitDetail.self
        )
    }

    static func folderList(peer: String) async throws -> [WorkspaceFolder] {
        try await Bridge.onPeer(peer, "workspace.list", ["includeGeneral": true], as: [WorkspaceFolder].self)
            .map(\.presented)
    }

    static func summaries(peer: String) async throws -> [WorkspaceSummary] {
        try await Bridge.onPeer(peer, "workspace.summary", as: [WorkspaceSummary].self)
    }

    static func recentChats(peer: String, limit: Int = 50) async throws -> [ChatRecentConversation] {
        let chats = try await Bridge.recentChats(peer: peer, limit: limit)
        var seen = Set<String>()
        return chats.filter { !$0.id.isEmpty && seen.insert($0.id).inserted }
    }


    static func todoCards(peer: String) async throws -> [TodoCard] {
        try await Bridge.onPeer(peer, "todo.list", ["includeArchived": true], as: [TodoCard].self)
    }

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
                "budgetSeconds": kind == .note ? 0 : defaultTaskBudgetSeconds,
            ],
            as: TodoCard.self
        )
    }

    static func todoMove(peer: String, id: String, column: String) async throws -> TodoCard {
        try await Bridge.onPeer(
            peer,
            "todo.update",
            ["id": id, "column": column],
            as: TodoCard.self
        )
    }

    static func todoRetitle(peer: String, id: String, title: String, notes: String? = nil) async throws -> TodoCard {
        var parameters: [String: Any] = ["id": id, "title": title]
        if let notes { parameters["notes"] = notes }
        return try await Bridge.onPeer(peer, "todo.update", parameters, as: TodoCard.self)
    }

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
                "budgetSeconds": defaultTaskBudgetSeconds,
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

    static func createAutomation(peer: String, job: Automation) async throws -> Automation {
        try await Bridge.onPeer(peer, "automation.create", ["job": job.payload], as: Automation.self)
    }

    static func createAutomationOnce(peer: String, job: Automation, operationID: String) async throws -> AutomationCreationOutcome {
        try await Bridge.onPeer(
            peer,
            "automation.createOnce",
            ["job": job.payload, "operationId": operationID],
            as: AutomationCreationOutcome.self
        )
    }

    static func automationCreationReceipt(peer: String, operationID: String) async throws -> AutomationCreationOutcome? {
        try await Bridge.onPeer(
            peer,
            "automation.creationReceipt",
            ["operationId": operationID],
            as: AutomationCreationOutcome?.self
        )
    }

    static func updateAutomation(peer: String, job: Automation) async throws -> Automation {
        try await Bridge.onPeer(peer, "automation.update", ["job": job.payload], as: Automation.self)
    }

    static func editAutomation(peer: String, job: Automation, revision: UInt64) async throws -> Automation {
        try await Bridge.onPeer(
            peer,
            "automation.edit",
            ["job": job.payload, "expectedRevision": revision],
            as: Automation.self
        )
    }

    static func removeAutomation(peer: String, id: String) async throws {
        struct Removed: Codable, Sendable { let removed: Bool? }
        _ = try await Bridge.onPeer(peer, "automation.remove", ["id": id], as: Removed.self)
    }

    static func automationBackends(peer: String) async throws -> [AgentBackend] {
        try await Bridge.onPeer(peer, "automation.backends", as: [AgentBackend].self)
    }

    static func automationQueue(peer: String) async throws -> AutomationQueue {
        try await Bridge.onPeer(peer, "automation.queue", as: AutomationQueue.self)
    }

    static func setAutomationQueue(
        peer: String,
        defaultBudgetSeconds: UInt64,
        maxConcurrent: UInt32
    ) async throws -> AutomationQueue {
        try await Bridge.onPeer(
            peer,
            "automation.setQueue",
            [
                "defaultBudgetSeconds": defaultBudgetSeconds,
                "maxConcurrent": maxConcurrent,
            ],
            as: AutomationQueue.self
        )
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

    static func runAutomationOnce(peer: String, id: String, operationID: String) async throws -> AutomationRunOutcome {
        try await Bridge.onPeer(
            peer,
            "automation.runOnce",
            ["id": id, "operationId": operationID],
            as: AutomationRunOutcome.self
        )
    }

    static func automationRunReceipt(peer: String, operationID: String) async throws -> AutomationRunOutcome? {
        try await Bridge.onPeer(
            peer,
            "automation.runReceipt",
            ["operationId": operationID],
            as: AutomationRunOutcome?.self
        )
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
        mode: String = "execute",
        autonomy: String = "bypass",
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

    static func createWorkflow(peer: String, graph: WorkflowGraph) async throws -> WorkflowGraph {
        try await Bridge.onPeer(
            peer,
            "workflow.create",
            ["workflow": try ClientJSON.object(graph)],
            as: WorkflowGraph.self
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

    static func editWorkflow(peer: String, graph: WorkflowGraph, revision: UInt64) async throws -> WorkflowGraph {
        try await Bridge.onPeer(
            peer,
            "workflow.edit",
            ["workflow": try ClientJSON.object(graph), "expectedRevision": revision],
            as: WorkflowGraph.self
        )
    }

    static func removeWorkflow(peer: String, id: String) async throws {
        struct Removed: Codable, Sendable { let removed: Bool? }
        _ = try await Bridge.onPeer(peer, "workflow.remove", ["id": id], as: Removed.self)
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


enum ClientAccessWatch {
    static let interval: Duration = .seconds(5)
    static let attempts = 180
}

#endif
