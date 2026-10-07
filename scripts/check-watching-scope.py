#!/usr/bin/env python3
# SPDX-License-Identifier: LicenseRef-tokenstat-source-available
"""Check actual Bridge heartbeat dispatch with a captured reader account."""
from pathlib import Path
import subprocess
import tempfile
root = Path(__file__).resolve().parents[1]
source = (root / 'apps/mac/Sources/Bridge/Bridge.swift').read_text()
def method(signature):
    start = source.index(signature)
    brace = source.index('{\n', start)
    end, depth = brace + 1, 1
    while depth:
        depth += (source[end] == '{') - (source[end] == '}')
        end += 1
    return source[start:end]
methods = '\n'.join(method(s) for s in ['    private static func chatInvoke<', '    static func watching(', '    static func stoppedWatching('])
heartbeat = (root / 'apps/mac/Sources/App/WatchingHeartbeat.swift').read_text()
assert 'scope: WorkSessionContext.shared.scope' in heartbeat
assert 'let owner = WorkSessionContext.shared.scope' in heartbeat
assert heartbeat.count('expectedScope: owner') == 2
assert 'WorkSessionContext.shared.scope == owner' in heartbeat
swift = r'''import Foundation
@MainActor final class WorkSessionContext { static let shared = WorkSessionContext(); var scope: WorkReference.Scope?; var generation: UInt64 = 0; var accountSession: String? = "mock-receipt" }
enum Bridge {
    enum Patience { static let standard: TimeInterval = 60 }
    private static let chatReadFlights = ChatReadFlights()
    @MainActor static var calls: [String] = [], watcherIDs: [String] = [], receipts: [String] = []
    @MainActor private static func chatTransport<T: Decodable & Sendable>(peer: String?, _ method: String,
        _ params: [String: Any], patience: TimeInterval, as type: T.Type) async throws -> T {
        calls.append(method); watcherIDs.append(params["watcherId"] as? String ?? "")
        receipts.append(params["_accountSession"] as? String ?? "")
        precondition(params["_accountScope"] != nil)
        return try JSONDecoder().decode(T.self, from: Data("{\"ok\":true}".utf8))
    }
''' + methods + r'''
}
@main struct Check {
    @MainActor static func main() async {
        let a = WorkReference.Scope.local(installationID: "A"), b = WorkReference.Scope.local(installationID: "B")
        WorkSessionContext.shared.scope = a
        await Bridge.watching(conversationID: "chat", watcherID: "lease-A", peer: "host", expectedScope: a)
        precondition(Bridge.calls == ["app.watching"])
        WorkSessionContext.shared.scope = b
        await Bridge.stoppedWatching(conversationID: "chat", watcherID: "lease-A", peer: "host", expectedScope: a)
        await Bridge.watching(conversationID: "chat", watcherID: "lease-A", peer: "host", expectedScope: a)
        precondition(Bridge.calls.count == 1, "Old reader heartbeat dispatched for the new account")
        await Bridge.watching(conversationID: "chat", watcherID: "lease-B", peer: "host", expectedScope: b)
        WorkSessionContext.shared.scope = nil
        await Bridge.stoppedWatching(conversationID: "chat", watcherID: "lease-B", peer: "host", expectedScope: b)
        precondition(Bridge.calls.count == 2, "Unknown account dispatched old release")
        WorkSessionContext.shared.scope = b
        await Bridge.stoppedWatching(conversationID: "chat", watcherID: "lease-B", peer: "host", expectedScope: b)
        precondition(Bridge.calls == ["app.watching", "app.watching", "app.stoppedWatching"])
        precondition(Bridge.watcherIDs == ["lease-A", "lease-B", "lease-B"])
        precondition(Bridge.receipts == ["mock-receipt", "mock-receipt", "mock-receipt"])
        WorkSessionContext.shared.generation = 2
        await Bridge.watching(conversationID: "chat", watcherID: "old-A", peer: "host", expectedScope: b, expectedGeneration: 1)
        precondition(Bridge.calls.count == 3, "A-B-A reused a departed login generation")
        print("Heartbeat: actual Bridge dispatch rejects retired account/unknown scope and preserves exact watcher lease")
    }
}
'''
with tempfile.TemporaryDirectory() as directory:
    work = Path(directory)
    (work / 'Check.swift').write_text(swift)
    subprocess.run(['swiftc', '-parse-as-library', '-swift-version', '5', '-module-cache-path', str(work / 'ModuleCache'), str(work / 'Check.swift'), str(root / 'apps/mac/Sources/Bridge/ChatReadFlights.swift'), str(root / 'apps/mac/Sources/Features/Work/WorkReference.swift'), '-o', str(work / 'check')], check=True)
    subprocess.run([str(work / 'check')], check=True)
