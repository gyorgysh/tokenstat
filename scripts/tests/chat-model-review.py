#!/usr/bin/env python3
# SPDX-License-Identifier: LicenseRef-tokenstat-source-available
"""Exercise production chat creation, approval and usage methods with inert peers."""
from pathlib import Path
import subprocess
import tempfile

root = Path(__file__).resolve().parents[2]

# Decode the production approval DTO rather than a permissive fixture. Shared
# history deliberately omits the physical conversation and shell grant.
models = (root / 'apps/mac/Sources/Bridge/Models.swift').read_text()
start = models.index('struct ChatApproval:')
end = models.index('/// An agent CLI', start)
approval_model = models[start:end]
approval_fixture = r'''import Foundation
MODEL
@main struct ApprovalProjectionTest {
    static func decode(_ value: [String: Any]) throws -> ChatApproval {
        try JSONDecoder().decode(ChatApproval.self, from: JSONSerialization.data(withJSONObject: value))
    }
    static func main() throws {
        var row: [String: Any] = ["id":"approval_fixture", "verb":"Read", "preview":"Example file", "createdAtMs":1, "expiresAtMs":2]
        do { _ = try decode(row); preconditionFailure("a live approval requires its conversation") } catch {}
        row["readOnly"] = true
        let historical = try decode(row)
        precondition(historical.readOnly && historical.conversationID.isEmpty)
        row["conversationId"] = "PRIVATE_CONVERSATION"
        let untrusted = try decode(row)
        precondition(untrusted.conversationID.isEmpty)
        let encoded = try JSONEncoder().encode(untrusted)
        precondition(!String(data: encoded, encoding: .utf8)!.contains("PRIVATE_CONVERSATION"))
        row["readOnly"] = false
        let live = try decode(row)
        precondition(!live.readOnly && live.conversationID == "PRIVATE_CONVERSATION")
        row.removeValue(forKey: "readOnly")
        let legacy = try decode(row)
        precondition(legacy.readOnly == false)
        print("Shared approvals remain read-only without private conversation bindings")
    }
}
'''.replace('MODEL', approval_model)
with tempfile.TemporaryDirectory(prefix='tokenstat-team-approval-') as directory:
    path = Path(directory)
    (path / 'Approval.swift').write_text(approval_fixture)
    subprocess.run(['swiftc', '-parse-as-library', str(path / 'Approval.swift'), '-o', str(path / 'test')], check=True)
    subprocess.run([str(path / 'test')], check=True)

source = (root / 'apps/mac/Sources/Features/Workspaces/Chat/ChatModel.swift').read_text()

# Exercise the real conversation decoder and sign-in/queue policies. A shared
# source must preserve private writing before any queue or sign-in side effect.
conversation = models[models.index('struct ChatSharingMarker:'):models.index('/// Answer from `chat.steerDeliver`.')]
shared_policy = source[source.index('    var isSharedSource:'):source.index('    private(set) var events:')]
sign_in = source[source.index('    func holdForSignIn('):source.index('    /// Explicit Continue reuses')]
queue_policy = source[source.index('    var queuePaused:'):source.index('    private var ownsQueue:')]
shared_fixture = r'''import Foundation
struct WorkReference { var itemID: String?; var workspaceID: String }
struct BranchPull: Codable, Hashable, Sendable {}
struct ChatRoutingState: Codable, Hashable, Sendable {}
CONVERSATION
struct ChatCommandRules { static func canSteer(_ text: String, attachments: Bool, acceptsAttachments: Bool) -> Bool { false } }
enum L10n { static func text(_ key: String) -> String { key } }
struct Pending { enum Delivery { case waiting }; var id = "private-pending"; var signInBackend: String?; var delivery: Delivery = .waiting }
final class SharedSourcePolicy {
    var selected: ChatConversation?
    var busy = false, nativeSteerAcceptsAttachments = false
    var attachments: [String] = [], signInQueuedMessage: String?, backendRefreshError: String?
    var draft = "Private unsent note", queued = 0
    var queueHead: Pending? = Pending(), authorizedQueueItems: Set<String> = ["private-pending"]
    enum SignInHold { case notNeeded, held, refused }
    func needsSignIn(_ backend: String) -> Bool { true }
    func enqueue(_ text: String, awaitingSignIn: Bool) -> String? { queued += 1; return text }
    func clearDraft() { draft = "" }
POLICY
SIGNIN
QUEUE
}
@main struct SharedSourceTest {
    static func main() throws {
        var row: [String:Any] = ["id":"chat-fixture", "workspaceId":"workspace-fixture", "title":"Fixture", "backend":"codex"]
        func decode() throws -> ChatConversation { try JSONDecoder().decode(ChatConversation.self, from: JSONSerialization.data(withJSONObject: row)) }
        let model = SharedSourcePolicy()
        model.selected = try decode()
        precondition(!model.isSharedSource && !model.queuePaused)
        row["teamShare"] = ["id":"share-fixture", "initialFingerprint":"PRIVATE_HOST_FINGERPRINT", "historyBytes":10]
        model.selected = try decode()
        precondition(model.isSharedSource && model.queuePaused)
        guard case .refused = model.holdForSignIn(model.draft, backend: "codex") else { fatalError("shared source queued private writing") }
        precondition(model.draft == "Private unsent note" && model.queued == 0)
        let cached = String(data: try JSONEncoder().encode(model.selected), encoding: .utf8)!
        precondition(cached.contains("share-fixture") && !cached.contains("PRIVATE_HOST_FINGERPRINT"))
        model.selected = try JSONDecoder().decode(ChatConversation.self, from: Data(cached.utf8))
        precondition(model.isSharedSource && model.queuePaused)
        row["teamShare"] = NSNull(); model.selected = try decode()
        guard case .held = model.holdForSignIn(model.draft, backend: "codex") else { fatalError("private control did not queue") }
        precondition(model.queued == 1 && model.draft.isEmpty)
        print("Shared source decoding, private draft retention and queue pause passed")
    }
}
'''.replace('CONVERSATION', conversation).replace('POLICY', shared_policy).replace('SIGNIN', sign_in).replace('QUEUE', queue_policy)
with tempfile.TemporaryDirectory(prefix='tokenstat-shared-source-') as directory:
    path = Path(directory)
    (path / 'SharedSource.swift').write_text(shared_fixture)
    subprocess.run(['swiftc', '-parse-as-library', str(path / 'SharedSource.swift'), '-o', str(path / 'test')], check=True)
    subprocess.run([str(path / 'test')], check=True)
creation = source[source.index('    private var createSingleflight'):source.index('    private func performCreate')]
usage = source[source.index('    var turnUsage:'):source.index('    var hasStarted:')].replace('@ObservationIgnored ', '')
approval = source[source.index('    func approvalIsPending'):source.index('    /// Workspace ownership does not require')]
cost = (root / 'apps/mac/Sources/Features/Workspaces/Chat/ChatCostMeter.swift').read_text()
cost = cost[cost.index('struct ChatUsageTotals:'):cost.index('struct ChatCostMeter:')]
fixture = r'''
import Foundation
struct ChatConversation: Sendable { var workspace: UInt64 }
struct ChatApproval { var id: String; var decision: String?; var readOnly = false; var expiresAtMs: Int64 = Int64.max }
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
    var isSharedSource = false
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
        var historical = approval; historical.readOnly = true
        assert(!model.approvalIsPending(historical), "shared history cannot revive live approval controls")
        model.isSharedSource = true
        assert(!model.approvalIsPending(approval), "personal shared sources cannot resolve live approvals")
        model.isSharedSource = false
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
