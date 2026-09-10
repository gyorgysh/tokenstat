// SPDX-License-Identifier: LicenseRef-tokenstat-source-available

#if os(macOS)
import AppKit
#else
import UIKit
#endif
import Foundation
import Observation

/// A message somebody started writing and has not sent.
///
/// Text they typed, and the files they attached to it. Both belong to one
/// conversation on one machine, which is what the reference carries.
struct ChatDraft: Codable, Equatable, Sendable {
    var reference: WorkReference
    var text: String
    var attachments: [ChatAttachment]
    var updatedAt: Date
    /// The name these words travel under when they are sent.
    ///
    /// Minted once per draft and kept for as long as the draft exists, which
    /// is what makes sending again safe: a machine that has already taken a
    /// message under this name answers instead of running the agent twice.
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

/// Unsent words are the person's own writing, so they are kept the way user
/// data is kept, not the way a cache is kept.
///
/// A cache may be thrown away to make room. This may not: nothing evicts a
/// draft to free space, and the only things that remove one are sending it,
/// or explicitly clearing it. It lives in a file rather than in
/// preferences because preferences are a plist that any process with the
/// container can read, have no file protection on iOS, and are the wrong
/// place for prose.
///
/// Reads are answered from memory so a list can ask "does this conversation
/// have a draft" per row. Writes go to one serial queue, which reads the file
/// back before merging a single key into it, so two windows editing different
/// conversations cannot overwrite each other.
@MainActor @Observable
final class ChatDraftStore {
    static let shared = ChatDraftStore()

    /// The last write failed, and the words on screen are the only copy.
    /// The composer says so and offers to try again rather than claiming
    /// a save that did not happen.
    private(set) var saveFailed = false

    /// The conversations holding unsent words, as storage keys.
    ///
    /// Separate from the drafts themselves so a list that marks them is
    /// invalidated when a draft appears or goes, and not on every keystroke
    /// of one that is already marked.
    private(set) var occupied: Set<String> = []

    @ObservationIgnored private var drafts: [String: ChatDraft] = [:]
    private let originalAccess: OriginalFileCoordination.Registration
    private let directory: URL
    private let file: URL
    private nonisolated static let queue = DispatchQueue(label: "ai.tokenstat.drafts", qos: .utility)
    @ObservationIgnored private let writer = Writer()
    @ObservationIgnored private var writeGeneration: UInt64 = 0
    private let byteLimit: Int
    /// Enough for a long message with a few files named beside it, and small
    /// enough that a corrupt or hostile file cannot be read into memory.
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
        // A save is queued, not awaited, so quitting a second after the last
        // keystroke could otherwise leave the write unmade.
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

    /// Wait for the queued writes to reach the disk.
    func settle() {
        saveFailed = Self.queue.sync { writer.failed } || (saveFailed && writeGeneration == 0)
    }

    // MARK: - Reading

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

    /// Protect both current in-memory writing and the latest persisted copy
    /// when reviewing retained original files for explicit removal.
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

    /// Whether one conversation is holding unsent words.
    ///
    /// A key lookup rather than a list, and asked by the mark itself rather
    /// than by the screen that lists the conversations. Reading `occupied`
    /// registers whoever reads it as an observer of every draft coming and
    /// going, and a screen that does that is a screen laid out again for a
    /// mark on one of its rows.
    func hasDraft(for reference: WorkReference) -> Bool {
        guard let key = Self.key(reference) else { return false }
        return occupied.contains(key)
    }

    // MARK: - Writing

    /// Keep this conversation's unsent words. An empty draft removes the
    /// record rather than storing emptiness.
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
        // The time is not part of "has this changed": a save with the same
        // words in it is not a save.
        if !newMessage, let held = drafts[key], held.text == draft.text, held.attachments == draft.attachments {
            return
        }
        drafts[key] = draft
        mark(key, occupied: true)
        flush(key: key, mutation: .save(draft))
    }

    /// Touch `occupied` only when membership actually changes.
    ///
    /// Assigning a stored property the value it already has does not notify,
    /// but a set mutated in place cannot be compared and notifies every time.
    /// A conversation that is already marked was being re-marked on every
    /// keystroke pause, and everything observing the set was laid out again
    /// for a mark that had not moved. `ChatDraftStoreTests` pins this.
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

    /// Acceptance may arrive after this draft was edited in another window.
    /// Remove only the exact submitted record, including on the writer queue.
    func clear(_ expected: ChatDraft) {
        guard let key = Self.key(expected.reference), drafts[key] == expected else { return }
        drafts.removeValue(forKey: key)
        mark(key, occupied: false)
        flush(key: key, mutation: .removeIfMatches(expected))
    }

    /// Try the failed write again with what is on screen now.
    func retryFailedSave() {
        flush()
    }

    // MARK: - Storage

    private enum Mutation: Sendable {
        case save(ChatDraft)
        case remove
        case removeIfMatches(ChatDraft)
    }

    /// Accessed only on the shared serial queue. Failed changes stay pending,
    /// including deletions, until a complete atomic write succeeds.
    private final class Writer: @unchecked Sendable {
        var pending: [String: Mutation] = [:]
        var failed = false

        func flush(file: URL, directory: URL, byteLimit: Int) {
            do {
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

    /// Merge only edits from this store. Rewriting an old in-memory snapshot
    /// would resurrect a draft another window cleared or replace its edits.
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

    /// A missing file is empty. An unreadable or damaged file is an error,
    /// so saving cannot overwrite writing we were unable to recover.
    private nonisolated static func read(_ file: URL, byteLimit: Int) throws -> [String: ChatDraft] {
        let handle: FileHandle
        do {
            handle = try FileHandle(forReadingFrom: file)
        } catch let error as CocoaError where error.code == .fileNoSuchFile || error.code == .fileReadNoSuchFile {
            // FileHandle can report a directory as missing. It must never
            // become an empty draft store that a later write removes.
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
    }

    /// One conversation on one machine under one account, in the name every
    /// per-conversation store on this device files things under.
    private nonisolated static func key(_ reference: WorkReference) -> String? {
        WorkReferenceKey.conversation(reference)
    }
}
