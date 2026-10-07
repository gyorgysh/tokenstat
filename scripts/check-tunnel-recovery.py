#!/usr/bin/env python3
# SPDX-License-Identifier: LicenseRef-tokenstat-source-available
"""Exercise actual Bridge recovery dispatch fences with a suspended status read."""
from pathlib import Path
import subprocess
import tempfile
root = Path(__file__).resolve().parents[1]
source = (root / 'apps/mac/Sources/Bridge/Bridge.swift').read_text()
start = source.index('    private static func recoverTunnel(')
brace = source.index('{\n', start)
end, depth = brace + 1, 1
while depth:
    depth += (source[end] == '{') - (source[end] == '}')
    end += 1
method = source[start:end].replace('private static func', 'static func')
swift = r'''import Foundation
@MainActor final class WorkSessionContext {
    struct Scope: Codable { let identity: String; let origin: String; let kind: String }
    static let shared = WorkSessionContext()
    var scope: Scope? = .init(identity: "A", origin: "service", kind: "account")
}
extension WorkSessionContext.Scope: Equatable {}
struct Nudged {}
struct RemoteStatus { let tunnelOnline: Bool }
enum Bridge {
    static let tunnelRecoveryFlights = TunnelRecoveryFlights()
    @MainActor static var statuses: [CheckedContinuation<RemoteStatus, Error>?] = []
    @MainActor static var nudges: [Bool] = []
    @MainActor static func remoteStatus() async throws -> RemoteStatus {
        try await withCheckedThrowingContinuation { statuses.append($0) }
    }
    @MainActor static func background(_ method: String, _ params: [String: Any], as: Nudged.Type) async throws -> Nudged {
        nudges.append(params["reconnect"] as? Bool ?? false); return Nudged()
    }
    @MainActor static func finish(_ n: Int, online: Bool) {
        let held = statuses[n]; statuses[n] = nil; held?.resume(returning: .init(tunnelOnline: online))
    }
''' + method + r'''
}
@MainActor func until(_ test: () -> Bool) async {
    for _ in 0..<10000 { if test() { return }; await Task.yield() }; precondition(test())
}
@main struct Check {
    @MainActor static func main() async {
        let old = Task { await Bridge.recoverTunnel(urgency: .foreground) }
        await until { Bridge.statuses.count == 1 }
        await Bridge.recoverTunnel(urgency: .reconnect)
        precondition(Bridge.nudges == [true])
        Bridge.finish(0, online: false); await old.value
        precondition(Bridge.nudges == [true], "Late old status tore down successor")
        let shared = (0..<30).map { _ in Task { await Bridge.recoverTunnel(urgency: .foreground) } }
        await until { Bridge.statuses.count == 2 }
        for _ in 0..<100 { await Task.yield() }
        precondition(Bridge.statuses.count == 2, "Equal account scope did not share status")
        Bridge.finish(1, online: true); for task in shared { await task.value }
        precondition(Bridge.nudges == [true, false])
        let accountA = Task { await Bridge.recoverTunnel(urgency: .foreground) }
        await until { Bridge.statuses.count == 3 }
        WorkSessionContext.shared.scope = .init(identity: "B", origin: "service", kind: "account")
        Bridge.finish(2, online: false); await accountA.value
        precondition(Bridge.nudges == [true, false], "A resumed recovery authorized itself for B")
        print("Actual Bridge recovery: stale side effect suppressed, canonical sharing and account fences")
    }
}
'''
with tempfile.TemporaryDirectory() as directory:
    work = Path(directory)
    (work / 'Check.swift').write_text(swift)
    subprocess.run(['swiftc', '-parse-as-library', '-swift-version', '5', '-module-cache-path', str(work / 'ModuleCache'), str(work / 'Check.swift'), str(root / 'apps/mac/Sources/Bridge/TunnelRecoveryFlights.swift'), '-o', str(work / 'check')], check=True)
    subprocess.run([str(work / 'check')], check=True)
