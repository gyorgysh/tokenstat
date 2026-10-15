#!/usr/bin/env python3
# SPDX-License-Identifier: LicenseRef-tokenstat-source-available
"""Exercise the production preview loader while foreground transfers overlap."""
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
    return source[start:end]
loader = member('apps/mac/Sources/Features/Workspaces/Chat/ChatModel.swift', '    private func loadResponseAttachment(').replace('private func', 'func', 1)
progress = member('apps/mac/Sources/Features/Workspaces/Chat/ChatFileTransferControls.swift', '    func updateFileProgress(')
stub = '''import Foundation
struct WorkReference: Equatable { var itemID: String? = "chat" }
struct ChatAttachment { var id = "image"; var name = "image.png"; var mediaType: String? = "image/png"; var size: UInt64? = 3 }
enum BridgeError: Error { case core(code: String, message: String) }
enum L10n { static func text(_ key: String) -> String { key } }
enum WorkCacheAccess { static func canRead(_ ref: WorkReference) -> Bool { true }; static func canSave(_ ref: WorkReference) -> Bool { true } }
enum WorkSavedPreview {
    static func read(reference: WorkReference, attachment: String) async -> Data? { nil }
    static func save(reference: WorkReference, attachment: ChatAttachment, data: Data) async {}
}
actor ChatAttachmentCache {
    static let shared = ChatAttachmentCache()
    func epoch() -> UInt64 { 0 }
    func readFile(reference: WorkReference, attachment: String, size: UInt64?) -> URL? { nil }
    func read(reference: WorkReference, attachment: String) -> Data? { nil }
    func write(_ data: Data, reference: WorkReference, attachment: String, epoch: UInt64) -> Bool { true }
    func writeFile(_ file: URL, reference: WorkReference, attachment: String, epoch: UInt64) throws -> URL { file }
}
enum ChatInbox { static let maxBytes = 6 * 1024 * 1024 }
enum ChatAttachmentDownloadPolicy { static func permitsAutomaticDownload(size: UInt64?, isLocalImage: Bool) -> Bool { true } }
enum RemoteHostFeature { case chatRecovery; func isSupported(peer: String?) async -> Bool { true } }
@MainActor enum Bridge {
    static var beforeProgress: (() -> Void)?
    static var failure: Error?
    static var calls = 0
    static var downloadedBytes = 3
    static var downloadedFiles: [URL] = []
    static func downloadChatFile(id: String, attachmentID: String, peer: String?,
        confirmRelay: @escaping @Sendable (UInt64?) async -> Bool,
        progress: @escaping @Sendable (Double) async throws -> Void) async throws -> URL {
        calls += 1
        beforeProgress?()
        if let failure { throw failure }
        try await progress(1)
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try Data([1,2,3]).write(to: file)
        if downloadedBytes > 3 {
            let handle = try FileHandle(forWritingTo: file)
            try handle.truncate(atOffset: UInt64(downloadedBytes))
            try handle.close()
        }
        downloadedFiles.append(file)
        return file
    }
    struct Payload { var data: String }
    static func chatAttachment(id: String, attachmentID: String, peer: String?, confirmRelay: @escaping @Sendable () async -> Bool) async throws -> Payload { Payload(data: "AQID") }
}
@MainActor final class Model {
    var currentReference: WorkReference? = WorkReference()
    var selectionGeneration: UInt64 = 1
    var savedCopy: Bool? = nil
    var peer: String? = nil
    var responseAttachmentData: [String:Data] = [:]
    var responseAttachmentFiles: [String:URL] = [:]
    var responseAttachmentErrors: [String:String] = [:]
    var loadingResponseAttachments: Set<String> = []
    var attemptedResponseAttachments: Set<String> = []
    var attachmentCacheGeneration: UInt64 = 0
    var fileTransferInFlight = false
    var fileTransferCancelled = false
    var fileTransferName: String?
    var fileTransferProgress = 0.0
    func selectionMatches(id: String, generation: UInt64) -> Bool { currentReference?.itemID == id && selectionGeneration == generation }
    func confirmFileRelay(name: String, size: UInt64?, remaining: UInt64? = nil) async -> Bool { false }
    static func downloadFailure(_ error: Error) -> String { "failed" }
'''
tests = '''
}
@main enum Tests {
    @MainActor static func main() async {
        defer { for file in Bridge.downloadedFiles { try? FileManager.default.removeItem(at: file) } }
        let background = Model()
        background.fileTransferInFlight = true
        background.fileTransferName = "upload.png"
        await background.loadResponseAttachment(ChatAttachment(), id: "chat", generation: 1, userInitiated: false)
        assert(background.responseAttachmentData["image"] == Data([1,2,3]), "Automatic local previews must load while an upload is active")
        assert(background.fileTransferInFlight && background.fileTransferName == "upload.png", "A preview cannot reset foreground transfer controls")
        let cancelledForeground = Model()
        Bridge.beforeProgress = { cancelledForeground.fileTransferCancelled = true }
        await cancelledForeground.loadResponseAttachment(ChatAttachment(), id: "chat", generation: 1, userInitiated: false)
        assert(cancelledForeground.responseAttachmentData["image"] != nil, "Unrelated foreground cancellation cannot cancel an automatic preview")
        let cancelledPreview = Model()
        Bridge.beforeProgress = nil
        Bridge.failure = CancellationError()
        await cancelledPreview.loadResponseAttachment(ChatAttachment(), id: "chat", generation: 1, userInitiated: false)
        assert(cancelledPreview.responseAttachmentErrors.isEmpty, "Cancellation or declined relay consent is not a download failure")
        let foreground = Model()
        Bridge.failure = nil
        Bridge.beforeProgress = { foreground.fileTransferCancelled = true }
        await foreground.loadResponseAttachment(ChatAttachment(), id: "chat", generation: 1, userInitiated: true)
        assert(foreground.responseAttachmentData.isEmpty && foreground.responseAttachmentErrors.isEmpty && !foreground.fileTransferInFlight, "Explicit Cancel still stops a foreground download without a false failure")
        Bridge.beforeProgress = nil
        let claimed = Model()
        Bridge.failure = BridgeError.core(code: "file_transfer_busy", message: "busy")
        await claimed.loadResponseAttachment(ChatAttachment(), id: "chat", generation: 1, userInitiated: false)
        assert(claimed.responseAttachmentErrors.isEmpty && claimed.attemptedResponseAttachments.isEmpty, "A file in progress in another window is deferred, not failed")
        let busy = Model()
        busy.fileTransferInFlight = true
        let before = Bridge.calls
        await busy.loadResponseAttachment(ChatAttachment(), id: "chat", generation: 1, userInitiated: true)
        assert(Bridge.calls == before && busy.responseAttachmentErrors.isEmpty && busy.attemptedResponseAttachments.isEmpty, "A busy foreground transfer must leave a retryable preview")
        Bridge.failure = CocoaError(.fileReadNoSuchFile)
        let failed = Model()
        await failed.loadResponseAttachment(ChatAttachment(), id: "chat", generation: 1, userInitiated: false)
        assert(failed.responseAttachmentErrors["image"] == "failed", "Real file errors remain visible")
        Bridge.failure = nil
        await failed.loadResponseAttachment(ChatAttachment(), id: "chat", generation: 1, userInitiated: true)
        assert(failed.responseAttachmentData["image"] != nil && failed.responseAttachmentErrors.isEmpty, "Explicit retry clears the old error")
        let moved = Model()
        Bridge.beforeProgress = { moved.selectionGeneration += 1; moved.currentReference = WorkReference(itemID: "other") }
        await moved.loadResponseAttachment(ChatAttachment(), id: "chat", generation: 1, userInitiated: false)
        assert(moved.responseAttachmentData.isEmpty && moved.responseAttachmentErrors.isEmpty, "A late preview cannot publish into another chat")
        Bridge.beforeProgress = nil
        Bridge.downloadedBytes = ChatInbox.maxBytes + 1
        for archivedSize: UInt64? in [nil, 3] {
            let large = Model()
            await large.loadResponseAttachment(ChatAttachment(size: archivedSize), id: "chat", generation: 1, userInitiated: false)
            assert(large.responseAttachmentData.isEmpty && large.responseAttachmentFiles["image"] != nil,
                   "A large downloaded image must stay file-backed when archive size is missing or understated")
        }
        print("Preview loading: concurrent transfer isolation, retry, ownership and actual file-size bounds passed")
    }
}
'''
with tempfile.TemporaryDirectory(prefix='tokenstat-preview-loader-') as work:
    work = Path(work)
    source = work / 'Check.swift'
    source.write_text(stub + progress + '\n' + loader + tests)
    subprocess.run(['swiftc', '-parse-as-library', '-swift-version', '5', '-module-cache-path', str(work/'cache'), str(source), '-o', str(work/'check')], check=True)
    subprocess.run([str(work/'check')], check=True)
