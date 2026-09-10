// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
import Foundation
import CryptoKit

/// Original draft files are user writing. Cache eviction and sign-out never
/// remove them. Each file belongs to one complete conversation reference.
actor ChatLocalAttachmentStore {
    static let shared = ChatLocalAttachmentStore()
    static let maximumBytes = 12 * 1024 * 1024
    private let directory: URL
    private struct File: Codable {
        let reference: WorkReference
        let attachment: ChatAttachment
        let data: Data
        var uploaded: ChatAttachment? = nil
    }
    private var uploads: [URL: Task<ChatAttachment, Error>] = [:]
    private var removals: Set<URL> = []
    enum Failure: LocalizedError {
        case invalid, missing, inUse
        var errorDescription: String? {
            switch self {
            case .invalid: "This attachment could not be saved on this device. Files can be up to 12 MB."
            case .inUse: "This file is now used by a draft or pending message. It has been kept."
            case .missing: "An original draft file is unavailable. Remove it and attach the original again before sending."
            }
        }
    }
    init(directory: URL? = nil) {
        self.directory = directory ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("tokenstat-drafts/files", isDirectory: true)
    }
    nonisolated static func isLocal(_ attachment: ChatAttachment) -> Bool { attachment.id.hasPrefix("local-draft:") }
    private func location(_ id: String, reference: WorkReference) throws -> URL {
        guard let key = WorkReferenceKey.conversation(reference), !id.isEmpty, id.utf8.count <= 256 else { throw Failure.invalid }
        let digest = SHA256.hash(data: Data((key + "|" + id).utf8)).map { String(format: "%02x", $0) }.joined()
        return directory.appendingPathComponent(digest + ".json")
    }
    func stage(data: Data, name: String, mediaType: String?, reference: WorkReference) throws -> ChatAttachment {
        guard !data.isEmpty, data.count <= Self.maximumBytes else { throw Failure.invalid }
        let attachment = ChatAttachment(id: "local-draft:" + UUID().uuidString, name: name, mediaType: mediaType, size: UInt64(data.count))
        var owner = reference
        owner.anchor = nil
        let url = try location(attachment.id, reference: owner)
        let encoded = try JSONEncoder().encode(File(reference: owner, attachment: attachment, data: data))
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        #if os(macOS)
        try encoded.write(to: url, options: .atomic)
        #else
        try encoded.write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        #endif
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        try handle.synchronize()
        return attachment
    }
    /// Keep an explicitly imported host file under the same descriptor. It
    /// remains usable offline, and sharing it again needs no second upload.
    func keep(_ attachment: ChatAttachment, data: Data, reference: WorkReference) throws {
        guard !Self.isLocal(attachment), !data.isEmpty, data.count <= Self.maximumBytes,
              UInt64(data.count) == attachment.size else { throw Failure.invalid }
        var owner = reference
        owner.anchor = nil
        let url = try location(attachment.id, reference: owner)
        guard !removals.contains(url), uploads[url] == nil else { throw Failure.invalid }
        let encoded = try JSONEncoder().encode(File(reference: owner, attachment: attachment, data: data, uploaded: attachment))
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        #if os(macOS)
        try encoded.write(to: url, options: .atomic)
        #else
        try encoded.write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        #endif
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        try handle.synchronize()
    }
    func resolve(_ attachment: ChatAttachment, reference: WorkReference,
                 upload: @escaping @Sendable (Data) async throws -> ChatAttachment) async throws -> ChatAttachment {
        let url = try location(attachment.id, reference: reference)
        guard !removals.contains(url) else { throw Failure.invalid }
        if let existing = uploads[url] { return try await existing.value }
        let file = try load(attachment, reference: reference)
        if let uploaded = file.uploaded { return uploaded }
        let task = Task {
            let uploaded = try await upload(file.data)
            guard !Self.isLocal(uploaded) else { throw Failure.invalid }
            var updated = file
            updated.uploaded = uploaded
            let encoded = try JSONEncoder().encode(updated)
            #if os(macOS)
            try encoded.write(to: url, options: .atomic)
            #else
            try encoded.write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
            #endif
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
            let handle = try FileHandle(forWritingTo: url)
            defer { try? handle.close() }
            try handle.synchronize()
            return uploaded
        }
        uploads[url] = task
        defer { uploads[url] = nil }
        return try await task.value
    }
    struct RetainedFile: Identifiable, Sendable {
        let reference: WorkReference
        let attachment: ChatAttachment
        let bytes: Int
        let fingerprint: Data
        var id: String { (WorkReferenceKey.conversation(reference) ?? "") + "|" + attachment.id }
    }
    struct RetainedListing: Sendable {
        var files: [RetainedFile] = []
        var hasUnreadableFiles = false
    }
    func retained(in scope: WorkReference.Scope) throws -> RetainedListing {
        guard FileManager.default.fileExists(atPath: directory.path) else { return RetainedListing() }
        let urls = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.isRegularFileKey], options: [.skipsHiddenFiles])
        var result = RetainedListing()
        for url in urls where url.pathExtension == "json" {
            try Task.checkCancellation()
            guard (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true else { continue }
            let handle = try FileHandle(forReadingFrom: url)
            let encoded: Data
            do { encoded = try handle.read(upToCount: 17 * 1024 * 1024) ?? Data(); try handle.close() }
            catch { try? handle.close(); throw error }
            guard encoded.count < 17 * 1024 * 1024, let file = try? JSONDecoder().decode(File.self, from: encoded) else {
                result.hasUnreadableFiles = true
                continue
            }
            guard file.reference.scope == scope, try location(file.attachment.id, reference: file.reference).resolvingSymlinksInPath().path == url.resolvingSymlinksInPath().path else { continue }
            result.files.append(RetainedFile(reference: file.reference, attachment: file.attachment, bytes: encoded.count,
                                       fingerprint: Data(SHA256.hash(data: encoded))))
        }
        result.files.sort { $0.attachment.name.localizedStandardCompare($1.attachment.name) == .orderedAscending }
        return result
    }
    /// Check live draft references and unlink in one main-actor operation.
    /// Reserving the file first keeps an upload from starting during the hop.
    func remove(_ retained: RetainedFile,
                ifUnused check: @escaping @MainActor @Sendable () throws -> Bool) async throws {
        let url = try location(retained.attachment.id, reference: retained.reference)
        guard uploads[url] == nil, removals.insert(url).inserted else { throw Failure.invalid }
        defer { removals.remove(url) }
        _ = try load(retained.attachment, reference: retained.reference)
        try await MainActor.run {
            guard try check() else { throw Failure.inUse }
            // No await after checking the references. Every live window writes
            // draft/outbox intent on this same actor, including unsaved drafts.
            let handle = try FileHandle(forReadingFrom: url)
            defer { try? handle.close() }
            let encoded = try handle.read(upToCount: 17 * 1024 * 1024) ?? Data()
            guard encoded.count < 17 * 1024 * 1024,
                  Data(SHA256.hash(data: encoded)) == retained.fingerprint else { throw Failure.invalid }
            try FileManager.default.removeItem(at: url)
        }
    }
    func read(_ attachment: ChatAttachment, reference: WorkReference) throws -> Data {
        try load(attachment, reference: reference).data
    }
    private func load(_ attachment: ChatAttachment, reference: WorkReference) throws -> File {
        let url = try location(attachment.id, reference: reference)
        guard let handle = try? FileHandle(forReadingFrom: url) else { throw Failure.missing }
        defer { try? handle.close() }
        let encoded = try handle.read(upToCount: 17 * 1024 * 1024) ?? Data()
        guard encoded.count < 17 * 1024 * 1024, let file = try? JSONDecoder().decode(File.self, from: encoded),
              WorkReferenceKey.conversation(file.reference) == WorkReferenceKey.conversation(reference),
              file.attachment == attachment, !file.data.isEmpty, file.data.count <= Self.maximumBytes,
              UInt64(file.data.count) == attachment.size else { throw Failure.missing }
        return file
    }
}
