// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
//
// Source-available for review, NOT open source. See LICENSE: no rights to
// redistribute, publish, or ship a build are granted. Read it, study it, run
// your own build of it.
// "tokenstat" is a trademark of pueev OU. See TRADEMARK.md.

import Foundation
import TokenstatFFI

/// Errors surfaced by the bridge.
///
/// `core` carries a message the Rust side already wrote for a human. Do not
/// rewrite those in the UI: they name the actual file or setting at fault.
enum BridgeError: LocalizedError {
    case core(code: String, message: String)
    case decoding(method: String, underlying: String)

    var errorDescription: String? {
        switch self {
        case let .core(_, message):
            return message
        case let .decoding(method, underlying):
            return "Could not read the response to \(method): \(underlying)"
        }
    }
}

/// Envelope every method returns. One decoding path for success and failure.
private struct Envelope<T: Decodable>: Decodable {
    struct Failure: Decodable {
        let code: String
        let message: String
    }

    let ok: Bool
    let result: T?
    let error: Failure?
}

/// Swift face of the Rust core.
///
/// Deliberately thin. It owns no state and caches nothing, because the Rust
/// side already holds the open archive and the loaded price book. When the host
/// daemon lands, only the body of `invoke` changes: a socket write instead of a
/// function call, with the same method names and the same envelope.
enum Bridge {
    /// Call across the boundary and decode the result.
    ///
    /// Synchronous and potentially slow. Everything public here is `async` and
    /// hops off the main actor first.
    private static func invoke<T: Decodable>(
        _ method: String,
        _ params: [String: Any] = [:],
        as _: T.Type
    ) throws -> T {
        let paramData = try JSONSerialization.data(withJSONObject: params)
        let paramString = String(decoding: paramData, as: UTF8.self)

        // `tokenstat_ffi_call` never returns null and always returns JSON, so
        // the only failure modes below are decoding ones.
        guard let raw = tokenstat_ffi_call(method, paramString) else {
            throw BridgeError.core(code: "null", message: "The core returned nothing.")
        }
        defer { tokenstat_ffi_string_free(raw) }

        let json = String(cString: raw)
        let data = Data(json.utf8)

        let decoder = JSONDecoder()
        let envelope: Envelope<T>
        do {
            envelope = try decoder.decode(Envelope<T>.self, from: data)
        } catch {
            // A failed call still decodes as an envelope, so reaching here means
            // the shape itself was wrong. Surface the raw payload: a protocol
            // mismatch is otherwise invisible.
            throw BridgeError.decoding(method: method, underlying: "\(error) in \(json.prefix(400))")
        }

        guard envelope.ok, let result = envelope.result else {
            let failure = envelope.error
            throw BridgeError.core(
                code: failure?.code ?? "unknown",
                message: failure?.message ?? "The core rejected the call without saying why."
            )
        }
        return result
    }

    /// Run a call off the main actor.
    ///
    /// Every method below goes through this. Reports run SQL and `scan` walks
    /// thousands of files, so none of it belongs on the thread that draws.
    private static func background<T: Decodable & Sendable>(
        _ method: String,
        _ params: [String: Any] = [:],
        as type: T.Type
    ) async throws -> T {
        try await Task.detached(priority: .userInitiated) {
            try invoke(method, params, as: type)
        }.value
    }

    // MARK: - Methods

    static func info() async throws -> Info {
        try await background("info", as: Info.self)
    }

    static func totals(_ query: Query = Query()) async throws -> Totals {
        try await background("totals", ["query": query.payload], as: Totals.self)
    }

    static func report(group: GroupBy, query: Query = Query()) async throws -> [Bucket] {
        try await background(
            "report",
            ["group": group.rawValue, "query": query.payload],
            as: [Bucket].self
        )
    }

    static func blocks(_ query: Query = Query()) async throws -> [Block] {
        try await background("blocks", ["query": query.payload], as: [Block].self)
    }

    /// Read every discoverable log source into the archive. Slow by nature:
    /// this is the call that walks the disk.
    static func scan() async throws -> ScanReport {
        try await background("scan", as: ScanReport.self)
    }
}

// MARK: - Account

extension Bridge {
    /// Who is signed in. Signed out is a normal result, not an error: the
    /// bridge reports `signedIn: false` so the UI can offer sign-in rather
    /// than show a failure.
    static func account() async throws -> Account {
        try await background("account.status", as: Account.self)
    }

    /// Begin a device authorization. Returns the code to show and the URL to
    /// open. Opening the browser is this side's job.
    static func startLogin() async throws -> DeviceLogin {
        try await background("account.deviceStart", as: DeviceLogin.self)
    }

    /// Poll once. Never sleeps: the caller owns the cadence, which is what
    /// keeps the window responsive and the flow cancellable.
    static func pollLogin() async throws -> DevicePoll {
        try await background("account.devicePoll", as: DevicePoll.self)
    }

    static func cancelLogin() async {
        // Best effort. A stale pending login is harmless, it expires anyway,
        // and failing to clear it must not surface as an error to the user.
        _ = try? await background("account.cancelLogin", as: Ack.self)
    }

    static func signOut() async throws {
        _ = try await background("account.logout", as: Ack.self)
    }

    /// Send the aggregate window to the account. Network-bound and slow.
    static func sync(dryRun: Bool = false) async throws -> SyncOutcome {
        try await background("sync.run", ["dryRun": dryRun], as: SyncOutcome.self)
    }
}

