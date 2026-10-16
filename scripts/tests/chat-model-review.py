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

start = source.index('    func warmWorkspacePreviews(')
end = source.index('\n    private func', start)
# The next production member may have documentation; retain only the function.
brace = source.index('{', start)
depth, end = 1, brace + 1
while depth:
    depth += (source[end] == '{') - (source[end] == '}')
    end += 1
warm = source[start:end]
root_source = (root / 'apps/mac/Sources/App/RootView.swift').read_text()
start = root_source.index('    private struct SidebarChatReadIdentity:')
end = root_source.index('\n    }', start) + len('\n    }')
identity = root_source[start:end].replace('private struct', 'struct')
sidebar_fixture = r'''
import Foundation
struct ChatConversation: Equatable { let id: String; var backend = "codex"; var running = false }
typealias ChatDisplayItem = String
@MainActor final class WorkSessionContext {
    static let shared = WorkSessionContext()
    var scope: String? = "account", localHostIdentity: String? = "host"
    func resolveLocalHostIdentity() async {}
}
@MainActor enum Bridge {
    struct Route { let workspaceID: String; let peer: String? }
    struct Page { var events: [String] = [] }
    static var replies: [CheckedContinuation<[ChatConversation], Error>?] = []
    static func chatRoute(workspaceID: String, peer: String?) -> Route { Route(workspaceID: workspaceID, peer: peer) }
    static func chats(workspaceID: String, peer: String?) async throws -> [ChatConversation] {
        try await withCheckedThrowingContinuation { replies.append($0) }
    }
    static func chatEventPage(id: String, cursor: String?, limit: Int, peer: String?, includeUsage: Bool) async throws -> Page { Page() }
}
enum ChatPaging { static let previewPageEvents = 10 }
enum WorkReferenceKey {
    static func folder(scope: String, hostIdentity: String, workspaceID: String) -> String { workspaceID }
    static func encode(_ id: String) -> String { id }
}
enum DiagnosticsLog { static func note(_ text: String) {} }
enum ChatHistoryWindow {
    static func previews(in list: [ChatConversation], limit: Int, excluding: (ChatConversation) -> Bool) -> [ChatConversation] { [] }
}
struct ChatRecentMessages<T> { static var perFolderLimit: Int { 10 } }
struct Cache {
    func contains(_ key: String) -> Bool { false }
    func store(_ rows: [String], for key: String, speculative: Bool, cost: (String) -> Int) {}
    func peek(_ key: String) -> [String] { [] }
}
struct Projector { func project(_ rows: [String], backend: String, running: Bool) async throws -> [String] { [] } }
@MainActor final class Model {
    var continuityScope: String?
    var previewCacheEpoch: UInt64 = 0
    var folderID: String?, selected: ChatConversation?
    var chatListCache: [String: [ChatConversation]] = [:]
    var sidebarListErrors: [String: (String, String)] = [:]
    var previewReads: Set<String> = []
    var recentMessages = Cache(), previewProjector = Projector()
    static let chatListCacheCap = 30
    func beginChatListRead(workspaceID: String, peer: String?, scope: String?) -> Int? { 1 }
    func applyChatList(_ rows: [ChatConversation], read: Int?, current: [ChatConversation]) -> [ChatConversation] { rows }
    func sidebarChats(in folder: String) -> [ChatConversation] { chatListCache[folder] ?? [] }
    func storeChatListCache(_ list: [ChatConversation], folderID: String) { chatListCache[folderID] = list; sidebarListErrors[folderID] = nil }
    static func uniqued(_ list: [ChatConversation]) -> [ChatConversation] { list }
    func isUnused(_ row: ChatConversation, in folder: String) -> Bool { false }
    static func warmMarkdown(_ rows: [String]) {}
WARM
}
IDENTITY
@MainActor func until(_ count: Int) async {
    for _ in 0..<10000 { if Bridge.replies.count == count { return }; await Task.yield() }
    preconditionFailure("Sidebar directory read did not start")
}
@main struct SidebarTests {
    @MainActor static func main() async {
        let model = Model()
        let read = Task { await model.warmWorkspacePreviews("other-repo", includeMessages: false) }
        await until(1)
        // Opening the first conversation adopts the scope and retires only
        // transcript previews while other sidebar folders are still loading.
        model.continuityScope = "account"; model.previewCacheEpoch += 1
        Bridge.replies[0]?.resume(returning: [ChatConversation(id: "existing")]); Bridge.replies[0] = nil
        await read.value
        assert(model.chatListCache["other-repo"]?.first?.id == "existing",
               "preview invalidation must not leave another repository loading")
        let failed = Task { await model.warmWorkspacePreviews("failed-repo", includeMessages: false) }
        await until(2); model.previewCacheEpoch += 1
        Bridge.replies[1]?.resume(throwing: CocoaError(.fileReadUnknown)); Bridge.replies[1] = nil
        await failed.value
        assert(model.sidebarListErrors["failed-repo"] != nil, "failed directory reads settle to Retry")
        let oldAccount = Task { await model.warmWorkspacePreviews("private-repo", includeMessages: false) }
        await until(3); WorkSessionContext.shared.scope = "other-account"
        Bridge.replies[2]?.resume(returning: [ChatConversation(id: "private")]); Bridge.replies[2] = nil
        await oldAccount.value
        assert(model.chatListCache["private-repo"] == nil, "retired account replies cannot populate the sidebar")
        let original = SidebarChatReadIdentity(folderID: "repo", model: ObjectIdentifier(model), session: 1)
        let replacement = Model()
        assert(original != SidebarChatReadIdentity(folderID: "repo", model: ObjectIdentifier(replacement), session: 1),
               "starting a chat with a new model restarts expanded repository reads")
        assert(original != SidebarChatReadIdentity(folderID: "repo", model: ObjectIdentifier(model), session: 2),
               "account verification and session changes restart directory reads")
        print("Sidebar chats: preview invalidation, failed reads, account fences and new-chat model replacement passed")
    }
}
'''.replace('WARM', warm).replace('IDENTITY', identity)
with tempfile.TemporaryDirectory(prefix='tokenstat-sidebar-chats-') as directory:
    path = Path(directory)
    (path / 'Fixture.swift').write_text(sidebar_fixture)
    subprocess.run(['swiftc', '-parse-as-library', str(path / 'Fixture.swift'),
                    '-o', str(path / 'test')], check=True)
    subprocess.run([str(path / 'test')], check=True)
