// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
//
// Source-available for review, NOT open source. See LICENSE: no rights to
// redistribute, publish, or ship a build are granted. Read it, study it, run
// your own build of it.
// "tokenstat" is a trademark of pueev OU. See TRADEMARK.md.

import Foundation

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
/// side already holds the open archive and the loaded price book. Which
/// `Transport` carries a call is chosen once, at launch, by `Bridge.connect()`.
/// Every method below is written as though there were only one.
enum Bridge {
    /// How long a call waits on a silent host before giving up.
    ///
    /// Not a deadline on the call, a budget on silence: the socket resets it
    /// every time bytes arrive, so a large answer is never truncated. The point
    /// is that no call can wait forever, because a call that waits forever
    /// holds the thread it runs on forever.
    enum Patience {
        /// Terminal polling, keystrokes, highlighting. A host that has not
        /// answered one of these in a few seconds is not busy, it is stuck, and
        /// the caller polls again in milliseconds anyway.
        static let interactive: TimeInterval = 10

        /// Reports, git, the workspace list. Slow work, but bounded work.
        static let standard: TimeInterval = 60

        /// `scan` walks every log on the machine and `sync` uploads. Both can
        /// legitimately say nothing for minutes on a large archive.
        static let long: TimeInterval = 600
    }

    /// How calls leave this process, and whether a daemon owns them.
    ///
    /// One box behind one lock, because these two are read together and must
    /// agree. `connect()` can run after terminals are already polling from
    /// other threads, so an unsynchronized `var` here was a real data race with
    /// a crash that pointed nowhere useful.
    private struct Route {
        var transport: Transport
        var isHosted: Bool
    }

    private static let routeLock = NSLock()
    nonisolated(unsafe) private static var route = Route(
        transport: InProcessTransport(),
        isHosted: false
    )

    private static var currentRoute: Route {
        routeLock.lock()
        defer { routeLock.unlock() }
        return route
    }

    /// Which transport is in use, for the interface and for a bug report.
    static var transportDescription: String { currentRoute.transport.describedAs }

    /// True when a daemon owns this session's work, so terminals outlive the
    /// window. The Machines screen will need to say this out loud.
    static var isHosted: Bool { currentRoute.isHosted }

    /// Choose a transport. Call once, before anything else.
    ///
    /// Prefers a running daemon. The daemon runs under launchd, so its
    /// terminals survive the app quitting and can be picked up again, which is
    /// the entire point of `tokenstat-hostd` and the step `remote-transport.md`
    /// puts first. In-process is the fallback for a machine where nobody
    /// installed the agent, not a faster path worth preferring: the socket's
    /// keystroke round trip measures in hundredths of a millisecond.
    static func connect() {
        #if os(macOS)
        // Do not initialize the Rust archive synchronously just to discover
        // the socket path. That made a cold Finder launch wait for the whole
        // archive before SwiftUI could show its first frame. ProjectDirs uses
        // this same standard Application Support location on macOS.
        if let path = Self.localHostSocketPath,
           let hosted = SocketTransport.connecting(to: path)
        {
            adopt(Route(transport: hosted, isHosted: true))
            return
        }
        #endif
        adopt(Route(transport: InProcessTransport(), isHosted: false))
    }

    private static func adopt(_ next: Route) {
        routeLock.lock()
        route = next
        routeLock.unlock()
    }

    #if os(macOS)
    private static var localHostSocketPath: String? {
        FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first?.appendingPathComponent("ai.tokenstat.tokenstat/host.sock").path
    }
    #endif

    /// Re-probe the host after the app provisions or repairs its launch agent.
    ///
    /// Only ever upgrades in-process to hosted. Going the other way would
    /// strand every process the daemon owns behind an interface that had
    /// quietly started answering from somewhere else, and the symptom is
    /// terminals vanishing. If a daemon we were talking to has gone, the honest
    /// answer is the error the socket already returns, not a silent demotion.
    static func reconnect() {
        guard !isHosted else { return }
        connect()
    }

