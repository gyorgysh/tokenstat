// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
// Compile with OriginalFileCoordination.swift WorkReference.swift ChatDraftStore.swift ChatLocalAttachmentStore.swift.
import Foundation
import Darwin

struct ChatAttachment: Codable, Sendable, Identifiable, Hashable {
    var id: String; var name: String; var mediaType: String?; var size: UInt64?
}
@MainActor private final class Check { var called = false }

private actor HeldUpload {
    var started = false
    private var continuation: CheckedContinuation<Void, Never>?
    func run(_ data: Data) async -> ChatAttachment {
        started = true
        await withTaskCancellationHandler {
            await withCheckedContinuation { continuation = $0 }
        } onCancel: {
            Task { await self.finish() }
        }
        return ChatAttachment(id: "uploaded", name: "held.txt", mediaType: "text/plain", size: UInt64(data.count))
    }
    func finish() { continuation?.resume(); continuation = nil }
}

@main struct OriginalFileCoordinationTests {
    @MainActor static func main() async throws {
        if CommandLine.arguments.count == 3, CommandLine.arguments[1] == "--participant" {
            let root = URL(fileURLWithPath: CommandLine.arguments[2])
            let drafts = ChatDraftStore(directory: root)
            assert(!drafts.saveFailed)
            try Data("ready".utf8).write(to: root.appendingPathComponent("child-ready"))
            withExtendedLifetime(drafts) {
                _ = try? FileHandle.standardInput.read(upToCount: 1)
                // Simulate abrupt exit: only the OS releases the store lease.
                Darwin._exit(23)
            }
        }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("original-access-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let reference = WorkReference(scope: .local(installationID: "test"), hostIdentity: "host",
            workspaceID: "folder", kind: .conversation, itemID: "chat")
        let files = ChatLocalAttachmentStore(directory: root)
        let bytes = Data("Original writing".utf8)
        let attachment = try await files.stage(data: bytes, name: "draft.txt", mediaType: "text/plain", reference: reference)
        let retained = try await files.retained(in: reference.scope).files[0]
        // A temporary registration failure is retryable, not cached forever.
        let blocked = root.appendingPathComponent("blocked-registration")
        try Data([1]).write(to: blocked)
        let retrying = OriginalFileCoordination.Registration(directory: blocked)
        do { _ = try retrying.get(); assertionFailure("Registered through a file instead of a directory") }
        catch {}
        try FileManager.default.removeItem(at: blocked)
        _ = try retrying.get()
        let localDrafts = ChatDraftStore(directory: root)
        let child = Process()
        child.executableURL = URL(fileURLWithPath: CommandLine.arguments[0])
        child.arguments = ["--participant", root.path]
        let input = Pipe()
        child.standardInput = input
        try child.run()
        defer { if child.isRunning { child.terminate(); child.waitUntilExit() } }
        let deadline = Date().addingTimeInterval(5)
        while !FileManager.default.fileExists(atPath: root.appendingPathComponent("child-ready").path) {
            assert(child.isRunning && Date() < deadline, "Participant did not register")
            try await Task.sleep(for: .milliseconds(10))
        }
        let check = Check()
        do {
            try await files.remove(retained) { check.called = true; return true }
            assertionFailure("Removed an original while another process held draft state")
        } catch OriginalFileCoordination.Failure.anotherInstance {}
        assert(!check.called, "Process ownership must be checked before references")
        let preserved = try await files.read(attachment, reference: reference)
        assert(preserved == bytes)
        try input.fileHandleForWriting.write(contentsOf: Data([1]))
        child.waitUntilExit()
        assert(child.terminationStatus == 23)
        // Same-process store instances share participation; dead process leases
        // no longer prevent the explicit removal and are pruned under the gate.
        try await files.remove(retained) {
            try localDrafts.referencedAttachmentIDs(for: reference).isEmpty
        }
        do { _ = try await files.read(attachment, reference: reference); assertionFailure("Original was not removed") }
        catch ChatLocalAttachmentStore.Failure.missing {}
        // Two actor instances in the same process also share in-flight use.
        let heldFile = try await files.stage(data: bytes, name: "held.txt", mediaType: "text/plain", reference: reference)
        let heldRecord = try await files.retained(in: reference.scope).files.first { $0.attachment.id == heldFile.id }!
        let otherFiles = ChatLocalAttachmentStore(directory: root)
        let upload = HeldUpload()
        async let resolved = otherFiles.resolve(heldFile, reference: reference) { await upload.run($0) }
        let uploadDeadline = Date().addingTimeInterval(5)
        while !(await upload.started) {
            assert(Date() < uploadDeadline)
            try await Task.sleep(for: .milliseconds(10))
        }
        do {
            try await files.remove(heldRecord, ifUnused: { true })
            assertionFailure("Removed a file being uploaded by another store instance")
        } catch OriginalFileCoordination.Failure.busy {}
        await upload.finish()
        _ = try await resolved
        let current = try await files.retained(in: reference.scope).files.first { $0.attachment.id == heldFile.id }!
        try await files.remove(current, ifUnused: { true })
        print("Original-file coordination: live process refusal, shared local stores and abrupt-exit release passed")
    }
}
