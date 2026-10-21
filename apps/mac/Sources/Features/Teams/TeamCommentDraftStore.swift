// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
import Foundation
import CryptoKit
import Darwin

/// Team writing is filed by stable person and exact published resource. It
/// never uses a private conversation ID, personal queue or provider session.
struct TeamCommentTarget: Codable, Hashable, Sendable {
    let origin: String
    let person: String
    let organization: String
    let repository: String
    let checkout: String
    let share: String
    let host: String

    var fields: JSONValue { .object(["organization":.string(organization), "repository":.string(repository), "checkout":.string(checkout), "share":.string(share)]) }
}
struct TeamCommentAttempt: Codable, Equatable, Sendable {
    let id: String
    let createdAtMs: Int64
}
struct TeamCommentDraft: Codable, Equatable, Sendable {
    let revision: UUID
    let text: String
    let attempt: TeamCommentAttempt?

    var input: JSONValue? {
        guard let attempt else { return nil }
        return .object(["text":.string(text), "clientMessageId":.string(attempt.id), "clientMessageCreatedAtMs":.int(attempt.createdAtMs)])
    }
    var canSend: Bool {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, text.utf8.count <= 8192 else { return false }
        let probe = TeamCommentDraft(revision: revision, text: text, attempt: attempt ?? .init(id: UUID().uuidString, createdAtMs: 1))
        return probe.input.flatMap { try? JSONEncoder().encode($0).count }.map { $0 <= 14 * 1024 } ?? false
    }
}
enum TeamCommentDraftFailure: LocalizedError {
    case changed, pending, unavailable, tooLong
    var errorDescription: String? {
        switch self {
        case .changed: L10n.text("common.teams.comment_draft_changed")
        case .pending: L10n.text("common.teams.comment_check_first")
        case .unavailable: L10n.text("common.teams.comment_save_failed")
        case .tooLong: L10n.text("common.teams.comment_too_long")
        }
    }
}

