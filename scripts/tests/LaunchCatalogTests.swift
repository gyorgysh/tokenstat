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
    static var installerCalls: [(String, String, TimeInterval)] = []
    enum Patience { static let installer: TimeInterval = 21 * 60 }
    static func launcherCatalog() async throws -> [RemoteLaunchProfile] { [] }
    static func launcherHide(id: String) async throws {}
    static func launcherShow(id: String) async throws {}
    static func launcherInstall(id: String, reinstall: Bool = false) async throws -> LauncherInstallResult {
        installerCalls.append(("local", reinstall ? "launcher.reinstall" : "launcher.install", Patience.installer))
        return LauncherInstallResult()
    }
    static func onPeer<T: Decodable>(_ peer: String, _ method: String, _ params: [String: String] = [:], patience: TimeInterval = 30, as: T.Type) async throws -> T {
        switch method {
        case "launcher.catalog": return [RemoteLaunchProfile()] as! T
        case "launcher.install", "launcher.reinstall":
            installerCalls.append((peer, method, patience))
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
        let repair = Task { await catalog.install(profile, peer: firstPeer, reinstall: true) }
        while Bridge.waiters[firstPeer] == nil { await Task.yield() }
        let duplicate = await catalog.install(profile, peer: firstPeer, reinstall: true)
        assert(duplicate != nil, "a duplicate request must not report success before the running installer finishes")
        assert(catalog.isInstalling(profile.id, peer: firstPeer), "the duplicate must not clear the original request's progress")
        assert(Bridge.installerCalls.filter { $0.1 == "launcher.reinstall" }.count == 1)
        Bridge.waiters.removeValue(forKey: firstPeer)?.resume(returning: LauncherInstallResult(ok: false, output: "fixture installer failed", exitCode: 7))
        let failedRepair = await repair.value
        assert(failedRepair == "fixture installer failed" && !catalog.isInstalling(profile.id, peer: firstPeer))
        _ = await catalog.install(profile, peer: nil, reinstall: true)
        assert(Bridge.installerCalls.last?.1 == "launcher.reinstall" && Bridge.installerCalls.last?.0 == "local")
        assert(Bridge.installerCalls.allSatisfy { $0.2 == Bridge.Patience.installer }, "installers need their full timeout on both hosts")
        print("Launcher visibility, host routing, installation/reinstallation and failure recovery passed")
    }
}
