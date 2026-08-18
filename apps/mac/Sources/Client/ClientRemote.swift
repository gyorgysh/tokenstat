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

    // MARK: - A folder's work, on the machine that owns it

    /// The peer's whole board, list and all. Filtering to one folder happens
    /// on this side: the host answers the same `todo.list` it answers locally,
    /// so the phone cannot see a card the Mac would not.
    static func todoCards(peer: String) async throws -> [TodoCard] {
        try await Bridge.onPeer(peer, "todo.list", ["includeArchived": true], as: [TodoCard].self)
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

#endif