    /// Call across the boundary and decode the result.
    ///
    /// Synchronous and potentially slow. Everything public here is `async` and
    /// hops off the main actor first.
    private static func invoke<T: Decodable>(
        _ method: String,
        _ params: [String: Any] = [:],
        patience: TimeInterval = Patience.standard,
        as _: T.Type
    ) throws -> T {
        let paramData = try JSONSerialization.data(withJSONObject: params)
        let paramString = String(decoding: paramData, as: UTF8.self)

        // Every transport answers with an envelope or throws, so the only
        // failure modes left below are decoding ones.
        let json = try Self.call(
            method: method,
            params: paramString,
            patience: patience,
            route: currentRoute
        )
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

    /// Run one transport call, repairing the local daemon when it is gone.
    ///
    /// A daemon that dies under the app is not something the user should fix
    /// by hand: the bridge reinstalls and restarts the launch agent, waits for
    /// the socket, and retries the call once before anything is reported. The
    /// repair only runs for `host_unreachable`. A timeout means the daemon is
    /// alive and busy, which is not the same situation at all.
    private static func call(
        method: String,
        params: String,
        patience: TimeInterval,
        route: Route
    ) throws -> String {
        // A host that is still booting fails the first connect, then comes up.
        // Repair and retry a bounded number of times so the caller gets its
        // answer instead of an error the moment the host is ready again.
        var attempt = 0
        while true {
            do {
                return try route.transport.call(method: method, params: params, patience: patience)
            } catch {
                attempt += 1
                guard route.isHosted,
                      Self.isRepairable(error),
                      attempt < maxHostRepairAttempts,
                      Self.repairHost()
                else {
                    throw error
                }
            }
        }
    }

    /// The urgent variant of `call`: same repair-and-retry loop, urgent
    /// transport path.
    private static func callUrgent(
        method: String,
        params: String,
        patience: TimeInterval
    ) throws -> String {
        var attempt = 0
        while true {
            do {
                return try currentRoute.transport.callUrgent(
                    method: method,
                    params: params,
                    patience: patience
                )
            } catch {
                attempt += 1
                guard currentRoute.isHosted,
                      Self.isRepairable(error),
                      attempt < maxHostRepairAttempts,
                      Self.repairHost()
                else {
                    throw error
                }
            }
        }
    }

    /// Whether a transport error means the daemon is gone rather than busy.
    ///
    /// Only connection-level failures are repairable. A timeout means the
    /// daemon is alive and working, and restarting it would interrupt that
    /// work for no reason.
    private static func isRepairable(_ error: Error) -> Bool {
        guard let bridge = error as? BridgeError, case let .core(code, _) = bridge else {
            return false
        }
        return code == "host_unreachable"
    }

    /// Whether an error means the host was unreachable or silent, which is
    /// worth retrying once it is back.
    ///
    /// Screens use this to keep refreshing while the daemon boots instead of
    /// pinning an error the user did not cause.
    static func isHostRecoveryError(_ error: Error) -> Bool {
        guard let bridge = error as? BridgeError, case let .core(code, _) = bridge else {
            return false
        }
        return code == "host_unreachable" || code == "host_timeout"
    }

    /// How many times a call is retried after repairing the host. The repair
    /// itself waits for the socket, so a host that is merely slow to boot is
    /// given this many chances to answer before an error is shown.
    private static let maxHostRepairAttempts = 3

    /// Bring the local daemon back after it stopped answering.
    ///
    /// Runs on the calls queue, so it can afford to block. Reinstalling the
    /// launch agent is idempotent: it replaces a missing or stale helper and
    /// reloads launchd, and needs no password, because the agent is this
    /// user's own. The reinstall is gated by a cooldown so a burst of failing
    /// calls does not boot the daemon repeatedly; the socket probe itself is
    /// cheap and runs on every failure.
    private static func repairHost() -> Bool {
        #if os(macOS)
        hostRepairLock.lock()
        defer { hostRepairLock.unlock() }

        if let last = lastHostRepairAt,
           Date().timeIntervalSince(last) < hostRepairCooldown
        {
            // Another call already repaired; reuse it rather than repeating it.
            return waitForSocket(seconds: hostRepairShareWait)
        }
        lastHostRepairAt = Date()

        // A failure to reinstall is not the end: the daemon may already be
        // coming up on its own, so the socket poll decides.
        try? HostAgentInstaller.installAndStart()
        return waitForSocket(seconds: hostRepairWait)
        #else
        return false
        #endif
    }

    #if os(macOS)
    private static let hostRepairLock = NSLock()
    nonisolated(unsafe) private static var lastHostRepairAt: Date?
    /// How long a completed repair stays fresh before launchd is touched again.
    private static let hostRepairCooldown: TimeInterval = 30
    /// How long to wait for the socket after the reinstall itself.
    private static let hostRepairWait: TimeInterval = 8
    /// How long a caller arriving mid-repair waits for the socket.
    private static let hostRepairShareWait: TimeInterval = 2

    private static func socketIsUp() -> Bool {
        guard let path = localHostSocketPath else { return false }
        return SocketTransport.connecting(to: path) != nil
    }

    private static func waitForSocket(seconds: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            if socketIsUp() { return true }
            Thread.sleep(forTimeInterval: 0.15)
        }
        return socketIsUp()
    }
    #endif

