#!/usr/bin/env python3
# SPDX-License-Identifier: LicenseRef-tokenstat-source-available
"""Exercise production chat creation, approval and usage methods with inert peers."""
from pathlib import Path
import subprocess
import tempfile

root = Path(__file__).resolve().parents[2]
source = (root / 'apps/mac/Sources/Features/Workspaces/Chat/ChatModel.swift').read_text()
creation = source[source.index('    private var createSingleflight'):source.index('    private func performCreate')]
usage = source[source.index('    var turnUsage:'):source.index('    var hasStarted:')].replace('@ObservationIgnored ', '')
approval = source[source.index('    func approvalIsPending'):source.index('    /// Workspace ownership does not require')]
cost = (root / 'apps/mac/Sources/Features/Workspaces/Chat/ChatCostMeter.swift').read_text()
cost = cost[cost.index('struct ChatUsageTotals:'):cost.index('struct ChatCostMeter:')]
fixture = r'''
import Foundation
struct ChatConversation: Sendable { var workspace: UInt64 }
struct ChatApproval { var id: String; var decision: String?; var expiresAtMs: Int64 = Int64.max }
struct Event {
    var kind = "usage"; var input: UInt64?; var output: UInt64?
    var cacheRead: UInt64?; var cacheWrite: UInt64?; var costUsd: Double?
}
struct Timeline { var seq: UInt64?; var event: Event? }
COST
@MainActor final class Model {
    var loadGeneration: UInt64 = 0
    var held: [UInt64: CheckedContinuation<Void, Never>] = [:]
    var starts: [UInt64] = []
    var events: [Timeline] = []
    var eventsEpoch: UInt64 = 0, usageThrough: UInt64?
    var conversationUsage: ChatUsageTotals?
    var savedCopy: Bool?, approvalsLoaded = false, approvals: [ChatApproval] = []
CREATION
    func performCreate(expectedGeneration: UInt64) async -> ChatConversation? {
        guard expectedGeneration == loadGeneration else { return nil }
        starts.append(expectedGeneration)
        await withCheckedContinuation { held[expectedGeneration] = $0 }
        guard expectedGeneration == loadGeneration else { return nil }
        return ChatConversation(workspace: expectedGeneration)
    }
USAGE
APPROVAL
}
@main struct Test {
    @MainActor static func main() async {
        let model = Model()
        model.conversationUsage = ChatUsageTotals(input: 1, output: 2, cacheRead: 0, cacheWrite: 0, cost: 0.1)
        guard case let .available(before) = model.turnUsage else { fatalError() }
        model.conversationUsage?.output = 50
        model.conversationUsage?.cost = 0.8
        guard case let .available(after) = model.turnUsage else { fatalError() }
        assert(before.output == 2 && after.output == 50 && after.cost == 0.8,
               "host counter refresh changes meter even with unchanged archive cursor")
        let approval = ChatApproval(id: "question")
        assert(!model.approvalIsPending(approval))
        model.approvalsLoaded = true; model.approvals = [approval]
        assert(model.approvalIsPending(approval))
        model.approvals = []
        assert(!model.approvalIsPending(approval), "resolved live approvals do not wait for old expiry")
        let old = Task { await model.create() }
        while model.held[0] == nil { await Task.yield() }
        model.loadGeneration = 1
        let current = Task { await model.create() }
        for _ in 0..<1000 { if model.held[1] != nil { break }; await Task.yield() }
        assert(model.held[1] != nil && model.starts == [0, 1], "new workspace gets its own creation")
        model.held.removeValue(forKey: 0)?.resume()
        let oldResult = await old.value
        assert(oldResult == nil && model.isCreating, "old completion cannot clear new workspace's spinner")
        model.held.removeValue(forKey: 1)?.resume()
        let result = await current.value
        assert(result?.workspace == 1 && !model.isCreating)
        print("Chat usage refresh, resolved approval and workspace creation races passed")
    }
}
'''.replace('COST', cost).replace('CREATION', creation).replace('USAGE', usage).replace('APPROVAL', approval)
with tempfile.TemporaryDirectory(prefix='tokenstat-chat-review-') as directory:
    path = Path(directory)
    (path / 'Fixture.swift').write_text(fixture)
    subprocess.run(['swiftc', '-parse-as-library', str(path / 'Fixture.swift'),
                    str(root / 'apps/mac/Sources/Features/Workspaces/Chat/Singleflight.swift'),
                    '-o', str(path / 'test')], check=True)
    subprocess.run([str(path / 'test')], check=True)

