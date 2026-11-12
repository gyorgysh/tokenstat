#!/usr/bin/env python3
# SPDX-License-Identifier: LicenseRef-tokenstat-source-available
"""A text-only send must not claim or disturb another active file transfer."""
from pathlib import Path
import subprocess
import tempfile

root = Path(__file__).resolve().parents[2]
source = (root / 'apps/mac/Sources/Features/Workspaces/Chat/ChatModel.swift').read_text()
start = source.index('    private func resolveDraftAttachments(')
end = source.index('\n    func keepImportedDraftFiles(', start)
method = source[start:end].replace('    private func resolveDraftAttachments(', '    func resolveDraftAttachments(', 1)
fixture = r'''
import Foundation
struct ChatAttachment { let id: String; let name: String; let mediaType: String?; let size: UInt64? }
struct WorkReference: Equatable { let itemID: String? }
enum BridgeError: Error { case core(code: String, message: String) }
enum L10n { static func text(_ key: String) -> String { key } }
enum WorkCacheAccess { static func canSave(_ reference: WorkReference) -> Bool { true } }
@MainActor final class ChatLocalAttachmentStore {
    static let shared = ChatLocalAttachmentStore()
    static func isLocal(_ file: ChatAttachment) -> Bool { true }
    func resolveStream(_ file: ChatAttachment, reference: WorkReference,
                       send: (URL) async throws -> ChatAttachment) async throws -> ChatAttachment {
        try await send(URL(fileURLWithPath: "/tmp/fixture"))
    }
}
enum Bridge {
    static func uploadChatFile(id: String, file: URL, name: String, mediaType: String?, peer: String?,
        confirmRelay: (UInt64?) async -> Bool, progress: (Double) async throws -> Void) async throws -> ChatAttachment {
        ChatAttachment(id: "uploaded", name: name, mediaType: mediaType, size: nil)
    }
}
@MainActor final class Model {
    var currentReference: WorkReference? = .init(itemID: "chat")
    var savedCopy: String?
    var fileTransferInFlight = true, fileTransferCancelled = true
    var fileTransferName: String? = "download"
    func confirmFileRelay(name: String, size: UInt64?, remaining: UInt64?) async -> Bool { true }
    func updateFileProgress(_ value: Double, name: String, reference: WorkReference) async throws {}
METHOD
}
@main struct Test {
    @MainActor static func main() async throws {
        let model = Model(), reference = WorkReference(itemID: "chat")
        let files = try await model.resolveDraftAttachments([], reference: reference, peer: nil)
        precondition(files.isEmpty && model.fileTransferInFlight && model.fileTransferCancelled && model.fileTransferName == "download")
        do {
            _ = try await model.resolveDraftAttachments([], reference: .init(itemID: nil), peer: nil)
            preconditionFailure("An invalid owner must not prepare a send")
        } catch is CancellationError {}
        do {
            _ = try await model.resolveDraftAttachments([ChatAttachment(id: "x", name: "file", mediaType: nil, size: nil)], reference: reference, peer: nil)
            preconditionFailure("A second file transfer must not start")
        } catch BridgeError.core(code: "file_transfer_busy", message: _) {}
        print("Text-only sends leave an active file transfer alone; competing uploads remain blocked")
    }
}
'''.replace('METHOD', method)
with tempfile.TemporaryDirectory(prefix='tokenstat-text-send-') as directory:
    path = Path(directory)
    (path / 'Test.swift').write_text(fixture)
    subprocess.run(['swiftc', '-parse-as-library', str(path / 'Test.swift'), '-o', str(path / 'test')], check=True)
    subprocess.run([str(path / 'test')], check=True)
