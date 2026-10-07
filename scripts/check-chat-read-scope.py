#!/usr/bin/env python3
"""Exercise production Bridge chat dispatch across same-account login retirement."""
from pathlib import Path
import subprocess
import tempfile

root = Path(__file__).resolve().parents[1]
source = (root / 'apps/mac/Sources/Bridge/Bridge.swift').read_text()
start = source.index('    private struct ChatReadOwner:')
end = source.index('    private static func chatTransport', start)
methods = source[start:end].replace('private static func chatInvoke', 'static func chatInvoke')
swift = r'''import Foundation
enum WorkReference { struct Scope: Codable, Equatable, Sendable {
    enum Kind: String, Codable { case account }; var kind = Kind.account
    var origin = "https://test.example"; let identity: String
} }
@MainActor final class WorkSessionContext {
    static let shared = WorkSessionContext()
    var scope: WorkReference.Scope? = .init(identity: "alice")
    var generation: UInt64 = 1
    var accountSession: String? = "first"
}
actor Wire {
    var replies: [CheckedContinuation<String, Error>?] = []
    func call() async throws -> String {
        try await withCheckedThrowingContinuation { replies.append($0) }
    }
    func count() -> Int { replies.count }
    func fail(_ index: Int) { replies[index]?.resume(throwing: NSError(domain: "old login", code: 1)); replies[index] = nil }
    func finish(_ index: Int, _ text: String) { replies[index]?.resume(returning: text); replies[index] = nil }
}
enum Bridge {
    static let chatReadFlights = ChatReadFlights()
    static let wire = Wire()
''' + methods + r'''
    static func chatTransport<T: Decodable & Sendable>(peer: String?, _ method: String,
        _ params: [String: Any], patience: TimeInterval, as type: T.Type) async throws -> T {
        let text = try await wire.call()
        return try JSONDecoder().decode(T.self, from: Data(text.utf8))
    }
    enum Patience { static let standard: TimeInterval = 60 }
}
func until(_ count: Int) async {
    for _ in 0..<20000 { if await Bridge.wire.count() >= count { return }; await Task.yield() }
    preconditionFailure("Wire request never arrived")
}
@main struct Check {
    @MainActor static func main() async throws {
        let first = Task { try await Bridge.chatInvoke(peer: "mac", "chat.list", as: String.self) }
        await until(1)
        // Same account identity, different verified login lifetime.
        WorkSessionContext.shared.generation = 2
        WorkSessionContext.shared.accountSession = "second"
        let second = Task { try await Bridge.chatInvoke(peer: "mac", "chat.list", as: String.self) }
        await until(2)
        await Bridge.wire.finish(0, "\"old\"")
        do { _ = try await first.value; preconditionFailure("Retired login published its reply") }
        catch is CancellationError {}
        await Bridge.wire.finish(1, "\"new\"")
        let value = try await second.value; precondition(value == "new")
        let mutation = Task { try await Bridge.chatInvoke(peer: "mac", "chat.update", as: String.self) }
        await until(3)
        WorkSessionContext.shared.generation = 3
        await Bridge.wire.finish(2, "\"old mutation\"")
        do { _ = try await mutation.value; preconditionFailure("Retired mutation reply published") }
        catch is CancellationError {}
        do {
            let _: String = try await Bridge.chatInvoke(peer: "mac", "chat.list", expectedGeneration: 2, as: String.self)
            preconditionFailure("Obsolete dispatch accepted")
        } catch is CancellationError {}
        let failed = Task { try await Bridge.chatInvoke(peer: "mac", "chat.update", as: String.self) }
        await until(4)
        WorkSessionContext.shared.generation = 4
        await Bridge.wire.fail(3)
        do { _ = try await failed.value; preconditionFailure("Retired mutation error published") }
        catch is CancellationError {}
        precondition(await Bridge.wire.count() == 4)
        print("Bridge chat reads: same-account login isolation, retired mutation replies and obsolete dispatch passed")
    }
}
'''.replace('        precondition(await Bridge.wire.count() == 4)',
            '        let calls = await Bridge.wire.count(); precondition(calls == 4)')
with tempfile.TemporaryDirectory(prefix='tokenstat-chat-scope-') as directory:
    path = Path(directory) / 'checks.swift'
    path.write_text(swift)
    binary = Path(directory) / 'checks'
    subprocess.run(['swiftc', '-parse-as-library', '-swift-version', '5', '-o', str(binary),
                    str(path), str(root / 'apps/mac/Sources/Bridge/ChatReadFlights.swift')], check=True)
    subprocess.run([str(binary)], check=True)
