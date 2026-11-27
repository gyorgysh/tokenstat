// SPDX-License-Identifier: LicenseRef-tokenstat-source-available

#if os(macOS)
import AppKit
#else
import UIKit
#endif
import Foundation
import Observation
import Darwin

struct ChatDraft: Codable, Equatable, Sendable {
    var reference: WorkReference
    var text: String
    var attachments: [ChatAttachment]
    var updatedAt: Date
    var messageID: String?

    /// Written in the same camelCase a host record uses, so this file and a
    /// draft that later travels between devices spell their keys one way.
    enum CodingKeys: String, CodingKey {
        case reference, text, attachments, updatedAt
        case messageID = "messageId"
    }

    var isEmpty: Bool {
        text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && attachments.isEmpty
    }
}

@MainActor @Observable
final class ChatDraftStore {
    static let shared = ChatDraftStore()

    private(set) var saveFailed = false

    private(set) var occupied: Set<String> = []

    @ObservationIgnored private var drafts: [String: ChatDraft] = [:]
    private let originalAccess: OriginalFileCoordination.Registration
    private let directory: URL
    private let file: URL
    private nonisolated static let queue = DispatchQueue(label: "ai.tokenstat.drafts", qos: .utility)
    @ObservationIgnored private let writer = Writer()
    @ObservationIgnored private var writeGeneration: UInt64 = 0
    private let byteLimit: Int
    private nonisolated static let maxFileBytes = 8 * 1024 * 1024

