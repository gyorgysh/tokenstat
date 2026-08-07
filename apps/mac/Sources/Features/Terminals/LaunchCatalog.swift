// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
//
// Source-available for review, NOT open source. See LICENSE: no rights to
// redistribute, publish, or ship a build are granted. Read it, study it, run
// your own build of it.
// "tokenstat" is a trademark of pueev OU. See TRADEMARK.md.

#if os(macOS)
import Foundation
import Observation

/// What can be launched in a workspace.
///
/// These are the supported harness commands, keyed by the source id so the
/// launch mark and the archive's mark are the same mark. Only commands actually
/// on the PATH are offered.
struct LaunchProfile: Identifiable, Sendable {
    let id: String
    let name: String
    let command: String
    let args: [String]
    /// The CLI's own "do not ask" flags, appended only when the workspace has
    /// bypass permissions switched on. Empty when the CLI has no such flag
    /// (verified against `--help` per command).
    let bypassArgs: [String]
    /// Source id for the brand mark, or nil for a plain SF symbol.
    let harnessID: String?
    let symbol: String?

    static let all: [LaunchProfile] = [
        LaunchProfile(
            id: "shell",
            name: "Shell",
            command: shellCommand,
            args: shellArguments,
            bypassArgs: [],
            harnessID: nil,
            symbol: "terminal"
        ),
        LaunchProfile(
            id: "claude_code", name: "Claude Code", command: "claude", args: [],
            bypassArgs: ["--dangerously-skip-permissions"],
            harnessID: "claude_code", symbol: nil
        ),
        LaunchProfile(
            id: "codex", name: "Codex", command: "codex", args: [],
            bypassArgs: ["--dangerously-bypass-approvals-and-sandbox"],
            harnessID: "codex", symbol: nil
        ),
        LaunchProfile(
            id: "opencode", name: "OpenCode", command: "opencode", args: [],
            bypassArgs: ["--auto"],
            harnessID: "opencode", symbol: nil
        ),
        LaunchProfile(
            id: "grok", name: "Grok Build", command: "grok", args: [],
            bypassArgs: ["--permission-mode", "bypassPermissions"],
            harnessID: "grok", symbol: nil
        ),
        LaunchProfile(
            id: "copilot", name: "Copilot CLI", command: "copilot", args: [],
            bypassArgs: ["--allow-all"],
            harnessID: "copilot", symbol: nil
        ),
        LaunchProfile(
            id: "cline", name: "Cline", command: "cline", args: [],
            bypassArgs: [], harnessID: "cline", symbol: nil
        ),
        LaunchProfile(
            id: "openclaw", name: "OpenClaw", command: "openclaw", args: [],
            bypassArgs: [], harnessID: "openclaw", symbol: nil
        ),
        LaunchProfile(
            id: "muse", name: "Muse", command: "muse", args: [],
            bypassArgs: [], harnessID: "muse", symbol: nil
        ),
        LaunchProfile(
            id: "pi", name: "Pi", command: "pi", args: [],
            bypassArgs: [], harnessID: "pi", symbol: nil
        ),
        LaunchProfile(
            id: "zed", name: "Zed", command: "zed", args: [],
            bypassArgs: [], harnessID: "zed", symbol: nil
        ),
        LaunchProfile(
            id: "antigravity", name: "Antigravity", command: "agy", args: [],
            bypassArgs: ["--dangerously-skip-permissions"],
            harnessID: "antigravity", symbol: nil
        ),
        LaunchProfile(
            id: "cursor_agent", name: "Cursor Agent", command: "agent", args: [],
            bypassArgs: [], harnessID: "cursor", symbol: nil
        ),
        LaunchProfile(
            id: "cursor", name: "Cursor CLI", command: "cursor", args: [],
            bypassArgs: [], harnessID: "cursor", symbol: nil
        ),
    ]

    static var shellCommand: String {
        ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
    }

    static var shellArguments: [String] {
        URL(fileURLWithPath: shellCommand).lastPathComponent == "zsh" ? ["-il"] : []
    }
}

