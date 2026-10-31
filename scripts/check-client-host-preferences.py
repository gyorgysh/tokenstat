#!/usr/bin/env python3
# SPDX-License-Identifier: LicenseRef-tokenstat-source-available
"""Run the Apple client's actual host preference methods under two accounts."""
from pathlib import Path
import subprocess
import tempfile

root = Path(__file__).resolve().parents[1]
source = (root / 'apps/mac/Sources/Client/ClientWorkspacesView.swift').read_text()
source = source[source.index('final class ClientWorkspacesModel'):]

def member(signature):
    start = source.index(signature)
    brace = source.index('{', start)
    end, depth = brace + 1, 1
    while depth:
        depth += (source[end] == '{') - (source[end] == '}')
        end += 1
    return source[start:end].replace('private var', 'var').replace('private func', 'func')

members = '\n'.join(member(signature) for signature in (
    '    private var hostPreferencePrefix:',
    '    private var lastConnectedHostKey:',
    '    private var rememberedHostsKey:',
    '    var lastConnectedHost:',
    '    private func rememberHost(_ peerKey:',
    '    private func autoConnectKey(for peerKey:',
    '    private func migrateLegacyHost()',
    '    func isAutoConnectEnabled(for peerKey:',
    '    func setAutoConnect(_ on:',
))
swift = r'''import Foundation
struct ClientHost { let peerKey: String }
@MainActor final class Model {
    let ownerScope: WorkReference.Scope?
    var hosts: [ClientHost] = []
    var backgroundTickets: [String: UUID] = [:]
    init(_ scope: WorkReference.Scope?) { ownerScope = scope }
''' + members + r'''
}
@main struct Check {
    @MainActor static func main() {
        let id = UUID().uuidString
        let peer = "host-" + id
        let origin = "https://example.invalid"
        let first = Model(.account(origin: origin, handle: "first-" + id)!)
        let second = Model(.account(origin: origin, handle: "second-" + id)!)
        let legacyHost = "client.lastConnectedHost"
        let legacyAuto = "client.autoConnectHost." + peer
        let defaults = UserDefaults.standard
        defer {
            defaults.removeObject(forKey: legacyHost)
            defaults.removeObject(forKey: legacyAuto)
            if let key = first.lastConnectedHostKey { defaults.removeObject(forKey: key) }
            if let key = first.rememberedHostsKey { defaults.removeObject(forKey: key) }
            if let key = first.autoConnectKey(for: peer) { defaults.removeObject(forKey: key) }
            if let key = second.lastConnectedHostKey { defaults.removeObject(forKey: key) }
            if let key = second.rememberedHostsKey { defaults.removeObject(forKey: key) }
            if let key = second.autoConnectKey(for: peer) { defaults.removeObject(forKey: key) }
        }
        defaults.set(peer, forKey: legacyHost)
        defaults.set(false, forKey: legacyAuto)
        first.hosts = [.init(peerKey: peer)]
        first.migrateLegacyHost()
        precondition(first.lastConnectedHost == peer)
        precondition(!first.isAutoConnectEnabled(for: peer))
        precondition(defaults.object(forKey: legacyHost) == nil)
        second.hosts = [.init(peerKey: peer)]
        second.migrateLegacyHost()
        precondition(second.lastConnectedHost == nil, "Another account inherited the host")
        precondition(second.isAutoConnectEnabled(for: peer), "Another account inherited Disconnect")
        second.setAutoConnect(false, for: peer)
        first.setAutoConnect(true, for: peer)
        precondition(first.isAutoConnectEnabled(for: peer))
        precondition(!second.isAutoConnectEnabled(for: peer))
        let unknown = Model(nil)
        precondition(unknown.lastConnectedHost == nil && !unknown.isAutoConnectEnabled(for: peer))
        print("Apple client host preferences: one-time migration, account isolation, unknown account")
    }
}
'''
with tempfile.TemporaryDirectory(prefix='tokenstat-client-host-prefs-') as temporary:
    path = Path(temporary)
    (path / 'main.swift').write_text(swift)
    subprocess.run(['swiftc', '-parse-as-library', '-swift-version', '5',
                    str(root / 'apps/mac/Sources/Features/Work/WorkReference.swift'),
                    str(path / 'main.swift'), '-o', str(path / 'check')], check=True)
    subprocess.run([str(path / 'check')], check=True)
