#!/usr/bin/env python3
# SPDX-License-Identifier: LicenseRef-tokenstat-source-available
"""Check handoff file ownership across a suspended local-cache lookup."""
from pathlib import Path
import subprocess
import tempfile

root = Path(__file__).resolve().parents[1]
source = (root / 'apps/mac/Sources/Features/Workspaces/Chat/ChatModel.swift').read_text()
start = source.index('    func keepImportedDraftFiles(')
end = source.index('\n    }', start) + len('\n    }')
method = source[start:end]
harness = r'''import Foundation
struct WorkReference: Equatable { let itemID: String? }
struct WorkSharedDraft: Equatable { let text: String }
struct ChatAttachment: Equatable { let id: String; let name: String; let size: UInt64? }
enum ChatInbox { static let maxBytes = 12 * 1024 * 1024 }
@MainActor enum WorkCacheAccess {
    static var allowed = true
    static func canSave(_ reference: WorkReference) -> Bool { allowed }
}
@MainActor final class ChatLocalAttachmentStore {
    static let shared = ChatLocalAttachmentStore()
    enum Failure: Error { case missing }
    var pending: CheckedContinuation<Bool, Never>?
    var keeps = 0
    func contains(_ file: ChatAttachment, reference: WorkReference) async -> Bool {
        await withCheckedContinuation { pending = $0 }
    }
    func keep(_ file: ChatAttachment, file url: URL, reference: WorkReference) async throws { keeps += 1 }
    func keep(_ file: ChatAttachment, data: Data, reference: WorkReference) async throws { keeps += 1 }
}
struct Payload { let attachment: ChatAttachment; let data: String }
@MainActor enum Bridge {
    static var downloads = 0
    static func downloadChatFile(id: String, attachmentID: String, peer: String?, confirmRelay: (UInt64?) async -> Bool) async throws -> URL {
        downloads += 1
        throw CancellationError()
    }
    static func chatAttachment(id: String, attachmentID: String, peer: String?, confirmRelay: () async -> Bool) async throws -> Payload {
        downloads += 1
        throw CancellationError()
    }
}
@MainActor final class Model {
    var currentReference = WorkReference(itemID: "chat")
    var handoffDraft = WorkSharedDraft(text: "local")
    var peer: String? = "host"
    func confirmFileRelay(name: String, size: UInt64?, remaining: UInt64? = nil) async -> Bool { true }
''' + method + r'''
}
@main struct Check {
    @MainActor static func main() async throws {
        for size: UInt64 in [1, 20 * 1024 * 1024] {
            for change in ["navigation", "draft", "access", "cancel", "cached", "current"] {
                let model = Model()
                let reference = model.currentReference, expected = model.handoffDraft
                WorkCacheAccess.allowed = true
                Bridge.downloads = 0
                let task = Task {
                    try await model.keepImportedDraftFiles([.init(id: "file", name: "file", size: size)], reference: reference, expected: expected)
                }
                while ChatLocalAttachmentStore.shared.pending == nil { await Task.yield() }
                switch change {
                case "navigation": model.currentReference = .init(itemID: "another")
                case "draft": model.handoffDraft = .init(text: "edited")
                case "access": WorkCacheAccess.allowed = false
                case "cancel": task.cancel()
                default: break
                }
                let pending = ChatLocalAttachmentStore.shared.pending!
                ChatLocalAttachmentStore.shared.pending = nil
                pending.resume(returning: change == "cached")
                _ = await task.result
                precondition(Bridge.downloads == (change == "current" ? 1 : 0), "late cache lookup started a download: \(change), size=\(size)")
                precondition(ChatLocalAttachmentStore.shared.keeps == 0)
            }
        }
        print("Handoff files: navigation, edits, revoked access and cancellation stop stale downloads; cache hits and current downloads preserved")
    }
}
'''
with tempfile.TemporaryDirectory(prefix='tokenstat-handoff-files-') as directory:
    path = Path(directory)
    (path / 'Check.swift').write_text(harness)
    subprocess.run(['swiftc', '-parse-as-library', str(path / 'Check.swift'), '-o', str(path / 'check')], check=True)
    subprocess.run([str(path / 'check')], check=True)
