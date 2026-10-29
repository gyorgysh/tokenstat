#!/usr/bin/env python3
# SPDX-License-Identifier: LicenseRef-tokenstat-source-available
"""Exercise the production bridge's page-capability fallback and routing."""
from pathlib import Path
import subprocess
import tempfile

root = Path(__file__).resolve().parents[2]
source = (root / 'apps/mac/Sources/Bridge/Bridge.swift').read_text()
start = source.index('    static func pullListPage(')
end = source.index('    /// Public author pictures', start)
method = source[start:end]
harness = r'''
import Foundation
struct PullSummary { var number: Int }
struct PullListPage { var rows: [PullSummary]; var nextCursor: String? }
enum PullScope: String { case all }
enum PullStateFilter: String { case open }
enum BridgeError: Error { case core(code: String, message: String) }
enum L10n { static func text(_ key: String) -> String { key } }
struct RemoteTarget { var peer: String }
@MainActor enum RemoteHostFeature {
    case pullListPages
    static var supported = false
    static var checkedPeer: String?
    func isSupported(peer: String?) async -> Bool { Self.checkedPeer = peer; return Self.supported }
}
@MainActor enum Bridge {
    static var oldCalls = 0
    static var method = ""
    static var values: [String: Any] = [:]
    static func remoteWorkspace(_ workspace: String) -> RemoteTarget? {
        workspace == "remote" ? RemoteTarget(peer: "remote-peer") : nil
    }
    static func pullList(workspaceID: String, peer: String?, scope: PullScope, state: PullStateFilter, refresh: Bool) async throws -> [PullSummary] {
        oldCalls += 1; return [.init(number: 1)]
    }
    static func pullRead<T>(workspaceID: String, peer: String?, method: String, values: [String: Any], as type: T.Type) async throws -> T {
        Self.method = method; Self.values = values
        return PullListPage(rows: [.init(number: 2)], nextCursor: "next") as! T
    }
'''
checks = r'''
}
@main struct Check {
    @MainActor static func main() async throws {
        let old = try await Bridge.pullListPage(workspaceID: "remote", peer: nil, scope: .all, state: .open)
        precondition(!old.supportsPagination && old.page.rows[0].number == 1 && RemoteHostFeature.checkedPeer == "remote-peer")
        do {
            _ = try await Bridge.pullListPage(workspaceID: "remote", peer: nil, scope: .all, state: .open, cursor: "next")
            fatalError("An old host must not be asked for a second page")
        } catch BridgeError.core(let code, _) { precondition(code == "host_incompatible") }
        precondition(Bridge.oldCalls == 1)
        RemoteHostFeature.supported = true
        let modern = try await Bridge.pullListPage(workspaceID: "remote", peer: "explicit-peer", scope: .all, state: .open, cursor: "next", refresh: true)
        precondition(modern.supportsPagination && modern.page.rows[0].number == 2)
        precondition(RemoteHostFeature.checkedPeer == "explicit-peer" && Bridge.method == "pulls.listPage")
        precondition(Bridge.values["cursor"] as? String == "next" && Bridge.values["refresh"] as? Bool == true)
        print("Pull pages: old-host fallback, cursor rejection and peer routing passed")
    }
}
'''
with tempfile.TemporaryDirectory() as directory:
    path = Path(directory)
    (path / 'Check.swift').write_text(harness + method + checks)
    subprocess.run(['swiftc', '-parse-as-library', str(path / 'Check.swift'), '-o', str(path / 'check')], check=True)
    subprocess.run([str(path / 'check')], check=True)