    /// Where blocking transport work runs.
    ///
    /// Deliberately its own queue and **not** the cooperative pool. A call is a
    /// synchronous socket round trip, and the pool is sized to the core count:
    /// `Task.detached` parked one of its threads per call in a `read(2)`, and
    /// with a terminal poll task and a writer task per session plus the screens
    /// that poll, the pool ran out of threads. Nothing else could make progress
    /// while it did, so the app looked hung with an idle main thread.
    ///
    /// libdispatch grows this queue on demand and the connection ceiling in
    /// `SocketTransport` bounds how many can be blocked at once.
    private static let calls = DispatchQueue(
        label: "ai.tokenstat.bridge.calls",
        qos: .userInitiated,
        attributes: .concurrent
    )

    /// Run blocking work on `calls` and await it.
    private static func offMainActor<T: Sendable>(
        _ work: @escaping @Sendable () throws -> T
    ) async throws -> T {
        try await withCheckedThrowingContinuation { continuation in
            calls.async {
                continuation.resume(with: Result { try work() })
            }
        }
    }

    /// Run a call off the main actor.
    ///
    /// Every method below goes through this. Reports run SQL and `scan` walks
    /// thousands of files, so none of it belongs on the thread that draws.
    private static func background<T: Decodable & Sendable>(
        _ method: String,
        _ params: [String: Any] = [:],
        patience: TimeInterval = Patience.standard,
        as type: T.Type
    ) async throws -> T {
        try await offMainActor {
            try invoke(method, params, patience: patience, as: type)
        }
    }

    /// A one-shot call the user is waiting on. Same decoding as `background`,
    /// but the transport skips the pool wait: opening a terminal must not
    /// queue behind the sessions already polling.
    private static func backgroundUrgent<T: Decodable & Sendable>(
        _ method: String,
        _ params: [String: Any] = [:],
        as type: T.Type
    ) async throws -> T {
        try await offMainActor {
            let paramData = try JSONSerialization.data(withJSONObject: params)
            let paramString = String(decoding: paramData, as: UTF8.self)
            let json = try Self.callUrgent(
                method: method,
                params: paramString,
                patience: Patience.interactive
            )
            let data = Data(json.utf8)
            let envelope: Envelope<T>
            do {
                envelope = try JSONDecoder().decode(Envelope<T>.self, from: data)
            } catch {
                throw BridgeError.decoding(method: method, underlying: "\(error) in \(json.prefix(400))")
            }
            guard envelope.ok else {
                throw BridgeError.core(
                    code: envelope.error?.code ?? "unknown",
                    message: envelope.error?.message
                        ?? "The core rejected the call without saying why."
                )
            }
            guard let result = envelope.result else {
                throw BridgeError.decoding(method: method, underlying: "missing result")
            }
            return result
        }
    }