/// For methods whose result is only "it worked".
private struct Ack: Codable, Sendable {}

extension Bridge {
    /// Two-level report. `project` split by `source` answers "which harnesses
    /// ran in this folder", which is what the sidebar tree is.
    static func reportSplit(
        group: GroupBy,
        splitBy: GroupBy,
        query: Query = Query()
    ) async throws -> [SplitBucket] {
        try await background(
            "report.split",
            ["group": group.rawValue, "splitBy": splitBy.rawValue, "query": query.payload],
            as: [SplitBucket].self
        )
    }
}

// MARK: - Workspaces

extension Bridge {
    /// Registered folders with their current git state. Reads git per folder,
    /// so treat it as a refresh rather than something to call on every keypress.
    static func workspaces() async throws -> [WorkspaceFolder] {
        try await background("workspace.list", as: [WorkspaceFolder].self)
    }

    static func addWorkspace(path: String) async throws -> WorkspaceFolder {
        try await background("workspace.add", ["path": path], as: WorkspaceFolder.self)
    }

    /// Forgets the entry. Never deletes the folder.
    static func removeWorkspace(id: String) async throws {
        _ = try await background("workspace.remove", ["id": id], as: Removed.self)
    }

    static func renameWorkspace(id: String, name: String) async throws {
        _ = try await background("workspace.rename", ["id": id, "name": name], as: Renamed.self)
    }

    /// Recent commits, newest first. Empty for a folder that is not a
    /// repository, and for one whose first commit has not happened yet.
    static func workspaceLog(id: String, limit: Int = 100) async throws -> [Commit] {
        try await background("workspace.log", ["id": id, "limit": limit], as: [Commit].self)
    }

    /// One directory of the file tree. Lazy: pass the relative path of the
    /// folder being opened, or "" for the workspace root.
    static func workspaceTree(id: String, path: String = "") async throws -> [TreeEntry] {
        try await background("workspace.tree", ["id": id, "path": path], as: [TreeEntry].self)
    }

    /// One file's diff against HEAD, staged and unstaged together.
    static func workspaceDiff(id: String, path: String) async throws -> FileDiff {
        try await background("workspace.diff", ["id": id, "path": path], as: FileDiff.self)
    }
}

// MARK: - Git, the parts that write

/// These change the repository, so every one of them is called from a button
/// and never from a timer, a watcher, or a refresh. See
/// `tokenstat_workspace::gitwrite` for why that split is kept in the Rust too.
extension Bridge {
    static func stage(id: String, paths: [String]) async throws -> GitOutcome {
        try await background("workspace.stage", ["id": id, "paths": paths], as: GitOutcome.self)
    }

    static func unstage(id: String, paths: [String]) async throws -> GitOutcome {
        try await background("workspace.unstage", ["id": id, "paths": paths], as: GitOutcome.self)
    }

    static func commit(id: String, message: String) async throws -> GitOutcome {
        try await background("workspace.commit", ["id": id, "message": message], as: GitOutcome.self)
    }

    static func push(id: String) async throws -> GitOutcome {
        try await background("workspace.push", ["id": id], as: GitOutcome.self)
    }
}

private struct Removed: Codable, Sendable { let removed: Bool }
private struct Renamed: Codable, Sendable { let renamed: Bool }

// MARK: - Terminals

extension Bridge {
    /// Launch a command in the workspace's folder. The process is owned by the
    /// host, so it outlives this window and any tab switch.
    static func ptySpawn(
        workspaceID: String,
        command: String,
        args: [String],
        rows: Int,
        cols: Int
    ) async throws -> PtySessionInfo {
        try await background("pty.spawn", [
            "workspaceId": workspaceID,
            "command": command,
            "args": args,
            "rows": rows,
            "cols": cols,
        ], as: PtySessionInfo.self)
    }

    static func ptyList() async throws -> [PtySessionInfo] {
        try await background("pty.list", as: [PtySessionInfo].self)
    }

    static func ptyInfo(id: String) async throws -> PtySessionInfo {
        try await background("pty.info", ["id": id], as: PtySessionInfo.self)
    }

    /// Output after `offset`. Returns immediately, empty when there is none.
    /// Poll, do not push.
    static func ptyRead(id: String, offset: UInt64) async throws -> PtyChunk {
        try await background("pty.read", ["id": id, "offset": offset], as: PtyChunk.self)
    }

    /// Keystrokes. Bytes, not text: an escape sequence is a byte stream.
    static func ptyWrite(id: String, bytes: [UInt8]) async throws {
        _ = try await background(
            "pty.write",
            ["id": id, "data": Data(bytes).base64EncodedString()],
            as: PtyWriteAck.self
        )
    }

    static func ptyResize(id: String, rows: Int, cols: Int) async throws {
        _ = try await background(
            "pty.resize",
            ["id": id, "rows": rows, "cols": cols],
            as: PtySizeAck.self
        )
    }

    /// Stop the process. Killing an already dead session is not an error.
    static func ptyKill(id: String) async throws {
        _ = try await background("pty.kill", ["id": id], as: Ack.self)
    }

    /// Kill and forget. The host's buffer goes with it.
    static func ptyClose(id: String) async throws {
        _ = try await background("pty.close", ["id": id], as: Ack.self)
    }
}

private struct PtyWriteAck: Codable, Sendable { let written: Int }
private struct PtySizeAck: Codable, Sendable { let rows: Int; let cols: Int }
