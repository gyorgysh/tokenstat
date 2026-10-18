#!/usr/bin/env python3
# SPDX-License-Identifier: LicenseRef-tokenstat-source-available
"""Exercise production terminal meter refreshes with held host replies."""
from pathlib import Path
import subprocess
import tempfile

root = Path(__file__).resolve().parents[2]
source = (root / "apps/mac/Sources/Features/Terminals/TerminalSession.swift").read_text()

def method(signature):
    start = source.index(signature)
    brace = source.index("{", start)
    end, depth = brace + 1, 1
    while depth:
        depth += (source[end] == "{") - (source[end] == "}")
        end += 1
    return source[start:end].replace("private func", "func")

meter = source[source.index("struct SessionMeter:"):source.index("/// Terminal preferences")]
methods = method("    private func applyMeter(") + "\n" + method("    func refreshDetails(")
fixture = r'''import Foundation
enum L10n { static func text(_ key: String) -> String { key } }
struct WorkReference: Equatable { var id: String }
struct SessionIdentities: Equatable, Sendable { var id: String }
@MainActor final class WorkSessionContext {
    static let shared = WorkSessionContext()
    var generation: UInt64 = 1
}
enum WorkCacheAccess { static func canRead(_ reference: WorkReference) -> Bool { true } }
struct PtySessionInfo: Sendable {
    var alive = true, exitCode: Int? = nil, lastActivityAtMs: Int64? = nil
    var activity: String? = nil, cpuPercent: Double? = nil, memoryMb: Double? = nil
    var attention: String? = nil, programStatus: String? = nil
    var sessionIdentities: SessionIdentities? = nil, tokens: UInt64? = nil
    var costMicros: Int64? = nil, costEstimated: Bool? = nil, costComplete: Bool? = nil
    var billing: String? = nil, model: String? = nil
    var contextUsed: UInt64? = nil, contextWindow: UInt64? = nil, contextEstimated: Bool? = nil
}
@MainActor enum Bridge {
    static var held: CheckedContinuation<PtySessionInfo, Error>?
    static func ptyInfo(id: String) async throws -> PtySessionInfo {
        try await withCheckedThrowingContinuation { held = $0 }
    }
    static func finish(_ info: PtySessionInfo) { held?.resume(returning: info); held = nil }
}
METER
@MainActor final class Session {
    var removed = false, isPending = false, workReference: WorkReference? = .init(id: "one")
    var hostID = "pty-test", alive = true, exitCode: Int?
    var sessionIdentities: SessionIdentities?, meter: SessionMeter?
    var applied = 0
    func applyState(alive: Bool, exitCode: Int?, lastActivityAtMs: Int64?, activity: String?,
                    cpuPercent: Double?, memoryMb: Double?, attention: String?, programStatus: String?) { applied += 1 }
METHODS
}
@MainActor func untilHeld() async {
    for _ in 0..<20000 { if Bridge.held != nil { return }; await Task.yield() }
    preconditionFailure("Expected a held info request")
}
@main struct Check {
    @MainActor static func main() async {
        let session = Session()
        var info = PtySessionInfo()
        info.contextUsed = 0; info.contextWindow = 200_000
        session.applyMeter(from: info)
        precondition(session.meter?.contextUsed == 0 && session.meter?.contextWindow == 200_000,
                     "An explicit zero context is a valid report even without lifetime usage")
        info.contextUsed = 142_000; info.tokens = 2_000_000; info.model = "model"
        session.applyMeter(from: info)
        precondition(session.meter?.contextUsed == 142_000)
        info.contextUsed = 150_000
        session.applyMeter(from: info)
        precondition(session.meter?.contextUsed == 150_000, "Context refresh cannot depend on lifetime token changes")
        info.contextUsed = nil
        session.applyMeter(from: info)
        precondition(session.meter?.contextUsed == nil, "An absent context is unknown, not 0%")
        info.alive = false; info.exitCode = 0; info.tokens = 2_100_000
        info.sessionIdentities = .init(id: "native-session")
        let final = Task { await session.refreshDetails() }
        await untilHeld(); Bridge.finish(info); await final.value
        precondition(!session.alive && session.exitCode == 0 && session.meter?.tokens == 2_100_000)
        precondition(session.sessionIdentities == info.sessionIdentities && session.applied == 1,
                     "An open detail card refreshes final counters and native IDs after exit")
        for change in 0..<3 {
            let stale = Task { await session.refreshDetails() }
            await untilHeld()
            if change == 0 { WorkSessionContext.shared.generation += 1 }
            if change == 1 { session.workReference = .init(id: "another") }
            if change == 2 { session.removed = true }
            var changed = info; changed.tokens = 9_999_999
            Bridge.finish(changed); await stale.value
            precondition(session.meter?.tokens == 2_100_000 && session.applied == 1,
                         "A late details response cannot publish after account, terminal or removal changes")
        }
        print("Terminal details: live context, explicit zero/unknown, final usage/native IDs and stale owner guards passed")
    }
}
'''.replace("METER", meter).replace("METHODS", methods)
with tempfile.TemporaryDirectory(prefix="tokenstat-terminal-details-") as directory:
    work = Path(directory)
    (work / "Check.swift").write_text(fixture)
    subprocess.run(["swiftc", "-parse-as-library", str(work / "Check.swift"), "-o", str(work / "check")], check=True)
    subprocess.run([str(work / "check")], check=True, timeout=30)