# Also exercise performCreate itself: singleflight stubs cannot catch a late
# create deleting from the model's newer host, or reusing a landing setup.
start = source.index('    private func performCreate(')
end = source.index('\n    /// Take the backend list again', start)
perform = source[start:end].replace('private func performCreate', 'func performCreate')
create_fixture = r'''
import Foundation
struct ChatConversation { var id = "created" }
struct Choice {
    var backend: String
    var model: String? = nil, effort: String? = nil
    var fastMode = false
    var mode = "execute", autonomy = "standard"
}
struct ChatBackend {
    var id: String
    var installed: Bool? = true
    var models = ["model"], efforts = ["high"], fastModeModels = ["model"]
    var gateTier: String? = nil
}
enum L10n { static func text(_ key: String) -> String { key } }
enum ChatFastMode {
    static func available(model: String?, models: [String], backend: String) -> Bool { true }
}
@MainActor final class WorkSessionContext {
    static let shared = WorkSessionContext()
    var scope: String? = "account"
}
@MainActor enum Bridge {
    static var beforeReply: (() -> Void)?
    static var removed: [String?] = []
    static var choices: [String] = []
    static func chatBackends(peer: String?) async throws -> [ChatBackend] { [] }
    static func createChat(workspaceID: String, backend: String, mode: String, autonomy: String,
        model: String?, effort: String?, personaID: String?, peer: String?) async throws -> ChatConversation {
        choices.append(backend)
        beforeReply?()
        return ChatConversation()
    }
    static func removeChat(id: String, peer: String?) async throws { removed.append(peer) }
}
@MainActor final class Model {
    var newChatChoice: Choice? = Choice(backend: "claude")
    var lastLaunchChoice: Choice? = Choice(backend: "codex")
    var loadGeneration: UInt64 = 0, selectionGeneration: UInt64 = 0
    var workspaceID: String? = "workspace", folderID: String? = "remote:original:workspace"
    var continuityScope: String? = "account", peer: String? = "original"
    var backends = [ChatBackend(id: "claude"), ChatBackend(id: "codex")]
    var chats: [ChatConversation] = []
    var error: String?
    func rememberedPersonaID(_ choice: Choice?) -> String? { nil }
    func storeChatListCache(_ chats: [ChatConversation], folderID: String) {}
    func select(_ chat: ChatConversation, savedPage: Bool?, fresh: Bool) async {}
PERFORM
}
@main struct CreateTests {
    @MainActor static func main() async {
        let model = Model()
        let first = await model.performCreate(expectedGeneration: 0)
        assert(first != nil && model.newChatChoice == nil)
        _ = await model.performCreate(expectedGeneration: 0)
        assert(Bridge.choices == ["claude", "codex"], "landing setup is used once")

        let stale = Model()
        Bridge.beforeReply = {
            stale.loadGeneration += 1
            stale.peer = "different"
            stale.folderID = "remote:different:other-workspace"
        }
        let result = await stale.performCreate(expectedGeneration: 0)
        assert(result == nil && stale.chats.isEmpty)
        assert(Bridge.removed.count == 1 && Bridge.removed[0] == "original",
               "late create cleanup uses its captured computer")

        let switched = Model()
        Bridge.beforeReply = { WorkSessionContext.shared.scope = "another-account" }
        let switchedResult = await switched.performCreate(expectedGeneration: 0)
        assert(switchedResult == nil && Bridge.removed.count == 1,
               "cleanup never borrows another account's authority")
        WorkSessionContext.shared.scope = "account"

        let cancelled = Model()
        Bridge.beforeReply = { withUnsafeCurrentTask { $0?.cancel() } }
        let cancelledResult = await Task { await cancelled.performCreate(expectedGeneration: 0) }.value
        assert(cancelledResult == nil && Bridge.removed.count == 2 && cancelled.chats.isEmpty,
               "cancellation after create cleans up before publishing")
        print("Chat creation: one-use choices, original-host cleanup, cancellation and account changes passed")
    }
}
'''.replace('PERFORM', perform)
with tempfile.TemporaryDirectory(prefix='tokenstat-chat-create-') as directory:
    path = Path(directory)
    (path / 'Fixture.swift').write_text(create_fixture)
    subprocess.run(['swiftc', '-parse-as-library', str(path / 'Fixture.swift'),
                    '-o', str(path / 'test')], check=True)
    subprocess.run([str(path / 'test')], check=True)
