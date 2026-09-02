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
    /// Where this tool's own installer puts it, relative to the home
    /// directory, for CLIs that ship a directory instead of landing in a
    /// shared one. Searched after the PATH, so an override still wins.
    ///
    /// `crates/tokenstat-host/src/launcher.rs` is the authority: the host
    /// answers `launcher.catalog` for local and remote folders alike, and
    /// `resolve()` replaces this whole list with its answer. These entries only
    /// have to keep the first moments of a launch honest, so a tool the user
    /// plainly installed does not flicker in.
    var installDirs: [String] = []
    /// A loopback page this command starts. The session is the server
    /// process. After spawn the pane waits for the port and opens this URL
    /// in the in-app browser. Nil for a TTY session.
    var openUrl: String? = nil
    /// Whether the command is on this machine's PATH (or in its own install
    /// directory). False when the profile is only offered to be installed,
    /// drawn muted with an Install action instead of a launch tile.
    var installed: Bool = true
    /// The tool's official one-shot installer. The host runs it when the
    /// user clicks Install; this app only displays it.
    var installCommand: String? = nil
    /// Taken off the owning machine's launcher. The binary is still there.
    var hidden: Bool = false

    /// Whether pointing this harness at a local model server means anything.
    ///
    /// The host decides what a selection turns into, in
    /// `tokenstat-host::launcher::model_environment`, and refuses a pair it
    /// has no contract for. This list only decides whether to offer the
    /// choice, so a harness missing here costs a menu entry, never a bad
    /// launch. Keep the two in step when a harness gains local support.
    static func acceptsLocalModel(_ profileID: String) -> Bool {
        ["claude_code", "codex", "opencode", "opencode2", "copilot"].contains(profileID)
    }

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
            harnessID: "claude_code", symbol: nil,
            installCommand: "curl -fsSL https://claude.ai/install.sh | bash"
        ),
        LaunchProfile(
            id: "codex", name: "Codex", command: "codex", args: [],
            bypassArgs: ["--dangerously-bypass-approvals-and-sandbox"],
            harnessID: "codex", symbol: nil,
            installCommand: "curl -fsSL https://chatgpt.com/codex/install.sh | sh"
        ),
        LaunchProfile(
            id: "opencode", name: "OpenCode", command: "opencode", args: [],
            bypassArgs: ["--auto"],
            harnessID: "opencode", symbol: nil,
            installDirs: [".opencode/bin"],
            installCommand: "curl -fsSL https://opencode.ai/install | bash"
        ),
        LaunchProfile(
            id: "opencode2", name: "OpenCode 2", command: "opencode2", args: [],
            bypassArgs: ["--auto"],
            harnessID: "opencode", symbol: nil,
            installDirs: [".opencode/bin"],
            installCommand: "curl -fsSL https://raw.githubusercontent.com/anomalyco/opencode/v2/install | bash"
        ),
        LaunchProfile(
            id: "grok", name: "Grok Build", command: "grok", args: [],
            bypassArgs: ["--permission-mode", "bypassPermissions"],
            harnessID: "grok", symbol: nil,
            installDirs: [".grok/bin"],
            installCommand: "curl -fsSL https://x.ai/cli/install.sh | bash"
        ),
        LaunchProfile(
            id: "copilot", name: "Copilot CLI", command: "copilot", args: [],
            bypassArgs: ["--allow-all"],
            harnessID: "copilot", symbol: nil,
            installCommand: "npm install -g @github/copilot"
        ),
        LaunchProfile(
            id: "cline", name: "Cline", command: "cline", args: [],
            bypassArgs: [], harnessID: "cline", symbol: nil,
            installCommand: "npm install -g cline"
        ),
        LaunchProfile(
            id: "openclaw", name: "OpenClaw", command: "openclaw", args: [],
            bypassArgs: [], harnessID: "openclaw", symbol: nil,
            installCommand: "curl -fsSL https://openclaw.ai/install.sh | bash"
        ),
        LaunchProfile(
            id: "muse", name: "Muse", command: "muse", args: [],
            bypassArgs: ["--yolo"], harnessID: "muse", symbol: nil,
            installCommand: "curl -fsSL https://dev.meta.ai/install.sh | bash"
        ),
        LaunchProfile(
            id: "pi", name: "Pi", command: "pi", args: [],
            bypassArgs: [], harnessID: "pi", symbol: nil,
            installCommand: "npm install -g --ignore-scripts @earendil-works/pi-coding-agent"
        ),
        LaunchProfile(
            id: "dsh",
            name: "DeepSeek Harness",
            command: "npx",
            args: ["--yes", "@deepseek-ai/dsh", "web"],
            bypassArgs: [],
            harnessID: "dsh",
            symbol: nil,
            openUrl: "http://127.0.0.1:3080/"
        ),
        LaunchProfile(
            id: "zed", name: "Zed", command: "zed", args: [],
            bypassArgs: [], harnessID: "zed", symbol: nil
        ),
        LaunchProfile(
            id: "antigravity", name: "Antigravity", command: "agy", args: [],
            bypassArgs: ["--dangerously-skip-permissions"],
            harnessID: "antigravity", symbol: nil,
            installCommand: "curl -fsSL https://antigravity.google/cli/install.sh | bash"
        ),
        LaunchProfile(
            id: "cursor_agent", name: "Cursor Agent", command: "agent", args: [],
            bypassArgs: [], harnessID: "cursor", symbol: nil,
            installCommand: "curl https://cursor.com/install -fsS | bash"
        ),
        LaunchProfile(
            id: "cursor", name: "Cursor CLI", command: "cursor", args: [],
            bypassArgs: [], harnessID: "cursor", symbol: nil
        ),
        LaunchProfile(
            id: "hermes", name: "Hermes Agent", command: "hermes", args: [],
            bypassArgs: [], harnessID: "hermes", symbol: nil,
            installCommand: "curl -fsSL https://hermes-agent.nousresearch.com/install.sh | bash -s -- --non-interactive --skip-setup"
        ),
        LaunchProfile(
            id: "kilo", name: "Kilo Code", command: "kilocode", args: [],
            bypassArgs: [], harnessID: "kilo", symbol: nil,
            installCommand: "npm install -g @kilocode/cli"
        ),
        LaunchProfile(
            id: "kimi", name: "Kimi Code", command: "kimi", args: [],
            bypassArgs: ["--yolo"], harnessID: "kimi", symbol: nil,
            installCommand: "curl -fsSL https://code.kimi.com/kimi-code/install.sh | bash"
        ),
    ]

    /// Names this tile answers to. Kilo's npm page and its docs disagree
    /// (`kilocode` vs `kilo`), so both are probed rather than guessed.
    var commandNames: [String] {
        id == "kilo" ? [command, "kilo"] : [command]
    }

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
    /// Every supported profile, installed or not, with the host's verdict.
    ///
    /// What the launch surface draws: installed profiles get a vivid tile,
    /// the rest sit behind the + tile until the user opens them.
    private(set) var catalog: [LaunchProfile]
    /// Profiles on a specific peer (the machine that owns a remote
    /// workspace), fetched from its daemon once per peer. Installed only, for
    /// the strip menu and model control.
    private(set) var remoteAvailable: [LaunchProfile] = []
    /// Every supported profile on a specific peer, installed or not.
    private(set) var remoteCatalog: [LaunchProfile] = []
    /// The profile ids whose installer is currently running, so a tile can
    /// show progress and refuse a second click.
    private(set) var installing: Set<String> = []

    /// Set once the host has answered. The strip calls `resolve()` every time
    /// it appears, and it must run once per launch, not once per workspace
    /// switch. A failure stays unresolved so the next visit retries.
    private var resolving = false
    private var resolved = false
    private var remoteFetched = Set<String>()

    private init() {
        let quick = Self.filter(LaunchProfile.all, onPathIn: Self.launchTimeSearchPath())
        available = quick
        catalog = LaunchProfile.all.map { profile in
            var p = profile
            p.installed = quick.contains { $0.id == profile.id }
            return p
        }
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
            catalog = dtos.map(Self.profile(from:))
            available = catalog.filter { $0.installed }
            resolved = true
            await adoptHostHidden(from: catalog, scope: "local", peer: nil)
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
            remoteCatalog = dtos.map(Self.profile(from:))
            remoteAvailable = remoteCatalog.filter { $0.installed }
            await adoptHostHidden(from: remoteCatalog, scope: peer, peer: peer)
        } catch {
            remoteFetched.remove(peer)
        }
    }

    /// Hide a profile on the machine that owns it, then refresh that catalog.
    ///
    /// Local defaults update first so the tile moves before the socket
    /// returns. An older host that does not know `launcher.hide` keeps the
    /// local set only.
    func hide(_ id: String, peer: String?) async {
        let scope = peer ?? "local"
        LauncherVisibility.shared.hide(id, scope: scope)
        setHidden(id, true, peer: peer)
        do {
            if let peer {
                _ = try await Bridge.onPeer(peer, "launcher.hide", ["id": id], as: HiddenAck.self)
            } else {
                try await Bridge.launcherHide(id: id)
            }
        } catch {
            // Older host: the local set is the whole answer.
        }
        await refreshAfterVisibilityChange(peer: peer)
    }

    /// Put a hidden profile back on the owning machine's launcher.
    func show(_ id: String, peer: String?) async {
        let scope = peer ?? "local"
        LauncherVisibility.shared.show(id, scope: scope)
        setHidden(id, false, peer: peer)
        do {
            if let peer {
                _ = try await Bridge.onPeer(peer, "launcher.show", ["id": id], as: HiddenAck.self)
            } else {
                try await Bridge.launcherShow(id: id)
            }
        } catch {
            // Older host: the local set is the whole answer.
        }
        await refreshAfterVisibilityChange(peer: peer)
    }

    private struct HiddenAck: Codable, Sendable {
        var hidden: Bool?
        var id: String?
    }

    private func setHidden(_ id: String, _ hidden: Bool, peer: String?) {
        if peer == nil {
            catalog = catalog.map { profile in
                var next = profile
                if next.id == id { next.hidden = hidden }
                return next
            }
        } else {
            remoteCatalog = remoteCatalog.map { profile in
                var next = profile
                if next.id == id { next.hidden = hidden }
                return next
            }
        }
    }

    private func refreshAfterVisibilityChange(peer: String?) async {
        if let peer {
            remoteFetched.remove(peer)
            await resolveRemote(peer: peer)
        } else {
            resolved = false
            await resolve()
        }
    }

    /// Host list wins. If the host has never stored a set and this Mac still
    /// has one in defaults, push it once so a phone sees the same hide.
    private func adoptHostHidden(from profiles: [LaunchProfile], scope: String, peer: String?) async {
        let hostHidden = Set(profiles.filter(\.hidden).map(\.id))
        if hostHidden.isEmpty {
            let local = LauncherVisibility.shared.ids(for: scope)
            if !local.isEmpty {
                for id in local.sorted() {
                    do {
                        if let peer {
                            _ = try await Bridge.onPeer(
                                peer,
                                "launcher.hide",
                                ["id": id],
                                as: HiddenAck.self
                            )
                        } else {
                            try await Bridge.launcherHide(id: id)
                        }
                    } catch {
                        return
                    }
                }
                if peer == nil {
                    catalog = catalog.map { profile in
                        var next = profile
                        if local.contains(next.id) { next.hidden = true }
                        return next
                    }
                } else {
                    remoteCatalog = remoteCatalog.map { profile in
                        var next = profile
                        if local.contains(next.id) { next.hidden = true }
                        return next
                    }
                }
                return
            }
        }
        LauncherVisibility.shared.replace(hostHidden, scope: scope)
    }

    /// Run a profile's official installer, then re-resolve so the muted tile
    /// flips to a launch once the tool is on disk.
    ///
    /// Returns a message for the user when the install failed, nil on success.
    /// The install runs on the machine that owns the folder, which is the
    /// peer's daemon for a remote workspace. A host that finished but reported
    /// failure counts as a failure: the installer's own output is the message.
    @discardableResult
    func install(_ profile: LaunchProfile, peer: String?) async -> String? {
        guard !installing.contains(profile.id) else { return nil }
        installing.insert(profile.id)
        defer { installing.remove(profile.id) }
        let result: LauncherInstallResult
        do {
            if let peer {
                result = try await Bridge.onPeer(
                    peer,
                    "launcher.install",
                    ["id": profile.id],
                    as: LauncherInstallResult.self
                )
            } else {
                result = try await Bridge.launcherInstall(id: profile.id)
            }
        } catch {
            return error.localizedDescription
        }
        guard result.ok else {
            let tail = result.output.trimmingCharacters(in: .whitespacesAndNewlines)
            return tail.isEmpty ? "the installer exited with code \(result.exitCode ?? 1)" : tail
        }
        LauncherVisibility.shared.show(profile.id, scope: peer ?? "local")
        if let peer {
            remoteFetched.remove(peer)
            await resolveRemote(peer: peer)
        } else {
            resolved = false
            await resolve()
        }
        return nil
    }

    private nonisolated static func profile(from dto: RemoteLaunchProfile) -> LaunchProfile {
        LaunchProfile(
            id: dto.id,
            name: dto.name,
            command: dto.command,
            args: dto.args,
            bypassArgs: dto.bypassArgs,
            harnessID: dto.harnessId,
            symbol: dto.symbol,
            openUrl: dto.openUrl,
            installed: dto.installed,
            installCommand: dto.installCommand,
            hidden: dto.hidden ?? false
        )
    }

    private nonisolated static func filter(_ profiles: [LaunchProfile], onPathIn path: [String]) -> [LaunchProfile] {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return profiles.filter { profile in
            // The shell is an absolute path; everything else is looked up.
            profile.command.hasPrefix("/")
                || profile.commandNames.contains(where: { isExecutable($0, in: path) })
                // A CLI that ships its own directory is on the PATH only
                // because its installer edited a startup file, and an app
                // launched from Finder never sourced one.
                || profile.commandNames.contains(where: { name in
                    isExecutable(name, in: profile.installDirs.map { "\(home)/\($0)" })
                })
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
