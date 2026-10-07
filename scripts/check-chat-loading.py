#!/usr/bin/env python3
"""Run the actual ChatModel opening/catalog methods against held replies."""
from pathlib import Path
import subprocess
import tempfile

root = Path(__file__).resolve().parents[1]
source = (root / 'apps/mac/Sources/Features/Workspaces/Chat/ChatModel.swift').read_text()
def method(signature):
    start = source.index(signature)
    brace = source.index('{\n', start)
    end, depth = brace + 1, 1
    while depth:
        depth += (source[end] == '{') - (source[end] == '}')
        end += 1
    return source[start:end]

methods = '\n'.join(method(s) for s in ['    func load(workspaceID:',
    '    private func loadSetup(', '    private func loadBackendCatalog(',
    '    private func loadPersonaCatalog(', '    private static func uniqued('])
swift = r'''import Foundation
struct Logger { init(subsystem: String, category: String) {}; func error(_ text: String) {} }
enum WorkReference { struct Scope: Equatable, Sendable { let identity: String } }
@MainActor final class WorkSessionContext {
    static let shared = WorkSessionContext()
    var scope: WorkReference.Scope? = .init(identity: "alice")
    var localHostIdentity: String? = "local"
    func resolveLocalHostIdentity() async {}
}
struct ChatConversation: Equatable, Sendable { let id: String }
struct ChatBackend: Sendable { let id: String }
struct Voices: Sendable { let personas: [String]; let defaultId: String }
@MainActor final class Held<T> {
    var replies: [CheckedContinuation<T, Error>?] = []
    func read() async throws -> T { try await withCheckedThrowingContinuation { replies.append($0) } }
    func finish(_ index: Int, _ value: T) { replies[index]?.resume(returning: value); replies[index] = nil }
    func fail(_ index: Int) { replies[index]?.resume(throwing: NSError(domain: "offline", code: 1)); replies[index] = nil }
}
@MainActor enum Bridge {
    static let backend = Held<[ChatBackend]>(), voices = Held<Voices>(), list = Held<[ChatConversation]>()
    static func chatRoute(workspaceID: String, peer: String?) -> (workspaceID: String, peer: String?) { (workspaceID, peer) }
    static func chats(workspaceID: String, peer: String?) async throws -> [ChatConversation] { try await list.read() }
    static func chatBackends(peer: String?) async throws -> [ChatBackend] { try await backend.read() }
    static func chatPersonas(workspaceID: String, peer: String?) async throws -> Voices { try await voices.read() }
}
struct Mark { let itemID: String? }
struct WorkContinuityStore { static let shared = Self(); func lastConversation(scope: WorkReference.Scope, hostIdentity: String, workspaceID: String) -> Mark? { nil } }
enum WorkReferenceKey {
    static func folder(scope: WorkReference.Scope, hostIdentity: String, workspaceID: String) -> String { workspaceID }
    static func encode(_ value: String) -> String { value }
}
enum L10n { static func text(_ key: String) -> String { key } }
struct Bag { mutating func removeAll() {}; func retain(_ keys: Set<String>, in prefix: String) {} }
@MainActor final class Model {
    var loadGeneration: UInt64 = 0, previewCacheEpoch: UInt64 = 0
    var setupLoadTask: Task<Void, Never>?
    var isLoading = false, openingConversation = false, pagingUnavailable = false
    var workspaceID: String?, peer: String?, folderID: String?, continuityScope: WorkReference.Scope?
    var chatListCache: [String: [ChatConversation]] = [:]
    var chats: [ChatConversation] = [], selected: ChatConversation?
    var backends: [ChatBackend] = [], backendRefreshError: String?, personas: [String] = [], defaultPersonaID: String?
    var pendingRevealID: String?, pendingRevealFolderID: String?, error: String?
    var steerOverlay = Bag(), listMutations = Bag(), recentMessages = Bag()
    var events: [String] = [], outgoing: [String] = [], approvals: [String] = []
    var outgoingWatermark: [String: Int] = [:], responseAttachmentData: [String: Data] = [:]
    var attemptedResponseAttachments = Set<String>(), loadingResponseAttachments = Set<String>()
    var responseAttachmentErrors: [String: String] = [:], instructions: String?
    var approvalsLoaded = false, instructionsLoaded = false
    func rememberRecentMessages() {}; func cancelPreviewWarmup() {}; func clearRecentMessagePreview() {}
    func noteRunningChats() {}; func rememberLastSelected(chatID: String, folderID: String) {}
    func storeChatListCache(_ chats: [ChatConversation], folderID: String) { chatListCache[folderID] = chats }
    func forgetWindow() {}; func loadQueue(for id: String?) {}
    func loadDraft(for id: String?, scope: WorkReference.Scope?, hostIdentity: String?, workspaceID: String?) {}
    func advanceSelection(_ reason: String) {}; func discardSteerReservations() {}; func restoreRecentMessages() {}
    func beginChatListRead(workspaceID: String, peer: String?, scope: WorkReference.Scope?) -> Int? { 1 }
    func applyChatList(_ rows: [ChatConversation], read: Int?, current: [ChatConversation]) -> [ChatConversation] { rows }
    func continuityOwner(folderID: String) -> (scope: WorkReference.Scope, host: String, workspace: String)? { nil }
    func refreshOpen(id: String) async {}; func select(_ chat: ChatConversation?) async { selected = chat }
    func warmRecentChats() {}
    func adoptPeer(_ next: String?) { peer = next }
''' + methods + r'''
}
@MainActor func until(_ condition: () -> Bool) async {
    for _ in 0..<20000 { if condition() { return }; await Task.yield() }
    precondition(condition(), "Controlled request did not arrive")
}
@main struct Check {
    @MainActor static func main() async {
        let m = Model()
        let opening = Task { await m.load(workspaceID: "p", peer: "mac", selectFirst: false) }
        await until { Bridge.list.replies.count == 1 && Bridge.backend.replies.count == 1 && Bridge.voices.replies.count == 1 }
        Bridge.list.finish(0, [.init(id: "history")]); await opening.value
        precondition(m.chats.count == 1 && !m.isLoading && m.error == nil,
                     "Held auxiliary requests hid successful history")
        Bridge.backend.fail(0); Bridge.voices.fail(0)
        await until { m.backendRefreshError != nil }
        precondition(m.chats.count == 1 && m.error == nil)
        // Another project supersedes a suspended catalog and its default voice.
        let first = Task { await m.load(workspaceID: "a", peer: "mac", selectFirst: false) }
        await until { Bridge.list.replies.count == 2 && Bridge.voices.replies.count == 2 }
        Bridge.list.finish(1, [.init(id: "a")]); await first.value
        let second = Task { await m.load(workspaceID: "b", peer: "mac", selectFirst: false) }
        await until { Bridge.list.replies.count == 3 && Bridge.voices.replies.count == 3 && Bridge.backend.replies.count == 3 }
        Bridge.list.finish(2, [.init(id: "b")]); await second.value
        Bridge.backend.finish(1, [.init(id: "old")]); Bridge.voices.finish(1, .init(personas: ["old"], defaultId: "old"))
        Bridge.backend.finish(2, [.init(id: "new")]); Bridge.voices.finish(2, .init(personas: ["new"], defaultId: "new"))
        await until { m.defaultPersonaID == "new" && m.backends.first?.id == "new" }
        precondition(m.chats.first?.id == "b" && m.personas == ["new"] && !m.isLoading)
        print("ChatModel loading: history survives held/failed auxiliary reads; superseded catalog/default voice rejected")
    }
}
'''
with tempfile.TemporaryDirectory(prefix='tokenstat-chat-loading-') as directory:
    path = Path(directory) / 'checks.swift'; path.write_text(swift)
    binary = Path(directory) / 'checks'
    subprocess.run(['swiftc', '-parse-as-library', '-swift-version', '5', '-o', str(binary), str(path)], check=True)
    subprocess.run([str(binary)], check=True)