    /// A call whose result may legitimately be `null`.
    ///
    /// Separate from `invoke` rather than a generic over `T?`, because the
    /// envelope's `result` is already optional: `Envelope<T?>` would nest two
    /// optionals and a successful null would be indistinguishable from a
    /// response that carried no result at all. Here `ok` alone decides whether
    /// the call worked, and `null` means the answer is "nothing".
    private static func invokeOptional<T: Decodable>(
        _ method: String,
        _ params: [String: Any] = [:],
        patience: TimeInterval = Patience.standard,
        as _: T.Type
    ) throws -> T? {
        let paramData = try JSONSerialization.data(withJSONObject: params)
        let paramString = String(decoding: paramData, as: UTF8.self)

        let json = try Self.call(
            method: method,
            params: paramString,
            patience: patience,
            route: currentRoute
        )
        let data = Data(json.utf8)

        let envelope: Envelope<T>
        do {
            envelope = try JSONDecoder().decode(Envelope<T>.self, from: data)
        } catch {
            throw BridgeError.decoding(method: method, underlying: "\(error) in \(json.prefix(400))")
        }

        guard envelope.ok else {
            throw BridgeError.core(
                code: envelope.error?.code ?? "unknown",
                message: envelope.error?.message
                    ?? "The core rejected the call without saying why."
            )
        }
        return envelope.result
    }

    private static func backgroundOptional<T: Decodable & Sendable>(
        _ method: String,
        _ params: [String: Any] = [:],
        patience: TimeInterval = Patience.standard,
        as type: T.Type
    ) async throws -> T? {
        try await offMainActor {
            try invokeOptional(method, params, patience: patience, as: type)
        }
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

    /// The activity grid behind Home's heatmap and streaks.
    ///
    /// Returns nil for an archive with nothing in it yet, which is a state and
    /// not a failure: it is the first thing a new install will ever show.
    /// The activity grid.
    ///
    /// `scope` is `"local"` for this machine's archive or `"account"` for every
    /// machine that syncs. The host answers with which one it actually built,
    /// because an account grid can fall back to a local one and a client that
    /// assumed otherwise would label one machine's year as everybody's.
    static func activityCalendar(
        weeks: Int = 53,
        scope: String = "local"
    ) async throws -> ActivityCalendar? {
        try await backgroundOptional(
            "activity.calendar",
            ["weeks": weeks, "scope": scope],
            // Longer than the default: an account grid is a network call on the
            // host's side, and this one is on the screen that opens first.
            patience: Patience.long,
            as: ActivityCalendar.self
        )
    }

    /// One day's hover detail for the Home heatmap, mirroring the profile page.
    ///
    /// `scope` is `"local"` or `"account"`, matching `activityCalendar`. The
    /// account answer comes from the same cached series the calendar uses, so
    /// moving across the grid costs no extra network calls. A day with no
    /// events is `nil`, which is an answer and not a failure.
    static func dayDetail(
        date: String,
        weeks: Int = 53,
        scope: String = "local"
    ) async throws -> DayDetail? {
        try await backgroundOptional(
            "activity.day",
            ["date": date, "weeks": weeks, "scope": scope],
            as: DayDetail.self
        )
    }

    static func blocks(_ query: Query = Query()) async throws -> [Block] {
        try await background("blocks", ["query": query.payload], as: [Block].self)
    }

    /// Read every discoverable log source into the archive. Slow by nature:
    /// this is the call that walks the disk.
    static func scan() async throws -> ScanReport {
        try await background("scan", patience: Patience.long, as: ScanReport.self)
    }

    /// Fetch remote vendor usage after an explicit user action.
    static func fetchRemotes() async throws -> [FetchReport] {
        try await background("fetch", patience: Patience.long, as: [FetchReport].self)
    }
}

// MARK: - Account

extension Bridge {
    /// Fetch the release's disk image and verify it against the release's own
    /// checksums. The daemon stops at a file on disk; `AppInstaller` decides
    /// whether to trust it.
    static func appUpdateDownload() async throws -> DownloadedFile {
        try await background("app.updateDownload", as: DownloadedFile.self)
    }

