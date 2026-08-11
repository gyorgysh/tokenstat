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
        try await Bridge.onPeer(peer, "pty.info", ["id": id], as: PtySessionInfo.self)
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
            ["id": id, "offset": offset, "waitMs": waitMs],
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

    static func ptyResize(peer: String, id: String, rows: Int, cols: Int) async throws {
        struct Ack: Codable, Sendable { let rows: Int; let cols: Int }
        _ = try await Bridge.onPeer(
            peer,
            "pty.resize",
            ["id": id, "rows": rows, "cols": cols],
            as: Ack.self
        )
    }

    static func ptyKill(peer: String, id: String) async throws {
        struct Ack: Codable, Sendable { let ok: Bool? }
        _ = try? await Bridge.onPeer(peer, "pty.kill", ["id": id], as: Ack.self)
    }

    static func ptyClose(peer: String, id: String) async throws {
        struct Ack: Codable, Sendable { let closed: Bool? }
        _ = try? await Bridge.onPeer(peer, "pty.close", ["id": id], as: Ack.self)
    }

    static func launcherCatalog(peer: String) async throws -> [RemoteLaunchProfile] {
        try await Bridge.onPeer(peer, "launcher.catalog", as: [RemoteLaunchProfile].self)
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