    init(directory: URL? = nil, byteLimit: Int = 8 * 1024 * 1024) {
        self.byteLimit = min(max(byteLimit, 1), Self.maxFileBytes)
        let base = directory ?? FileManager.default.urls(
            for: .applicationSupportDirectory, in: .userDomainMask
        )[0].appendingPathComponent("tokenstat-drafts", isDirectory: true)
        originalAccess = OriginalFileCoordination.Registration(directory: base)
        self.directory = base
        file = base.appendingPathComponent("drafts.v1.json")
        do {
            _ = try originalAccess.get()
            drafts = try Self.queue.sync { try Self.read(file, byteLimit: self.byteLimit) }
        } catch {
            saveFailed = true
        }
        occupied = Set(drafts.keys)
        #if os(macOS)
        let terminating = NSApplication.willTerminateNotification
        #else
        let terminating = UIApplication.willTerminateNotification
        #endif
        NotificationCenter.default.addObserver(
            forName: terminating, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.settle() }
        }
    }

    func settle() {
        saveFailed = Self.queue.sync { writer.failed } || (saveFailed && writeGeneration == 0)
    }


    func drafts(in scope: WorkReference.Scope) -> [ChatDraft] {
        drafts.values.filter { $0.reference.scope == scope }.sorted { $0.updatedAt > $1.updatedAt }
    }

    func protectedAttachments(in scope: WorkReference.Scope) throws -> [String: Set<String>] {
        let stored = try Self.queue.sync { try Self.read(file, byteLimit: byteLimit) }
        var result: [String: Set<String>] = [:]
        for draft in Array(drafts.values) + Array(stored.values) where draft.reference.scope == scope {
            guard let key = Self.key(draft.reference) else { continue }
            result[key, default: []].formUnion(draft.attachments.map(\.id))
        }
        return result
    }

    func referencedAttachmentIDs(for reference: WorkReference) throws -> Set<String> {
        guard let key = Self.key(reference) else { return [] }
        let stored = try Self.queue.sync { try Self.read(file, byteLimit: byteLimit) }
        return Set((drafts[key]?.attachments ?? []).map(\.id))
            .union((stored[key]?.attachments ?? []).map(\.id))
    }

    func draft(for reference: WorkReference) -> ChatDraft? {
        guard let key = Self.key(reference) else { return nil }
        return drafts[key]
    }

    func hasDraft(for reference: WorkReference) -> Bool {
        guard let key = Self.key(reference) else { return false }
        return occupied.contains(key)
    }


    func save(text: String, attachments: [ChatAttachment], for reference: WorkReference,
              at date: Date = Date(), newMessage: Bool = false) {
        guard (try? originalAccess.get()) != nil else { saveFailed = true; return }
        guard let key = Self.key(reference) else { return }
        let draft = ChatDraft(reference: reference,
                              text: text,
                              attachments: attachments, updatedAt: date,
                              messageID: newMessage ? UUID().uuidString : (drafts[key]?.messageID ?? UUID().uuidString))
        if draft.isEmpty {
            guard drafts.removeValue(forKey: key) != nil else { return }
            mark(key, occupied: false)
            flush(key: key, mutation: .remove)
            return
        }
        if !newMessage, let held = drafts[key], held.text == draft.text, held.attachments == draft.attachments {
            return
        }
        drafts[key] = draft
        mark(key, occupied: true)
        flush(key: key, mutation: .save(draft))
    }

    private func mark(_ key: String, occupied wanted: Bool) {
        guard occupied.contains(key) != wanted else { return }
        if wanted {
            occupied.insert(key)
        } else {
            occupied.remove(key)
        }
    }

    func clear(for reference: WorkReference) {
        guard let key = Self.key(reference), drafts.removeValue(forKey: key) != nil else { return }
        mark(key, occupied: false)
        flush(key: key, mutation: .remove)
    }

    func clear(_ expected: ChatDraft) {
        guard let key = Self.key(expected.reference), drafts[key] == expected else { return }
        drafts.removeValue(forKey: key)
        mark(key, occupied: false)
        flush(key: key, mutation: .removeIfMatches(expected))
    }

    func retryFailedSave() {
        flush()
    }


    private enum Mutation: Sendable {
        case save(ChatDraft)
        case remove
        case removeIfMatches(ChatDraft)
    }

    private final class Writer: @unchecked Sendable {
        var pending: [String: Mutation] = [:]
        var failed = false

        func flush(file: URL, directory: URL, byteLimit: Int) {
            do {
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                    attributes: [.posixPermissions: 0o700])
                let lock = Darwin.open(directory.appendingPathComponent("drafts.lock").path,
                                       O_CREAT | O_RDWR | O_CLOEXEC | O_NOFOLLOW, 0o600)
                guard lock >= 0 else { throw CocoaError(.fileWriteUnknown) }
                defer { Darwin.close(lock) }
                var region = flock()
                region.l_type = Int16(F_WRLCK)
                region.l_whence = Int16(SEEK_SET)
                while Darwin.fcntl(lock, F_SETLKW, &region) == -1 {
                    guard errno == EINTR else { throw CocoaError(.fileWriteUnknown) }
                }
                var merged = try ChatDraftStore.read(file, byteLimit: byteLimit)
                for (key, mutation) in pending {
                    switch mutation {
                    case let .save(draft): merged[key] = draft
                    case .remove: merged.removeValue(forKey: key)
                    case let .removeIfMatches(expected):
                        if merged[key] == expected { merged.removeValue(forKey: key) }
                    }
                }
                if !pending.isEmpty {
                    try ChatDraftStore.write(merged, to: file, in: directory, byteLimit: byteLimit)
                }
                pending.removeAll()
                failed = false
            } catch {
                failed = true
            }
        }
    }

    private func flush(key: String? = nil, mutation: Mutation? = nil) {
        writeGeneration &+= 1
        let generation = writeGeneration
        let writer = writer
        let file = file
        let directory = directory
        let byteLimit = byteLimit
        Self.queue.async {
            if let key, let mutation { writer.pending[key] = mutation }
            writer.flush(file: file, directory: directory, byteLimit: byteLimit)
            let failed = writer.failed
            Task { @MainActor in
                guard self.writeGeneration == generation else { return }
                self.saveFailed = failed
            }
        }
    }

    private enum StorageError: Error { case tooLarge, invalidRecord }

    private nonisolated static func read(_ file: URL, byteLimit: Int) throws -> [String: ChatDraft] {
        let handle: FileHandle
        do {
            handle = try FileHandle(forReadingFrom: file)
        } catch let error as CocoaError where error.code == .fileNoSuchFile || error.code == .fileReadNoSuchFile {
            guard !FileManager.default.fileExists(atPath: file.path) else { throw error }
            return [:]
        }
        defer { try? handle.close() }
        let data = try handle.read(upToCount: byteLimit + 1) ?? Data()
        guard data.count <= byteLimit else { throw StorageError.tooLarge }
        let stored = try JSONDecoder().decode([String: ChatDraft].self, from: data)
        guard stored.allSatisfy({ key($0.value.reference) == $0.key && !$0.value.isEmpty })
        else { throw StorageError.invalidRecord }
        return stored
    }

    private nonisolated static func write(
        _ drafts: [String: ChatDraft], to file: URL, in directory: URL, byteLimit: Int
    ) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700])
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
        if drafts.isEmpty {
            if FileManager.default.fileExists(atPath: file.path) {
                try FileManager.default.removeItem(at: file)
            }
            try synchronizeDirectory(directory)
            return
        }
        let data = try JSONEncoder().encode(drafts)
        guard data.count <= byteLimit else { throw StorageError.tooLarge }
        // Unsent writing is not reconstructible, so it is backed up like
        // the user data it is. On iOS it stays readable to a background
        // save after first unlock and unreadable to anything before it.
        #if os(macOS)
        try data.write(to: file, options: .atomic)
        #else
        try data.write(to: file, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        #endif
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
        let handle = try FileHandle(forWritingTo: file)
        defer { try? handle.close() }
        try handle.synchronize()
        try synchronizeDirectory(directory)
    }

    private nonisolated static func synchronizeDirectory(_ directory: URL) throws {
        let descriptor = Darwin.open(directory.path, O_RDONLY | O_CLOEXEC)
        guard descriptor >= 0 else { throw CocoaError(.fileWriteUnknown) }
        defer { Darwin.close(descriptor) }
        guard Darwin.fsync(descriptor) == 0 else { throw CocoaError(.fileWriteUnknown) }
    }

    private nonisolated static func key(_ reference: WorkReference) -> String? {
        WorkReferenceKey.conversation(reference)
    }
}
