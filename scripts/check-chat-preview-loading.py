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
viewer_loader = member('apps/mac/Sources/Features/Workspaces/Chat/ChatImageGallery.swift', '    private func loadSelected(').replace('private func', 'func', 1)
viewer_export = member('apps/mac/Sources/Features/Workspaces/Chat/ChatImageGallery.swift', '    private func copyImage(').replace('private func', 'func', 1).replace('FileManager.default.copyItem(at: source, to: temporary)', 'ExportCopyGate.shared.copyItem(at: source, to: temporary)')
stub = '''import Foundation
struct WorkReference: Equatable { var itemID: String? = "chat" }
struct ChatAttachment { var id = "image"; var name = "image.png"; var mediaType: String? = "image/png"; var size: UInt64? = 3 }
enum BridgeError: Error { case core(code: String, message: String) }
enum L10n { static func text(_ key: String) -> String { key } }
enum WorkCacheAccess { static var readable = true; static func canRead(_ ref: WorkReference) -> Bool { readable }; static func canSave(_ ref: WorkReference) -> Bool { readable } }
final class ExportCopyGate: @unchecked Sendable {
    static let shared = ExportCopyGate()
    private let condition = NSCondition()
    private var blocked = false
    private var count = 0
    var calls: Int { condition.lock(); defer { condition.unlock() }; return count }
    func reset(blocked: Bool = false) { condition.lock(); self.blocked = blocked; count = 0; condition.unlock() }
    func release() { condition.lock(); blocked = false; condition.broadcast(); condition.unlock() }
    func copyItem(at source: URL, to destination: URL) throws {
        condition.lock()
        count += 1
        condition.broadcast()
        while blocked { condition.wait() }
        condition.unlock()
        try FileManager.default.copyItem(at: source, to: destination)
    }
}
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
    var requestedImages: [String] = []
    func downloadResponseAttachment(_ attachment: ChatAttachment) async { requestedImages.append(attachment.id) }
    func selectionMatches(id: String, generation: UInt64) -> Bool { currentReference?.itemID == id && selectionGeneration == generation }
    func confirmFileRelay(name: String, size: UInt64?, remaining: UInt64? = nil) async -> Bool { false }
    static func downloadFailure(_ error: Error) -> String { "failed" }
'''
viewer = '''
}
@MainActor final class Viewer {
    struct Request { var reference: WorkReference? = WorkReference() }
    struct Resource { let available: Bool }
    let model: Model
    var request = Request()
    var attachment = ChatAttachment()
    var error: String?
    var resource: Resource { Resource(available: model.responseAttachmentData[attachment.id] != nil || model.responseAttachmentFiles[attachment.id] != nil) }
    init(_ model: Model) { self.model = model }
''' + viewer_loader + '\n' + viewer_export
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
        let waiting = Model()
        waiting.fileTransferInFlight = true
        let lightbox = Viewer(waiting)
        let opening = Task { await lightbox.loadSelected() }
        try? await Task.sleep(for: .milliseconds(10))
        assert(waiting.requestedImages.isEmpty, "The lightbox must wait for a retiring foreground transfer")
        waiting.fileTransferInFlight = false
        await opening.value
        assert(waiting.requestedImages == ["image"], "Next must download once the previous image releases its slot")
        let backgroundPreview = Model()
        backgroundPreview.loadingResponseAttachments = ["image"]
        let explicit = Viewer(backgroundPreview)
        let explicitOpen = Task { await explicit.loadSelected() }
        try? await Task.sleep(for: .milliseconds(10))
        backgroundPreview.loadingResponseAttachments = []
        await explicitOpen.value
        assert(backgroundPreview.requestedImages == ["image"], "An explicit open must retry after a background preview declines relay consent")
        let canceled = Model()
        canceled.fileTransferInFlight = true
        let canceledViewer = Viewer(canceled)
        let canceledOpen = Task { await canceledViewer.loadSelected() }
        try? await Task.sleep(for: .milliseconds(10))
        canceledOpen.cancel()
        await canceledOpen.value
        assert(canceled.requestedImages.isEmpty, "Closing the lightbox must cancel its waiting download")
        let changed = Model()
        changed.fileTransferInFlight = true
        let changedViewer = Viewer(changed)
        let changedOpen = Task { await changedViewer.loadSelected() }
        try? await Task.sleep(for: .milliseconds(10))
        changedViewer.attachment.id = "different-image"
        changed.fileTransferInFlight = false
        await changedOpen.value
        assert(changed.requestedImages.isEmpty, "A waiting request cannot retarget a newly selected image")
        let warmed = Model()
        warmed.loadingResponseAttachments = ["image"]
        let warmedViewer = Viewer(warmed)
        let warmedOpen = Task { await warmedViewer.loadSelected() }
        try? await Task.sleep(for: .milliseconds(10))
        warmed.responseAttachmentData["image"] = Data([1])
        warmed.loadingResponseAttachments = []
        await warmedOpen.value
        assert(warmed.requestedImages.isEmpty, "A successful background preview must not download twice")
        try! await checkImageExports()
        print("Preview loading: transfer isolation, file-size bounds, lightbox waiting and scoped atomic image export passed")
    }

    @MainActor static func checkImageExports() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { ExportCopyGate.shared.release(); WorkCacheAccess.readable = true; try? FileManager.default.removeItem(at: directory) }
        let source = directory.appendingPathComponent("source.png")
        let destination = directory.appendingPathComponent("saved.png")
        let previous = Data("previous image".utf8), replacement = Data("new image".utf8)
        try replacement.write(to: source)
        let reference = WorkReference()

        // Both publication paths are real filesystem operations from production.
        for replacing in [false, true] {
            ExportCopyGate.shared.reset()
            if replacing { try previous.write(to: destination) }
            let viewer = Viewer(Model())
            await viewer.copyImage(source, to: destination, reference: reference)
            let saved = try Data(contentsOf: destination)
            assert(saved == replacement, "Save must publish the completed image")
            assert(ExportCopyGate.shared.calls == 1 && viewer.error == nil)
            try FileManager.default.removeItem(at: destination)
        }
        for revoked in [false, true] {
            ExportCopyGate.shared.reset()
            let model = Model(), viewer: Viewer
            viewer = Viewer(model)
            if revoked { WorkCacheAccess.readable = false } else { model.currentReference = nil }
            await viewer.copyImage(source, to: destination, reference: reference)
            WorkCacheAccess.readable = true
            assert(ExportCopyGate.shared.calls == 0 && !FileManager.default.fileExists(atPath: destination.path), "Save must check ownership and access before copying")
        }
        for change in ["chat", "access", "cancel"] {
            ExportCopyGate.shared.reset(blocked: true)
            try previous.write(to: destination)
            let model = Model(), viewer: Viewer
            viewer = Viewer(model)
            let task = Task { await viewer.copyImage(source, to: destination, reference: reference) }
            for _ in 0..<10_000 {
                if ExportCopyGate.shared.calls > 0 { break }
                await Task.yield()
            }
            assert(ExportCopyGate.shared.calls == 1, "The fixture must suspend inside the detached copy")
            if change == "chat" { model.currentReference = WorkReference(itemID: "other") }
            if change == "access" { WorkCacheAccess.readable = false }
            if change == "cancel" { task.cancel() }
            ExportCopyGate.shared.release()
            await task.value
            WorkCacheAccess.readable = true
            let preserved = try Data(contentsOf: destination)
            assert(preserved == previous, "A canceled or disowned save cannot publish after its copy finishes")
            let remaining = try FileManager.default.contentsOfDirectory(atPath: directory.path)
            assert(!remaining.contains { $0.hasPrefix(".tokenstat-image-") }, "Refused exports must remove their temporary copies")
            assert(viewer.error == nil, "Refusing an outdated save is not a visible file error")
        }
        ExportCopyGate.shared.reset()
        let failed = Viewer(Model())
        await failed.copyImage(directory.appendingPathComponent("missing.png"), to: destination, reference: reference)
        let preserved = try Data(contentsOf: destination)
        assert(preserved == previous, "A failed copy cannot damage the existing destination")
        assert(failed.error == "common.chat.images.save_failed")
        let remaining = try FileManager.default.contentsOfDirectory(atPath: directory.path)
        assert(!remaining.contains { $0.hasPrefix(".tokenstat-image-") })
    }
}
'''
with tempfile.TemporaryDirectory(prefix='tokenstat-preview-loader-') as work:
    work = Path(work)
    source = work / 'Check.swift'
    source.write_text(stub + progress + '\n' + loader + viewer + tests)
    subprocess.run(['swiftc', '-parse-as-library', '-swift-version', '5', '-module-cache-path', str(work/'cache'), str(source), '-o', str(work/'check')], check=True)
    subprocess.run([str(work/'check')], check=True)
