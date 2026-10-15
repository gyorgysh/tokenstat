#!/usr/bin/env python3
# SPDX-License-Identifier: LicenseRef-tokenstat-source-available
"""Exercise production chat drop acceptance, ownership and temporary cleanup."""
from pathlib import Path
import subprocess
import tempfile

root = Path(__file__).resolve().parents[1]

def member(path, signature):
    source = (root / path).read_text()
    start = source.index(signature)
    brace = source.index('{', start)
    end, depth = brace + 1, 1
    while depth:
        depth += (source[end] == '{') - (source[end] == '}')
        end += 1
    return source[start:end].replace('private ', '', 1)

mac = 'apps/mac/Sources/Features/Workspaces/Chat/ChatView.swift'
client = 'apps/mac/Sources/Client/ClientChatView.swift'
pieces = [r'''import Foundation
final class NSItemProvider {}
struct WorkReference: Equatable { var scope = "account"; var itemID: String? = "chat" }
struct ChatInboxItem { var file: URL? }
enum ChatInboxDrop { case attachment(ChatInboxItem), text(String), folder }
enum L10n { static func text(_ key: String) -> String { key } }
@MainActor enum WorkCacheAccess { static var readable = true; static func canRead(_ owner: WorkReference) -> Bool { readable && owner.scope == WorkSessionContext.shared.readingScope } }
@MainActor final class WorkSessionContext { static let shared = WorkSessionContext(); var readingScope = "account" }
@MainActor enum ChatInbox {
    static var calls = 0
    static var pending: CheckedContinuation<[ChatInboxDrop], Never>?
    static func drops(from providers: [NSItemProvider]) async -> [ChatInboxDrop] {
        calls += 1
        return await withCheckedContinuation { pending = $0 }
    }
}
@MainActor final class Model {
    struct Chat { let id: String }
    var currentReference: WorkReference? = WorkReference()
    var selected: Chat? = Chat(id: "chat")
    var chats: [Chat] = [Chat(id: "chat")]
    var savedCopy: Bool?
    var sending = false
    var folderID: String? = "workspace"
    var peer: String? = "host"
    var selectionGeneration: UInt64 = 1
    var ready = true
    var creates = 0
    var attachments: [WorkReference] = []
    var importedText: [WorkReference] = []
    var onAttach: (() -> Void)?
    var onCreate: (() -> Void)?
    func isReady(for workspace: String) -> Bool { ready }
    func draftReference(for id: String, in folder: String) -> WorkReference? { WorkReference(itemID: id) }
    func create() async -> Chat? {
        creates += 1
        let created = Chat(id: "created")
        selected = created; currentReference = WorkReference(itemID: created.id); chats = [created]
        selectionGeneration += 1
        onCreate?()
        return created
    }
    func attach(_ item: ChatInboxItem, to owner: WorkReference) async { attachments.append(owner); onAttach?(); await Task.yield() }
    func appendImportedText(_ text: String, to owner: WorkReference) { importedText.append(owner) }
}
@MainActor final class MacView {
    let model = Model()
    var workspaceID = "workspace"
    var isActive = true
    var showingOverview = false
    var dropPresentation: UInt64 = 1
    var inserted = 0
    func insertInDraft(_ text: String) { inserted += 1 }
    func showDropNotice(_ text: String) {}
''']
pieces += [member(mac, signature) for signature in [
    '    private var acceptsDrops:', '    private func receive(_ providers:', '    private func receive(_ drops:']]
pieces += ['}\n@MainActor final class ClientView {\n let model = Model(); var isActive = true; var dropPresentation: UInt64 = 1; func showDropNotice(_ text: String) {}\n']
pieces += [member(client, signature) for signature in [
    '    private var acceptsDrops:', '    private func receive(_ providers:', '    private func receive(_ drops: [ChatInboxDrop])',
    '    private func discardPreparedFiles(', '    private func receive(_ drops: [ChatInboxDrop], owner:']]
