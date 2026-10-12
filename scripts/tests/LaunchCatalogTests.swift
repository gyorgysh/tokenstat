// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
// Compile with LaunchCatalog.swift LauncherVisibility.swift.
import Foundation
struct AgentBackend { var id: String }
struct RemoteLaunchProfile: Codable {
    var id = "codex"; var name = "Codex"; var command = "codex"; var args: [String] = []
    var bypassArgs: [String] = []; var harnessId: String?; var symbol: String?; var openUrl: String?
    var installed = true; var installCommand: String?; var hidden: Bool? = false
}
struct LauncherInstallResult: Codable { var ok = true; var output = ""; var exitCode: Int? = 0 }
@MainActor enum Bridge {
    static var waiters: [String: CheckedContinuation<LauncherInstallResult, Never>] = [:]
    static var hideCalls = 0
    static func launcherCatalog() async throws -> [RemoteLaunchProfile] { [] }
    static func launcherHide(id: String) async throws {}
    static func launcherShow(id: String) async throws {}
    static func launcherInstall(id: String) async throws -> LauncherInstallResult { LauncherInstallResult() }
    static func onPeer<T: Decodable>(_ peer: String, _ method: String, _ params: [String: String] = [:], as: T.Type) async throws -> T {
        switch method {
        case "launcher.catalog": return [RemoteLaunchProfile()] as! T
        case "launcher.install":
            return await withCheckedContinuation { waiters[peer] = $0 } as! T
        case "launcher.hide":
            hideCalls += 1
            return try JSONDecoder().decode(T.self, from: Data("{}".utf8))
        default:
            return try JSONDecoder().decode(T.self, from: Data("{}".utf8))
        }
    }
}
@main struct LaunchCatalogTests {
    @MainActor static func main() async throws {
        let firstPeer = "review-" + UUID().uuidString
        let secondPeer = "review-" + UUID().uuidString
        defer {
            for peer in [firstPeer, secondPeer] {
                UserDefaults.standard.removeObject(forKey: "launcher.hidden." + peer)
                UserDefaults.standard.removeObject(forKey: "launcher.hidden.migrated." + peer)
            }
        }
        let catalog = LaunchCatalog.shared
        LauncherVisibility.shared.hide("codex", scope: firstPeer)
        await catalog.resolveRemote(peer: firstPeer)
        assert(Bridge.hideCalls == 1, "legacy local hides migrate once")
        // Showing another tile refreshes the host catalog, whose empty hide
        // set must now win over stale preferences from the first fetch.
        await catalog.show("shell", peer: firstPeer)
        assert(Bridge.hideCalls == 1 && !LauncherVisibility.shared.isHidden("codex", scope: firstPeer))
        let profile = LaunchProfile.all.first { $0.id == "codex" }!
        let first = Task { await catalog.install(profile, peer: firstPeer) }
        while Bridge.waiters[firstPeer] == nil { await Task.yield() }
        let second = Task { await catalog.install(profile, peer: secondPeer) }
        for _ in 0..<200 {
            if Bridge.waiters[secondPeer] != nil { break }
            try await Task.sleep(for: .milliseconds(5))
        }
        assert(catalog.isInstalling("codex", peer: firstPeer) && catalog.isInstalling("codex", peer: secondPeer))
        assert(Bridge.waiters[secondPeer] != nil, "the same agent installs independently on two hosts")
        Bridge.waiters.removeValue(forKey: firstPeer)?.resume(returning: LauncherInstallResult())
        Bridge.waiters.removeValue(forKey: secondPeer)?.resume(returning: LauncherInstallResult())
        _ = await first.value; _ = await second.value
        print("Launcher host visibility and independent installation passed")
    }
}
