#!/usr/bin/env python3
# SPDX-License-Identifier: LicenseRef-tokenstat-source-available
"""Exercise actual Bridge vault dispatch against account changes and held replies."""
from pathlib import Path
import subprocess
import tempfile

root = Path(__file__).resolve().parents[1]
source = (root / 'apps/mac/Sources/Bridge/Bridge.swift').read_text()


def member(signature):
    start = source.index(signature)
    brace = source.index('{\n', start)
    end, depth = brace + 1, 1
    while depth:
        depth += (source[end] == '{') - (source[end] == '}')
        end += 1
    return source[start:end]


methods = '\n'.join(member(name) for name in [
    '    private static func vaultInvoke<',
    '    @MainActor private static func captureVaultOwner(',
    '    @MainActor private static func prepareVaultBiometrics(',
    '    static func sshVaultStatus(', '    static func createSSHVault(',
    '    static func unlockSSHVault(', '    static func setSSHVaultPassword(',
    '    static func lockSSHVault(', '    static func resetSSHVault(',
    '    static func rotateSSHVaultRecovery(', '    static func sshVaultRecords(',
    '    static func putSSHVaultRecord(', '    static func deleteSSHVaultRecord(',
])
swift = r'''import Foundation
@MainActor final class WorkSessionContext { static let shared = WorkSessionContext(); var scope: WorkReference.Scope?; var generation: UInt64 = 0 }
@MainActor enum SSHOperationOwner { struct Ticket: Sendable { let scope: WorkReference.Scope; let generation: UInt64 } }
struct SSHVaultStatus: Codable, Sendable { let created: Bool }
struct SSHVaultRecovery: Codable, Sendable { let recovery: String }
struct SSHVaultUnlock: Codable, Sendable { let unlocked: Bool }
struct SSHVaultPasswordChange: Codable, Sendable { let changed: Bool }
struct SSHVaultReset: Codable, Sendable { let reset: Bool }
struct SSHVaultPut: Codable, Sendable { let id: String }
struct SSHVaultDelete: Codable, Sendable { let deleted: Bool }
struct SSHVaultRecord: Codable, Sendable { let id: String }
struct SSHVaultRecords: Codable, Sendable { let records: [SSHVaultRecord] }
@MainActor enum SSHVaultBiometrics { static var removals = 0; static func remove() throws { removals += 1 } }
enum Bridge {
    enum Patience { static let standard: TimeInterval = 60 }
    @MainActor static var calls: [String] = [], owners: [[String: String]] = []
    @MainActor static var held: [CheckedContinuation<Void, Error>?] = []
    @MainActor static var suspend = false
    @MainActor private static func background<T: Decodable & Sendable>(_ method: String,
        _ params: [String: Any], patience: TimeInterval, as type: T.Type) async throws -> T {
        calls.append(method)
        owners.append(params["_accountScope"] as? [String: String] ?? [:])
        if suspend { try await withCheckedThrowingContinuation { held.append($0) } }
        return try JSONDecoder().decode(T.self, from: Data(#"{"created":true,"recovery":"mock","unlocked":true,"changed":true,"locked":true,"reset":true,"id":"mock","deleted":true,"records":[]}"#.utf8))
    }
    @MainActor static func finish(_ n: Int, fail: Bool) {
        let c = held[n]; held[n] = nil
        if fail { c?.resume(throwing: CocoaError(.fileReadUnknown)) } else { c?.resume() }
    }
''' + methods + r'''
}
@MainActor func until(_ test: () -> Bool) async {
    for _ in 0..<10000 { if test() { return }; await Task.yield() }; precondition(test())
}
@MainActor func canceled(_ action: () async throws -> Void) async {
    do { try await action(); preconditionFailure("retired work was accepted") }
    catch is CancellationError {} catch { preconditionFailure("wrong stale error: \(error)") }
}
@main struct Check {
    @MainActor static func main() async {
        let a = WorkReference.Scope.account(origin: "https://test.example", handle: "alice")!
        let b = WorkReference.Scope.account(origin: "https://test.example", handle: "bob")!
        WorkSessionContext.shared.scope = a
        _ = try! await Bridge.sshVaultStatus(expectedScope: a)
        _ = try! await Bridge.createSSHVault(password: "mock", tier: "supporter", expectedScope: a)
        _ = try! await Bridge.unlockSSHVault(password: "mock", tier: "supporter", expectedScope: a)
        _ = try! await Bridge.setSSHVaultPassword(newPassword: "mock", expectedScope: a)
        try! await Bridge.lockSSHVault(expectedScope: a)
        try! await Bridge.resetSSHVault(expectedScope: a)
        _ = try! await Bridge.rotateSSHVaultRecovery(password: "mock", expectedScope: a)
        _ = try! await Bridge.sshVaultRecords(recovery: "", tier: "supporter", expectedScope: a)
        _ = try! await Bridge.putSSHVaultRecord(id: "mock", plaintext: "mock", tier: "supporter", expectedScope: a)
        _ = try! await Bridge.deleteSSHVaultRecord(id: "mock", expectedScope: a)
        precondition(Bridge.calls.count == 10)
        precondition(Bridge.owners.allSatisfy { $0 == ["kind": "account", "origin": a.origin, "identity": a.identity] })
        WorkSessionContext.shared.scope = b
        await canceled { try await Bridge.lockSSHVault(expectedScope: a) }
        await canceled { try await Bridge.resetSSHVault(expectedScope: a) }
        await canceled { _ = try await Bridge.setSSHVaultPassword(newPassword: "mock", expectedScope: a) }
        precondition(Bridge.calls.count == 10 && SSHVaultBiometrics.removals == 2, "stale request dispatched or deleted B biometrics")
        for scope in [nil, WorkReference.Scope.local(installationID: "local")] {
            WorkSessionContext.shared.scope = scope
            await canceled { _ = try await Bridge.sshVaultStatus() }
        }
        precondition(Bridge.calls.count == 10)
        Bridge.suspend = true
        for fail in [false, true] {
            WorkSessionContext.shared.scope = a
            let index = Bridge.held.count
            let old = Task { try await Bridge.sshVaultStatus(expectedScope: a) }
            await until { Bridge.held.count == index + 1 }
            WorkSessionContext.shared.scope = b
            Bridge.finish(index, fail: fail)
            await canceled { _ = try await old.value }
            precondition(Bridge.owners.last?["identity"] == a.identity)
        }
        WorkSessionContext.shared.scope = a
        let index = Bridge.held.count
        let canceledRead = Task { try await Bridge.sshVaultStatus(expectedScope: a) }
        await until { Bridge.held.count == index + 1 }
        canceledRead.cancel(); Bridge.finish(index, fail: false)
        await canceled { _ = try await canceledRead.value }
        Bridge.suspend = false
        let before = Bridge.calls.count
        let preCanceled = Task { try await Bridge.sshVaultStatus(expectedScope: a) }
        preCanceled.cancel()
        await canceled { _ = try await preCanceled.value }
        precondition(Bridge.calls.count == before)
        // Hold the actual MainActor dispatch hop while A leaves and returns.
        // Scope equality alone must not delete fresh A biometric credentials.
        WorkSessionContext.shared.scope = a
        let oldGeneration = WorkSessionContext.shared.generation
        let oldReset = Task.detached {
            try await Bridge.resetSSHVault(expectedScope: a, expectedGeneration: oldGeneration)
        }
        WorkSessionContext.shared.scope = b
        WorkSessionContext.shared.generation += 1
        WorkSessionContext.shared.scope = a
        WorkSessionContext.shared.generation += 1
        let removals = SSHVaultBiometrics.removals
        await canceled { try await oldReset.value }
        precondition(SSHVaultBiometrics.removals == removals && Bridge.calls.count == before)
        let oldRead = Task.detached {
            try await Bridge.sshVaultStatus(expectedScope: a, expectedGeneration: oldGeneration)
        }
        await canceled { _ = try await oldRead.value }
        precondition(Bridge.calls.count == before)
        print("Vault: all10 actual typed dispatches preserve account envelope; stale success/error/cancellation and biometric deletion fenced")
    }
}
'''
with tempfile.TemporaryDirectory() as directory:
    work = Path(directory)
    (work / 'Check.swift').write_text(swift)
    subprocess.run(['swiftc', '-parse-as-library', '-swift-version', '5',
                    '-module-cache-path', str(work / 'ModuleCache'), str(work / 'Check.swift'),
                    str(root / 'apps/mac/Sources/Features/Work/WorkReference.swift'),
                    '-o', str(work / 'check')], check=True)
    subprocess.run([str(work / 'check')], check=True)