pieces += [r'''
}
@main enum Tests {
    @MainActor static func settle() async { for _ in 0..<50 { await Task.yield() } }
    @MainActor static func decode(_ drops: [ChatInboxDrop]) async {
        for _ in 0..<10_000 { if ChatInbox.pending != nil { break }; await Task.yield() }
        guard let continuation = ChatInbox.pending else { preconditionFailure("Provider decoder did not start") }
        ChatInbox.pending = nil; continuation.resume(returning: drops)
        await settle()
    }
    static func prepared() throws -> (ChatInboxDrop, URL) {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try Data([1]).write(to: file)
        return (.attachment(ChatInboxItem(file: file)), file)
    }
    @MainActor static func main() async throws {
        let providers = [NSItemProvider()]
        let owner = WorkReference()
        let policy = MacView()
        precondition(policy.acceptsDrops)
        policy.isActive = false; precondition(!policy.acceptsDrops); policy.isActive = true
        policy.showingOverview = true; precondition(!policy.acceptsDrops); policy.showingOverview = false
        policy.model.sending = true; precondition(!policy.acceptsDrops); policy.model.sending = false
        policy.model.folderID = "wrong"; precondition(!policy.acceptsDrops); policy.model.folderID = "workspace"
        policy.model.ready = false; precondition(!policy.acceptsDrops); policy.model.ready = true
        WorkCacheAccess.readable = false; precondition(!policy.acceptsDrops); WorkCacheAccess.readable = true
        policy.model.savedCopy = true; precondition(policy.acceptsDrops, "Readable offline drafts keep the composer's attachment behavior")
        policy.model.currentReference = nil; policy.model.selected = nil; policy.model.chats = []
        precondition(!policy.acceptsDrops, "An offline no-owner pane cannot create a new conversation")
        policy.model.savedCopy = nil; precondition(policy.acceptsDrops)
        policy.isActive = false
        let calls = ChatInbox.calls
        precondition(!policy.receive(providers) && ChatInbox.calls == calls, "Hidden panes refuse before reading providers")

        for change in ["presentation", "folder", "peer", "account", "access"] {
            let view = MacView(), snapshot = try prepared()
            precondition(view.receive(providers))
            if change == "presentation" { view.dropPresentation += 1 }
            if change == "folder" { view.model.folderID = "other" }
            if change == "peer" { view.model.peer = "other" }
            if change == "account" { WorkSessionContext.shared.readingScope = "other" }
            if change == "access" { WorkCacheAccess.readable = false }
            await decode([snapshot.0])
            precondition(view.model.attachments.isEmpty && view.model.creates == 0)
            precondition(!FileManager.default.fileExists(atPath: snapshot.1.path), "Rejected preparations must clean temporary snapshots")
            WorkSessionContext.shared.readingScope = "account"; WorkCacheAccess.readable = true
        }
        let batch = MacView()
        batch.model.onAttach = { batch.model.currentReference = WorkReference(itemID: "other") }
        precondition(batch.receive(providers))
        await decode([.attachment(.init()), .attachment(.init()), .text("words")])
        precondition(batch.model.attachments == [owner, owner] && batch.model.importedText == [owner],
            "An accepted batch must retain its original owner after navigation")
        for change in ["selection", "presentation"] {
            let view = MacView()
            view.model.currentReference = nil; view.model.selected = nil; view.model.chats = []
            precondition(view.receive(providers))
            if change == "selection" { view.model.selectionGeneration += 1 }
            if change == "presentation" { view.dropPresentation += 1 }
            await decode([.text("words")])
            precondition(view.model.creates == 0, "Stale empty panes cannot create a conversation")
        }
        let empty = MacView()
        empty.model.currentReference = nil; empty.model.selected = nil; empty.model.chats = []
        precondition(empty.receive(providers))
        await decode([.attachment(.init())])
        precondition(empty.model.creates == 1 && empty.model.attachments == [WorkReference(itemID: "created")])
        let retired = MacView()
        retired.model.currentReference = nil; retired.model.selected = nil; retired.model.chats = []
        retired.model.onCreate = { retired.dropPresentation += 1 }
        precondition(retired.receive(providers))
        await decode([.attachment(.init())])
        precondition(retired.model.attachments.isEmpty, "A create completion cannot attach after its pane retires")

        let mobile = ClientView()
        mobile.model.savedCopy = true; precondition(mobile.acceptsDrops)
        mobile.isActive = false
        let rejected = try prepared()
        precondition(!mobile.receive([rejected.0]) && !FileManager.default.fileExists(atPath: rejected.1.path))
        mobile.isActive = true
        let delayed = try prepared()
        precondition(mobile.receive([delayed.0]))
        mobile.model.currentReference = WorkReference(itemID: "other")
        await settle()
        precondition(mobile.model.attachments.isEmpty && !FileManager.default.fileExists(atPath: delayed.1.path),
            "Typed drops that lose their owner must clean prepared snapshots")
        let importer = try prepared()
        await mobile.receive([importer.0], owner: owner)
        precondition(!FileManager.default.fileExists(atPath: importer.1.path), "Importer refusals share the same cleanup")
        print("Chat drop routing: visibility/send/access/offline policy, captured owners, stale creation and Mac/iOS prepared-file cleanup passed")
    }
}
''']
with tempfile.TemporaryDirectory(prefix='tokenstat-drop-routing-') as work:
    work = Path(work)
    source = work / 'Check.swift'
    source.write_text('\n'.join(pieces))
    subprocess.run(['swiftc', '-parse-as-library', '-swift-version', '5', '-module-cache-path', str(work / 'cache'),
        str(source), '-o', str(work / 'check')], check=True)
    subprocess.run([str(work / 'check')], check=True)