    static func appUpdateCheck() async throws -> AppUpdate {
        try await background("app.updateCheck", as: AppUpdate.self)
    }
}

// MARK: - Automations

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
        try await background(
            "sync.run",
            ["dryRun": dryRun],
            patience: Patience.long,
            as: SyncOutcome.self
        )
    }

    static func syncScheduleStatus() async throws -> SyncScheduleStatus {
        try await background("sync.scheduleStatus", as: SyncScheduleStatus.self)
    }

    /// Fetch the hosted list-rate snapshot and reload the session's cached
    /// copy. The daemon does this on its own schedule; the in-process
    /// scheduler is the only thing that can on a machine with no host agent.
    static func pricingRefresh() async throws -> PricingRefresh {
        try await background(
            "pricing.refresh",
            patience: Patience.long,
            as: PricingRefresh.self
        )
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

// MARK: - Plan limits

extension Bridge {
    /// What each vendor says is left of its plan.
    ///
    /// Slow: Codex reads off the disk but Claude is a request. Treat it as a
    /// refresh the user asked for, not something to poll.
    static func usageLimits() async throws -> [ProviderLimits] {
        try await background("usage.limits", patience: Patience.long, as: [ProviderLimits].self)
    }
}

// MARK: - Workspaces

extension Bridge {
    /// Registered folders with their current git state. Reads git per folder,
    /// so treat it as a refresh rather than something to call on every keypress.
    static func workspaces() async throws -> [WorkspaceFolder] {
        try await background("workspace.list", as: [WorkspaceFolder].self)
    }

    static func remoteWorkspaces(peer: Peer) async throws -> [WorkspaceFolder] {
        let folders = try await onPeer(peer.key, "workspace.list", as: [WorkspaceFolder].self)
        return folders.map { folder in
            var folder = folder
            folder.id = "remote:\(peer.key):\(folder.id)"
            folder.machineID = peer.key
            folder.machineLabel = peer.label
            return folder
        }
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
        if let target = remoteWorkspace(id) {
            return try await onPeer(
                target.peer,
                "workspace.log",
                ["id": target.workspace, "limit": limit],
                as: [Commit].self
            )
        }
        return try await background("workspace.log", ["id": id, "limit": limit], as: [Commit].self)
    }

    /// One directory of the file tree. Lazy: pass the relative path of the
    /// folder being opened, or "" for the workspace root.
    static func workspaceTree(id: String, path: String = "") async throws -> [TreeEntry] {
        if let target = remoteWorkspace(id) {
            return try await onPeer(
                target.peer,
                "workspace.tree",
                ["id": target.workspace, "path": path],
                as: [TreeEntry].self
            )
        }
        return try await background("workspace.tree", ["id": id, "path": path], as: [TreeEntry].self)
    }

    /// One file's diff against HEAD, staged and unstaged together.
    static func workspaceDiff(id: String, path: String) async throws -> FileDiff {
        if let target = remoteWorkspace(id) {
            return try await onPeer(
                target.peer,
                "workspace.diff",
                ["id": target.workspace, "path": path],
                as: FileDiff.self
            )
        }
        return try await background("workspace.diff", ["id": id, "path": path], as: FileDiff.self)
    }

    static func workspaceRead(id: String, path: String) async throws -> FileText {
        if let target = remoteWorkspace(id) {
            return try await onPeer(
                target.peer,
                "workspace.read",
                ["id": target.workspace, "path": path],
                as: FileText.self
            )
        }
        return try await background("workspace.read", ["id": id, "path": path], as: FileText.self)
    }

    /// Colour a buffer.
    ///
    /// Takes the text rather than a workspace and a path, for two reasons. The
    /// buffer on screen is what wants colouring, and it is usually not what is
    /// on disk. And it needs no session, so it answers without queuing behind a
    /// `git status` the way anything on the workspace path would.
    static func highlight(path: String, text: String) async throws -> Highlighting {
        try await background(
            "highlight",
            ["path": path, "text": text],
            patience: Patience.interactive,
            as: Highlighting.self
        )
    }

    /// One commit in full: message, files, and their diffs.
    static func workspaceShow(id: String, commit: String) async throws -> CommitDetail {
        if let target = remoteWorkspace(id) {
            return try await onPeer(
                target.peer,
                "workspace.show",
                ["id": target.workspace, "path": commit],
                as: CommitDetail.self
            )
        }
        return try await background("workspace.show", ["id": id, "path": commit], as: CommitDetail.self)
    }
}

// MARK: - Git, the parts that write

/// These change the repository, so every one of them is called from a button
/// and never from a timer, a watcher, or a refresh. See
/// `tokenstat_workspace::gitwrite` for why that split is kept in the Rust too.
extension Bridge {
    static func stage(id: String, paths: [String]) async throws -> GitOutcome {
        if let target = remoteWorkspace(id) {
            return try await onPeer(
                target.peer,
                "workspace.stage",
                ["id": target.workspace, "paths": paths],
                as: GitOutcome.self
            )
        }
        return try await background("workspace.stage", ["id": id, "paths": paths], as: GitOutcome.self)
    }

    static func unstage(id: String, paths: [String]) async throws -> GitOutcome {
        if let target = remoteWorkspace(id) {
            return try await onPeer(
                target.peer,
                "workspace.unstage",
                ["id": target.workspace, "paths": paths],
                as: GitOutcome.self
            )
        }
        return try await background("workspace.unstage", ["id": id, "paths": paths], as: GitOutcome.self)
    }

    static func commit(id: String, message: String) async throws -> GitOutcome {
        if let target = remoteWorkspace(id) {
            return try await onPeer(
                target.peer,
                "workspace.commit",
                ["id": target.workspace, "message": message],
                as: GitOutcome.self
            )
        }
        return try await background("workspace.commit", ["id": id, "message": message], as: GitOutcome.self)
    }

    static func workspaceWrite(id: String, path: String, content: String) async throws -> GitOutcome {
        if let target = remoteWorkspace(id) {
            return try await onPeer(
                target.peer,
                "workspace.write",
                ["id": target.workspace, "path": path, "content": content],
                as: GitOutcome.self
            )
        }
        return try await background(
            "workspace.write",
            ["id": id, "path": path, "content": content],
            as: GitOutcome.self
        )
    }

    static func push(id: String) async throws -> GitOutcome {
        if let target = remoteWorkspace(id) {
            return try await onPeer(target.peer, "workspace.push", ["id": target.workspace], as: GitOutcome.self)
        }
        return try await background("workspace.push", ["id": id], as: GitOutcome.self)
    }
}

private struct Removed: Codable, Sendable { let removed: Bool }
private struct Renamed: Codable, Sendable { let renamed: Bool }

private struct RemoteWorkspaceTarget {
    let peer: String
    let workspace: String
}

private func remoteWorkspace(_ id: String) -> RemoteWorkspaceTarget? {
    guard id.hasPrefix("remote:") else { return nil }
    let parts = id.split(separator: ":", maxSplits: 2).map(String.init)
    guard parts.count == 3 else { return nil }
    return RemoteWorkspaceTarget(peer: parts[1], workspace: parts[2])
}

// MARK: - Terminals

extension Bridge {
    /// Launch a command in the workspace's folder. The process is owned by the
    /// host, so it outlives this window and any tab switch.
    static func ptySpawn(
        workspaceID: String,
        command: String,
        args: [String],
        rows: Int,
        cols: Int,
        noColor: Bool = false
    ) async throws -> PtySessionInfo {
        // Urgent: a person clicked Shell and is watching this round trip. It
        // must not queue behind sessions already polling when the pool is
        // saturated.
        try await backgroundUrgent("pty.spawn", [
            "workspaceId": workspaceID,
            "command": command,
            "args": args,
            "rows": rows,
            "cols": cols,
            "noColor": noColor,
        ], as: PtySessionInfo.self)
    }

    static func ptyList() async throws -> [PtySessionInfo] {
        try await background("pty.list", patience: Patience.interactive, as: [PtySessionInfo].self)
    }

    static func ptyInfo(id: String) async throws -> PtySessionInfo {
        try await background(
            "pty.info",
            ["id": id],
            patience: Patience.interactive,
            as: PtySessionInfo.self
        )
    }

    /// Output after `offset`. Returns immediately, empty when there is none.
    /// Poll, do not push.
    static func ptyRead(id: String, offset: UInt64) async throws -> PtyChunk {
        try await background(
            "pty.read",
            ["id": id, "offset": offset],
            patience: Patience.interactive,
            as: PtyChunk.self
        )
    }

    /// Keystrokes. Bytes, not text: an escape sequence is a byte stream.
    static func ptyWrite(id: String, bytes: [UInt8]) async throws {
        _ = try await background(
            "pty.write",
            ["id": id, "data": Data(bytes).base64EncodedString()],
            patience: Patience.interactive,
            as: PtyWriteAck.self
        )
    }

    static func ptyResize(id: String, rows: Int, cols: Int) async throws {
        _ = try await background(
            "pty.resize",
            ["id": id, "rows": rows, "cols": cols],
            patience: Patience.interactive,
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

// MARK: - Automations

extension Bridge {
    static func automations() async throws -> [Automation] {
        try await background("automation.list", as: [Automation].self)
    }

    static func createAutomation(_ job: Automation) async throws -> Automation {
        try await background("automation.create", ["job": job.payload], as: Automation.self)
    }

    static func updateAutomation(_ job: Automation) async throws -> Automation {
        try await background("automation.update", ["job": job.payload], as: Automation.self)
    }

    static func setAutomation(_ id: String, enabled: Bool) async throws -> Automation {
        try await background(enabled ? "automation.enable" : "automation.disable", ["id": id], as: Automation.self)
    }

    static func runAutomation(_ id: String) async throws -> Automation {
        try await background("automation.run", ["id": id], as: Automation.self)
    }

    static func removeAutomation(_ id: String) async throws {
        _ = try await background("automation.remove", ["id": id], as: Removed.self)
    }

    static func automationRuns() async throws -> [RunRecord] {
        try await background("automation.runs", as: [RunRecord].self)
    }

    /// The agent backends a job can choose, as the daemon knows them.
    static func automationBackends() async throws -> [AgentBackend] {
        try await background("automation.backends", as: [AgentBackend].self)
    }

    /// Output a run produced after `offset`. Poll while the run is running.
    static func automationTranscript(id: String, offset: UInt64) async throws -> TranscriptChunk {
        try await background("automation.transcript", ["id": id, "offset": offset], as: TranscriptChunk.self)
    }

    /// Stop a run before its budget. Used by the todo board's Stop.
    static func automationKill(runID: String) async throws {
        _ = try await background("automation.kill", ["id": runID], as: Ack.self)
    }
}

// MARK: - Todo

extension Bridge {
    static func todoCards() async throws -> [TodoCard] {
        try await background("todo.list", as: [TodoCard].self)
    }

    static func todoCreate(
        title: String, kind: TodoKind, notes: String, column: String, backend: String,
        workspaceID: String, budgetSeconds: UInt64, model: String? = nil, effort: String? = nil
    ) async throws -> TodoCard {
        var params: [String: Any] = [
            "title": title, "kind": kind.rawValue, "notes": notes, "column": column, "backend": backend,
            "workspaceId": workspaceID, "budgetSeconds": budgetSeconds,
        ]
        if let model { params["model"] = model }
        if let effort { params["effort"] = effort }
        return try await background("todo.create", params, as: TodoCard.self)
    }

    static func todoUpdate(
        id: String, column: String? = nil, order: Int64? = nil, title: String? = nil,
        kind: TodoKind? = nil, notes: String? = nil
    ) async throws -> TodoCard {
        var params: [String: Any] = ["id": id]
        if let column { params["column"] = column }
        if let order { params["order"] = order }
        if let title { params["title"] = title }
        if let kind { params["kind"] = kind.rawValue }
        if let notes { params["notes"] = notes }
        return try await background("todo.update", params, as: TodoCard.self)
    }

    static func todoRemove(id: String) async throws {
        _ = try await background("todo.remove", ["id": id], as: Removed.self)
    }

    /// Hand the card to an agent. The card moves to Doing and the run starts.
    static func todoDelegate(id: String) async throws -> TodoCard {
        try await background("todo.delegate", ["id": id], as: TodoCard.self)
    }

    /// Stop a delegated run.
    static func todoStop(id: String) async throws -> TodoCard {
        try await background("todo.stop", ["id": id], as: TodoCard.self)
    }
}

private extension Automation {
    var payload: [String: Any] {
        [
            "id": id, "name": name, "backend": backend,
            "model": model as Any, "effort": effort as Any, "workspaceId": workspaceID,
            "prompt": prompt,
            "schedule": [
                "kind": schedule.kind.rawValue,
                "everySeconds": schedule.everySeconds,
                "hour": schedule.hour,
                "minute": schedule.minute,
                "weekday": schedule.weekday,
            ],
            "budgetSeconds": budgetSeconds, "enabled": enabled,
            "lastRunAtMs": lastRunAtMs as Any, "nextRunAtMs": nextRunAtMs as Any,
            "lastRunID": lastRunID as Any,
        ]
    }
}

private struct PtyWriteAck: Codable, Sendable { let written: Int }
private struct PtySizeAck: Codable, Sendable { let rows: Int; let cols: Int }

// MARK: - Machines

/// This machine's identity, the peers it knows, and calls forwarded to them.
///
/// A front end never speaks the machine-to-machine protocol itself. It asks its
/// own daemon, and the daemon reaches the peer. That is why there is no
/// handshake anywhere in this app, and why an iPad client will not need one
/// either. See `docs/remote-transport.md`.
extension Bridge {
    static func machineIdentity() async throws -> MachineIdentity {
        try await background("machine.identity", as: MachineIdentity.self)
    }

    /// Name this machine. An empty name puts the system's own name back, which
    /// is why this takes a string rather than an optional: the field is the undo.
    static func renameMachine(_ name: String) async throws -> MachineIdentity {
        try await background("machine.rename", ["name": name], as: MachineIdentity.self)
    }

    static func peers() async throws -> [Peer] {
        try await background("machine.peers", as: [Peer].self)
    }

    /// Pair with a machine whose key was typed or pasted. Approved outright:
    /// entering a key by hand is the approval.
    static func pair(key: String, label: String, address: String) async throws -> Peer {
        try await background(
            "machine.pair",
            ["key": key, "label": label, "address": address],
            as: Peer.self
        )
    }

    static func approve(key: String) async throws {
        _ = try await background("machine.approve", ["key": key], as: Changed.self)
    }

    static func revoke(key: String) async throws {
        _ = try await background("machine.revoke", ["key": key], as: Changed.self)
    }

    /// Forget a peer entirely, so it arrives as a stranger next time. Different
    /// from revoking, which remembers that it was turned away.
    static func forget(key: String) async throws {
        _ = try await background("machine.forget", ["key": key], as: Forgotten.self)
    }

    static func remoteStatus() async throws -> RemoteStatus {
        try await background("remote.status", as: RemoteStatus.self)
    }

    /// Bind a loopback port on this machine and bridge it to a service on a
    /// peer's own localhost. The browser tab opens the returned URL as if the
    /// service ran here.
    static func proxyListen(peer: String, host: String, port: Int) async throws -> ProxyListen {
        try await background(
            "proxy.listen",
            ["peer": peer, "host": host, "port": port],
            as: ProxyListen.self
        )
    }

    /// Remove a machine from the account directory. The server deletes that
    /// machine's uploaded rows, so this is for a stale machine id (a
    /// reinstall) that is holding a machine-cap slot a live machine needs.
    static func unlinkMachine(id: String) async throws {
        _ = try await background("account.unlinkMachine", ["id": id], as: Removed.self)
    }

    /// Turn remote reach on or off. The one switch: everything between
    /// machines rides the tunnel, so there is nothing else to configure.
    static func setTunnel(_ enabled: Bool) async throws -> TunnelOutcome {
        try await background("remote.serve", ["tunnel": enabled], as: TunnelOutcome.self)
    }

    /// Ask a peer a question, through this machine's daemon.
    ///
    /// The result is the peer's own, unwrapped: a failure over there is a
    /// failure here, so a caller has one error path whether the call was local
    /// or remote.
    static func onPeer<T: Decodable & Sendable>(
        _ peer: String,
        _ method: String,
        _ params: [String: Any] = [:],
        as type: T.Type
    ) async throws -> T {
        try await background(
            "remote.call",
            ["peer": peer, "method": method, "params": params],
            as: type
        )
    }

    /// `onPeer` for a method whose answer may legitimately be nothing.
    ///
    /// The same distinction `invokeOptional` draws locally, kept over the
    /// remote hop: a peer with an empty archive answers `null` to
    /// `activity.calendar`, and that is an answer, not a failure.
    static func onPeerOptional<T: Decodable & Sendable>(
        _ peer: String,
        _ method: String,
        _ params: [String: Any] = [:],
        as type: T.Type
    ) async throws -> T? {
        try await backgroundOptional(
            "remote.call",
            ["peer": peer, "method": method, "params": params],
            as: type
        )
    }
}

private struct Changed: Codable, Sendable { let changed: Bool }
private struct Forgotten: Codable, Sendable { let forgotten: Bool }