/// An attempt is durably recorded before sending. An uncertain attempt keeps
/// the original text, ID and time through navigation, relaunch and sign-in.
/// No draft is evicted. CAS also protects writing in another app window.
actor TeamCommentDraftStore {
    static let shared = TeamCommentDraftStore()
    private let directory: URL
    private static let mutex = NSLock()
    private static let limit = 128 * 1024
    struct Unsaved: Sendable { let text: String; let expected: TeamCommentDraft? }
    private var unsaved: [TeamCommentTarget: Unsaved] = [:]
    private struct Envelope: Codable { let version: Int; let target: TeamCommentTarget; let draft: TeamCommentDraft }

    init(directory: URL? = nil) {
        self.directory = directory ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("tokenstat-team-drafts", isDirectory: true)
    }
    func load(_ target: TeamCommentTarget) throws -> TeamCommentDraft? { try locked(target) { try read($0, target) } }
    func unsavedWriting(_ target: TeamCommentTarget) -> Unsaved? { unsaved[target] }
    func forgetUnsavedWriting(_ target: TeamCommentTarget) { unsaved[target] = nil }
    func save(_ target: TeamCommentTarget, text: String, expected: TeamCommentDraft?) throws -> TeamCommentDraft? {
        do {
            let result = try locked(target) { file in
                let current = try read(file, target)
                guard current == expected else { throw TeamCommentDraftFailure.changed }
                guard current?.attempt == nil else { throw TeamCommentDraftFailure.pending }
                if current?.text == text { return current }
                let next = text.isEmpty ? nil : TeamCommentDraft(revision: UUID(), text: text, attempt: nil)
                try write(next, file, target)
                return next
            }
            unsaved[target] = nil
            return result
        } catch {
            // A failed save still belongs to its original person and share.
            // Keep it in memory for returning views, including CAS conflicts.
            unsaved[target] = Unsaved(text: text, expected: expected)
            throw error
        }
    }
    func reserve(_ target: TeamCommentTarget, expected: TeamCommentDraft) throws -> TeamCommentDraft {
        try locked(target) { file in
            guard try read(file, target) == expected else { throw TeamCommentDraftFailure.changed }
            guard expected.canSend else { throw TeamCommentDraftFailure.tooLong }
            if expected.attempt != nil { return expected }
            let next = TeamCommentDraft(revision: UUID(), text: expected.text, attempt: .init(id: UUID().uuidString, createdAtMs: Int64(Date().timeIntervalSince1970 * 1000)))
            try write(next, file, target)
            return next
        }
    }
    func resolve(_ target: TeamCommentTarget, expected: TeamCommentDraft, state: TeamCommentReceipt.State) throws -> TeamCommentDraft? {
        try locked(target) { file in
            let current = try read(file, target)
            if current == nil, state == .accepted { return nil }
            guard current == expected else { throw TeamCommentDraftFailure.changed }
            let next: TeamCommentDraft?
            switch state {
            case .accepted: next = nil
            case .notAccepted: next = .init(revision: UUID(), text: expected.text, attempt: nil)
            case .pending, .unknown: return expected
            }
            try write(next, file, target)
            return next
        }
    }
    private func locked<T>(_ target: TeamCommentTarget, _ work: (URL) throws -> T) throws -> T {
        Self.mutex.lock(); defer { Self.mutex.unlock() }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let root = try directory.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        guard root.isDirectory == true, root.isSymbolicLink != true else { throw TeamCommentDraftFailure.unavailable }
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
        let descriptor = Darwin.open(directory.appendingPathComponent("drafts.lock").path, O_CREAT | O_RDWR | O_CLOEXEC | O_NOFOLLOW, 0o600)
        guard descriptor >= 0 else { throw TeamCommentDraftFailure.unavailable }
        defer { Darwin.close(descriptor) }
        var region = flock(); region.l_type = Int16(F_WRLCK); region.l_whence = Int16(SEEK_SET)
        // A stalled second app must not hold a Swift worker indefinitely.
        // Keep the unsaved copy and let the person retry a busy file.
        while Darwin.fcntl(descriptor, F_SETLK, &region) == -1 {
            guard errno == EINTR else { throw TeamCommentDraftFailure.unavailable }
        }
        let encoder = JSONEncoder(); encoder.outputFormatting = .sortedKeys
        let key = SHA256.hash(data: try encoder.encode(target)).map { String(format: "%02x", $0) }.joined()
        return try work(directory.appendingPathComponent(key + ".json"))
    }
    private func read(_ file: URL, _ target: TeamCommentTarget) throws -> TeamCommentDraft? {
        let descriptor = Darwin.open(file.path, O_RDONLY | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK)
        if descriptor < 0, errno == ENOENT { return nil }
        guard descriptor >= 0 else { throw TeamCommentDraftFailure.unavailable }
        defer { Darwin.close(descriptor) }
        var info = stat()
        guard fstat(descriptor, &info) == 0, info.st_mode & S_IFMT == S_IFREG, info.st_size <= Self.limit else { throw TeamCommentDraftFailure.unavailable }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: false)
        let data = try handle.read(upToCount: Self.limit + 1) ?? Data()
        guard data.count <= Self.limit else { throw TeamCommentDraftFailure.unavailable }
        let value = try JSONDecoder().decode(Envelope.self, from: data)
        guard value.version == 1, value.target == target, !value.draft.text.isEmpty,
              value.draft.attempt.map({ !$0.id.isEmpty && $0.id.utf8.count <= 128 && $0.createdAtMs > 0 }) ?? true else { throw TeamCommentDraftFailure.unavailable }
        return value.draft
    }
    private func write(_ draft: TeamCommentDraft?, _ file: URL, _ target: TeamCommentTarget) throws {
        if let draft {
            let data = try JSONEncoder().encode(Envelope(version: 1, target: target, draft: draft))
            guard data.count <= Self.limit else { throw TeamCommentDraftFailure.unavailable }
            #if os(macOS)
            try data.write(to: file, options: .atomic)
            #else
            try data.write(to: file, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
            #endif
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
            let handle = try FileHandle(forWritingTo: file); defer { try? handle.close() }
            try handle.synchronize()
        } else if FileManager.default.fileExists(atPath: file.path) { try FileManager.default.removeItem(at: file) }
        let descriptor = Darwin.open(directory.path, O_RDONLY | O_CLOEXEC)
        guard descriptor >= 0 else { throw TeamCommentDraftFailure.unavailable }
        defer { Darwin.close(descriptor) }
        guard Darwin.fsync(descriptor) == 0 else { throw TeamCommentDraftFailure.unavailable }
    }
}
