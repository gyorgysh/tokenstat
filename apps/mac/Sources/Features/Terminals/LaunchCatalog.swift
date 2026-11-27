// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
//
// Source-available: source sharing and own builds are permitted.
// Store and commercial distribution of builds is reserved. See LICENSE.
// "tokenstat" is a trademark of pueev OU. See TRADEMARK.md.

#if os(macOS)
import Foundation
import Observation

struct LaunchProfile: Identifiable, Sendable {
    let id: String
    let name: String
    let command: String
    let args: [String]
    let bypassArgs: [String]
    /// Source id for the brand mark, or nil for a plain SF symbol.
    let harnessID: String?
    let symbol: String?
    var installDirs: [String] = []
    var openUrl: String? = nil
    var installed: Bool = true
    var installCommand: String? = nil
    var hidden: Bool = false

    static var shellFallback: LaunchProfile {
        LaunchProfile(
            id: "shell",
            name: L10n.text("apple.launchcatalog.shell.a7332854"),
            command: shellCommand,
            args: shellArguments,
            bypassArgs: [],
            harnessID: nil,
            symbol: "terminal"
        )
    }

    static func acceptsLocalModel(_ profileID: String) -> Bool {
        LocalModelLaunch.accepts(profileID)
    }

    static let all: [LaunchProfile] = [
        LaunchProfile(
            id: "shell",
            name: L10n.text("apple.launchcatalog.shell.a7332854"),
            command: shellCommand,
            args: shellArguments,
            bypassArgs: [],
            harnessID: nil,
            symbol: "terminal"
        ),
        LaunchProfile(
            id: "claude_code", name: L10n.text("apple.launchcatalog.claude_code.246ef8c1"), command: "claude", args: [],
            bypassArgs: ["--dangerously-skip-permissions"],
            harnessID: "claude_code", symbol: nil,
            installCommand: "curl -fsSL https://claude.ai/install.sh | bash"
        ),
        LaunchProfile(
            id: "codex", name: L10n.text("apple.launchcatalog.codex.616efbe9"), command: "codex", args: [],
            bypassArgs: ["--dangerously-bypass-approvals-and-sandbox"],
            harnessID: "codex", symbol: nil,
            installCommand: "curl -fsSL https://chatgpt.com/codex/install.sh | sh"
        ),
        LaunchProfile(
            id: "opencode", name: "OpenCode", command: "opencode", args: [],
            bypassArgs: ["--auto"],
            harnessID: "opencode", symbol: nil,
            installDirs: [".opencode/bin"],
            installCommand: "curl -fsSL https://opencode.ai/v2/install | bash"
        ),
        LaunchProfile(
            id: "opencode2", name: "OpenCode 2", command: "opencode2", args: [],
            bypassArgs: ["--auto"],
            harnessID: "opencode", symbol: nil,
            installDirs: [".opencode/bin"]
        ),
        LaunchProfile(
            id: "grok", name: L10n.text("apple.launchcatalog.grok_build.fd3bf01a"), command: "grok", args: [],
            bypassArgs: ["--permission-mode", "bypassPermissions"],
            harnessID: "grok", symbol: nil,
            installDirs: [".grok/bin"],
            installCommand: "curl -fsSL https://x.ai/cli/install.sh | bash"
        ),
        LaunchProfile(
            id: "copilot", name: L10n.text("apple.launchcatalog.copilot_cli.c73e38d4"), command: "copilot", args: [],
            bypassArgs: ["--allow-all"],
            harnessID: "copilot", symbol: nil,
            installCommand: "npm install -g @github/copilot"
        ),
        LaunchProfile(
            id: "cline", name: L10n.text("apple.launchcatalog.cline.8a91b069"), command: "cline", args: [],
            bypassArgs: [], harnessID: "cline", symbol: nil,
            installCommand: "npm install -g cline"
        ),
        LaunchProfile(
            id: "openclaw", name: "OpenClaw", command: "openclaw", args: [],
            bypassArgs: [], harnessID: "openclaw", symbol: nil,
            installCommand: "curl -fsSL https://openclaw.ai/install.sh | bash"
        ),
        LaunchProfile(
            id: "muse", name: L10n.text("apple.launchcatalog.muse.5fa6e850"), command: "muse", args: [],
            bypassArgs: ["--yolo"], harnessID: "muse", symbol: nil,
            installCommand: "curl -fsSL https://dev.meta.ai/install.sh | bash"
        ),
        LaunchProfile(
            id: "omp", name: "Oh My Pi", command: "omp", args: [],
            bypassArgs: ["--auto-approve"], harnessID: "omp", symbol: nil,
            installDirs: [".bun/bin", ".local/bin"],
            installCommand: "curl -fsSL https://omp.sh/install | sh"
        ),
        LaunchProfile(
            id: "pi", name: "Pi", command: "pi", args: [],
            bypassArgs: [], harnessID: "pi", symbol: nil,
            installCommand: "npm install -g --ignore-scripts @earendil-works/pi-coding-agent"
        ),
        LaunchProfile(
            id: "dsh",
            name: L10n.text("apple.launchcatalog.deepseek_harness.e562a9c5"),
            command: "npx",
            args: ["--yes", "@deepseek-ai/dsh", "web"],
            bypassArgs: [],
            harnessID: "dsh",
            symbol: nil,
            openUrl: "http://127.0.0.1:3080/"
        ),
        LaunchProfile(
            id: "zed", name: L10n.text("apple.launchcatalog.zed.a90e4dc6"), command: "zed", args: [],
            bypassArgs: [], harnessID: "zed", symbol: nil
        ),
        LaunchProfile(
            id: "antigravity", name: L10n.text("apple.launchcatalog.antigravity.4da276f5"), command: "agy", args: [],
            bypassArgs: ["--dangerously-skip-permissions"],
            harnessID: "antigravity", symbol: nil,
            installCommand: "curl -fsSL https://antigravity.google/cli/install.sh | bash"
        ),
        LaunchProfile(
            id: "cursor_agent", name: L10n.text("apple.launchcatalog.cursor_agent.f2b703ad"), command: "agent", args: [],
            bypassArgs: [], harnessID: "cursor", symbol: nil,
            installCommand: "curl https://cursor.com/install -fsS | bash"
        ),
        LaunchProfile(
            id: "cursor", name: L10n.text("apple.launchcatalog.cursor_cli.4faa6009"), command: "cursor", args: [],
            bypassArgs: [], harnessID: "cursor", symbol: nil
        ),
        LaunchProfile(
            id: "hermes", name: L10n.text("apple.launchcatalog.hermes_agent.873e989a"), command: "hermes", args: [],
            bypassArgs: [], harnessID: "hermes", symbol: nil,
            installCommand: "curl -fsSL https://hermes-agent.nousresearch.com/install.sh | bash -s -- --non-interactive --skip-setup"
        ),
        LaunchProfile(
            id: "kilo", name: L10n.text("apple.launchcatalog.kilo_code.83abecfd"), command: "kilocode", args: [],
            bypassArgs: [], harnessID: "kilo", symbol: nil,
            installCommand: "npm install -g @kilocode/cli"
        ),
        LaunchProfile(
            id: "kimi", name: L10n.text("apple.launchcatalog.kimi_code.0c486180"), command: "kimi", args: [],
            bypassArgs: ["--yolo"], harnessID: "kimi", symbol: nil,
            installCommand: "curl -fsSL https://code.kimi.com/kimi-code/install.sh | bash"
        ),
        LaunchProfile(
            id: "qwen", name: L10n.text("apple.launchcatalog.qwen_code.47487dbd"), command: "qwen", args: [],
            bypassArgs: ["--approval-mode", "yolo"], harnessID: "qwen", symbol: nil,
            installCommand: "curl -fsSL https://qwen-code-assets.oss-cn-hangzhou.aliyuncs.com/installation/install-qwen-standalone.sh | bash"
        ),
        LaunchProfile(
            id: "devin", name: L10n.text("apple.launchcatalog.devin_cli.29247d05"), command: "devin", args: [],
            bypassArgs: ["--permission-mode", "dangerous"], harnessID: "devin", symbol: nil,
            installCommand: "curl -fsSL https://cli.devin.ai/install.sh | bash"
        ),
    ]

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
    private(set) var catalog: [LaunchProfile]
    private(set) var remoteAvailableByPeer: [String: [LaunchProfile]] = [:]
    private(set) var remoteCatalogByPeer: [String: [LaunchProfile]] = [:]
    func remoteAvailable(for peer: String) -> [LaunchProfile] {
        remoteAvailableByPeer[peer] ?? []
    }
    func remoteCatalog(for peer: String) -> [LaunchProfile] {
        remoteCatalogByPeer[peer] ?? []
    }
    private struct InstallKey: Hashable { let peer: String?; let profile: String }
    private var installing: Set<InstallKey> = []
    func isInstalling(_ id: String, peer: String?) -> Bool {
        installing.contains(InstallKey(peer: peer, profile: id))
    }

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
        }
        resolving = false
    }

    private var remoteInFlight: [String: Task<[RemoteLaunchProfile]?, Never>] = [:]
    func resolveRemote(peer: String) async {
        if let running = remoteInFlight[peer] {
            _ = await running.value
            return
        }
        guard !remoteFetched.contains(peer) else { return }
        let task = Task<[RemoteLaunchProfile]?, Never> {
            try? await Bridge.onPeer(peer, "launcher.catalog", as: [RemoteLaunchProfile].self)
        }
        remoteInFlight[peer] = task
        let dtos = await task.value
        remoteInFlight[peer] = nil
        guard let dtos else {
            remoteFetched.remove(peer)
            return
        }
        remoteFetched.insert(peer)
        let profiles = dtos.map(Self.profile(from:))
        remoteCatalogByPeer[peer] = profiles
        remoteAvailableByPeer[peer] = profiles.filter { $0.installed }
        await adoptHostHidden(from: profiles, scope: peer, peer: peer)
    }

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
        }
        await refreshAfterVisibilityChange(peer: peer)
    }

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
        }
        await refreshAfterVisibilityChange(peer: peer)
    }

    private struct HiddenAck: Codable, Sendable {
        var hidden: Bool?
        var id: String?
    }

    private func setHidden(_ id: String, _ hidden: Bool, peer: String?) {
        if let peer {
            remoteCatalogByPeer[peer] = (remoteCatalogByPeer[peer] ?? []).map { profile in
                var next = profile
                if next.id == id { next.hidden = hidden }
                return next
            }
        } else {
            catalog = catalog.map { profile in
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

    private func adoptHostHidden(from profiles: [LaunchProfile], scope: String, peer: String?) async {
        let hostHidden = Set(profiles.filter(\.hidden).map(\.id))
        let migrationKey = "launcher.hidden.migrated." + scope
        if hostHidden.isEmpty, !UserDefaults.standard.bool(forKey: migrationKey) {
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
                if let peer {
                    remoteCatalogByPeer[peer] = (remoteCatalogByPeer[peer] ?? []).map { profile in
                        var next = profile
                        if local.contains(next.id) { next.hidden = true }
                        return next
                    }
                } else {
                    catalog = catalog.map { profile in
                        var next = profile
                        if local.contains(next.id) { next.hidden = true }
                        return next
                    }
                }
                UserDefaults.standard.set(true, forKey: migrationKey)
                return
            }
        }
        UserDefaults.standard.set(true, forKey: migrationKey)
        LauncherVisibility.shared.replace(hostHidden, scope: scope)
    }

    @discardableResult
    func install(_ profile: LaunchProfile, peer: String?, reinstall: Bool = false) async -> String? {
        let key = InstallKey(peer: peer, profile: profile.id)
        guard installing.insert(key).inserted else {
            return L10n.text("apple.launchcatalog.installer_already_running")
        }
        defer { installing.remove(key) }
        let result: LauncherInstallResult
        do {
            if let peer {
                result = try await Bridge.onPeer(
                    peer,
                    reinstall ? "launcher.reinstall" : "launcher.install",
                    ["id": profile.id],
                    patience: Bridge.Patience.installer,
                    as: LauncherInstallResult.self
                )
            } else {
                result = try await Bridge.launcherInstall(id: profile.id, reinstall: reinstall)
            }
        } catch {
            return error.localizedDescription
        }
        guard result.ok else {
            let tail = result.output.trimmingCharacters(in: .whitespacesAndNewlines)
            return tail.isEmpty ? L10n.text("apple.launchcatalog.the_installer_exited_with_code_0.80d5114c", "\(result.exitCode ?? 1)") : tail
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
            profile.command.hasPrefix("/")
                || profile.commandNames.contains(where: { isExecutable($0, in: path) })
                || profile.commandNames.contains(where: { name in
                    isExecutable(name, in: profile.installDirs.map { "\(home)/\($0)" })
                })
        }
    }

    private nonisolated static func isExecutable(_ name: String, in path: [String]) -> Bool {
        path.contains { FileManager.default.isExecutableFile(atPath: "\($0)/\(name)") }
    }

    private nonisolated static func launchTimeSearchPath() -> [String] {
        var paths = ProcessInfo.processInfo.environment["PATH"]?
            .split(separator: ":")
            .map(String.init) ?? []
        paths.append(contentsOf: conventionalDirectories())
        return deduplicated(paths)
    }

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
