#!/usr/bin/env python3
# SPDX-License-Identifier: LicenseRef-tokenstat-source-available
"""Run the Mac's actual host preference methods under two account scopes."""
from pathlib import Path
import subprocess
import tempfile

root = Path(__file__).resolve().parents[1]
source = (root / 'apps/mac/Sources/Features/Workspaces/WorkspacesModel.swift').read_text()

def method(signature):
    start = source.index(signature)
    brace = source.index('{', start)
    end, depth = brace + 1, 1
    while depth:
        depth += (source[end] == '{') - (source[end] == '}')
        end += 1
    return source[start:end].replace('private static func', 'static func')

methods = '\n'.join(method(signature) for signature in (
    '    static func autoConnectKey(for peerKey:',
    '    static func isAutoConnectEnabled(for peerKey:',
    '    static func setAutoConnect(_ on:',
    '    private static func migrateLegacyAutoConnect(peers:',
    '    func disconnect(peer key:',
))
swift = r'''import Foundation
struct Peer { let key: String }
@MainActor final class WorkSessionContext {
    static let shared = WorkSessionContext()
    var scope: WorkReference.Scope?
}
@MainActor final class HostPrefs {
    var suppressedPeers: Set<String> = []
    var remoteFolders: [String: [Int]] = [:]
    var remotePeerNextDial: [String: Date] = [:]
    var remotePeerFailures: [String: Int] = [:]
    func publishFolders() {}
''' + methods + r'''
}
@main struct Check {
    @MainActor static func main() {
        let id = UUID().uuidString
        let peer = "host-" + id
        let origin = "https://example.invalid"
        let first = WorkReference.Scope.account(origin: origin, handle: "first-" + id)!
        let second = WorkReference.Scope.account(origin: origin, handle: "second-" + id)!
        let legacy = "workspace.autoconnect." + peer
        let defaults = UserDefaults.standard
        defer {
            defaults.removeObject(forKey: legacy)
            WorkSessionContext.shared.scope = first
            if let key = HostPrefs.autoConnectKey(for: peer) { defaults.removeObject(forKey: key) }
            WorkSessionContext.shared.scope = second
            if let key = HostPrefs.autoConnectKey(for: peer) { defaults.removeObject(forKey: key) }
        }
        defaults.set(false, forKey: legacy)
        WorkSessionContext.shared.scope = first
        HostPrefs.migrateLegacyAutoConnect(peers: [Peer(key: peer)])
        precondition(!HostPrefs.isAutoConnectEnabled(for: peer))
        precondition(defaults.object(forKey: legacy) == nil)
        WorkSessionContext.shared.scope = second
        precondition(HostPrefs.isAutoConnectEnabled(for: peer), "Second account inherited Disconnect")
        HostPrefs().disconnect(peer: peer)
        precondition(!HostPrefs.isAutoConnectEnabled(for: peer), "Disconnect was not persisted")
        let restarted = HostPrefs()
        precondition(restarted.suppressedPeers.isEmpty)
        precondition(!HostPrefs.isAutoConnectEnabled(for: peer), "A new model redialled after restart")
        WorkSessionContext.shared.scope = first
        HostPrefs.setAutoConnect(true, for: peer)
        precondition(HostPrefs.isAutoConnectEnabled(for: peer))
        WorkSessionContext.shared.scope = second
        precondition(!HostPrefs.isAutoConnectEnabled(for: peer))
        WorkSessionContext.shared.scope = nil
        precondition(!HostPrefs.isAutoConnectEnabled(for: peer))
        print("Mac host preferences: one-time migration, account isolation, unknown account")
    }
}
'''
with tempfile.TemporaryDirectory(prefix='tokenstat-mac-host-prefs-') as temporary:
    path = Path(temporary)
    (path / 'main.swift').write_text(swift)
    subprocess.run(['swiftc', '-parse-as-library', '-swift-version', '5',
                    str(root / 'apps/mac/Sources/Features/Work/WorkReference.swift'),
                    str(path / 'main.swift'), '-o', str(path / 'check')], check=True)
    subprocess.run([str(path / 'check')], check=True)