/// Which harnesses this Mac can actually launch.
///
/// The list is a view model rather than a constant, and that is the whole
/// point. The accurate answer — what the user's login shell actually puts on
/// the PATH — used to mean running a second login shell in this process, on
/// top of the one the host runs, and that work cannot happen while a view is
/// drawing. It used to: `LaunchProfile.available` was a `static let` filtered
/// through a login shell, the session strip read it from its `body`, and the
/// first read ran the shell on the main thread, re-entered layout, and
/// libdispatch trapped the process for locking recursively.
///
/// So the app starts with a cheap answer (PATH the process was launched with,
/// plus the conventional install directories, no subprocess) and asks the host
/// for the real catalog once — the same `launcher.catalog` a remote folder
/// asks its owner, answered by the machine the session would actually run on.
/// One source of truth, and one login shell per process instead of two.
@MainActor
@Observable
final class LaunchCatalog {
    static let shared = LaunchCatalog()

    /// The profiles whose command is installed, as best we currently know.
    ///
    /// Starts from the PATH the app was launched with, which costs a handful of
    /// `stat` calls and no subprocess. Finder and launchd give an app a much
    /// smaller PATH than a Terminal session, so this under-reports until
    /// `resolve()` has run, and under-reporting for a moment is the right
    /// trade against blocking the first frame.
    private(set) var available: [LaunchProfile]
    /// Profiles on a specific peer (the machine that owns a remote
    /// workspace), fetched from its daemon once per peer.
    private(set) var remoteAvailable: [LaunchProfile] = []

    /// Set once the host has answered. The strip calls `resolve()` every time
    /// it appears, and it must run once per launch, not once per workspace
    /// switch. A failure stays unresolved so the next visit retries.
    private var resolving = false
    private var resolved = false
    private var remoteFetched = Set<String>()

    private init() {
        available = Self.filter(LaunchProfile.all, onPathIn: Self.launchTimeSearchPath())
    }

    /// Ask the machine that will run the sessions what it can launch.
    ///
    /// The host resolves its login environment once per process and filters
    /// the same catalog a remote folder gets, so the tile list and the spawn
    /// agree even about CLIs that only a profile puts on the PATH.
    func resolve() async {
        guard !resolved, !resolving else { return }
        resolving = true
        do {
            let dtos = try await Bridge.launcherCatalog()
            available = dtos.map(Self.profile(from:))
            resolved = true
        } catch {
            // The launch-time list stays; the next appearance retries.
        }
        resolving = false
    }

    /// Ask the machine that owns a remote workspace what it can launch. One
    /// fetch per peer; a failure forgets the peer so the next visit retries.
    func resolveRemote(peer: String) async {
        guard !remoteFetched.contains(peer) else { return }
        remoteFetched.insert(peer)
        do {
            let dtos = try await Bridge.onPeer(
                peer,
                "launcher.catalog",
                as: [RemoteLaunchProfile].self
            )
            remoteAvailable = dtos.map(Self.profile(from:))
        } catch {
            remoteFetched.remove(peer)
        }
    }

    private nonisolated static func profile(from dto: RemoteLaunchProfile) -> LaunchProfile {
        LaunchProfile(
            id: dto.id,
            name: dto.name,
            command: dto.command,
            args: dto.args,
            bypassArgs: dto.bypassArgs,
            harnessID: dto.harnessId,
            symbol: dto.symbol
        )
    }

    private nonisolated static func filter(_ profiles: [LaunchProfile], onPathIn path: [String]) -> [LaunchProfile] {
        profiles.filter {
            // The shell is an absolute path; everything else is looked up.
            $0.command.hasPrefix("/") || isExecutable($0.command, in: path)
        }
    }

    private nonisolated static func isExecutable(_ name: String, in path: [String]) -> Bool {
        path.contains { FileManager.default.isExecutableFile(atPath: "\($0)/\(name)") }
    }

    /// The PATH this process was given, plus the places CLIs are usually
    /// installed. No subprocess, so this is safe to compute during init.
    private nonisolated static func launchTimeSearchPath() -> [String] {
        var paths = ProcessInfo.processInfo.environment["PATH"]?
            .split(separator: ":")
            .map(String.init) ?? []
        paths.append(contentsOf: conventionalDirectories())
        return deduplicated(paths)
    }

    /// Where CLIs land when they are installed through npm, Homebrew or a
    /// version manager, whether or not a profile has been sourced.
    private nonisolated static func conventionalDirectories() -> [String] {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return [
            "\(home)/.local/bin",
            "\(home)/.npm-global/bin",
            "\(home)/.volta/bin",
            "/opt/homebrew/bin",
            "/usr/local/bin",
            "/usr/bin",
            "/bin",
        ]
    }

    private nonisolated static func deduplicated(_ paths: [String]) -> [String] {
        var seen = Set<String>()
        return paths.filter { !$0.isEmpty && seen.insert($0).inserted }
    }
}
#endif
