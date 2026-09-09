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
/// clearing it and signing the account out. It lives in a file rather than in
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
    private let directory: URL
    private let file: URL
    private let queue = DispatchQueue(label: "ai.tokenstat.drafts", qos: .utility)
    /// Enough for a long message with a few files named beside it, and small
    /// enough that a corrupt or hostile file cannot be read into memory.
    private nonisolated static let maxFileBytes = 8 * 1024 * 1024
    private static let maxDraftCharacters = 200_000
    /// Old drafts are still somebody's writing, so the bound is generous and
    /// the oldest go first only once there are more than a person could have
    /// meant to keep.
    private nonisolated static let capacity = 400

    init(directory: URL? = nil) {
        let base = directory ?? FileManager.default.urls(
            for: .applicationSupportDirectory, in: .userDomainMask
        )[0].appendingPathComponent("tokenstat-drafts", isDirectory: true)
        self.directory = base
        file = base.appendingPathComponent("drafts.v1.json")
        drafts = Self.read(file)
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
        queue.sync {}
    }

    // MARK: - Reading

    func draft(for reference: WorkReference) -> ChatDraft? {
        guard let key = Self.key(reference) else { return nil }
        return drafts[key]
    }

    /// Which conversations in one folder have unsent words, so a list can
    /// mark them without reading a single draft.
    func conversationsWithDrafts(
        scope: WorkReference.Scope, hostIdentity: String, workspaceID: String
    ) -> Set<String> {
        guard !hostIdentity.isEmpty, !workspaceID.isEmpty else { return [] }
        let prefix = Self.folderPrefix(scope: scope, hostIdentity: hostIdentity,
                                       workspaceID: workspaceID)
        var found: Set<String> = []
        for key in occupied where key.hasPrefix(prefix) {
            let item = key.dropFirst(prefix.count)
            guard !item.isEmpty, !item.contains("|"),
                  let decoded = item.removingPercentEncoding, !decoded.isEmpty
            else { continue }
            found.insert(decoded)
        }
        return found
    }

    // MARK: - Writing

    /// Keep this conversation's unsent words. An empty draft removes the
    /// record rather than storing emptiness.
    func save(text: String, attachments: [ChatAttachment], for reference: WorkReference,
              at date: Date = Date()) {
        guard let key = Self.key(reference) else { return }
        let draft = ChatDraft(reference: reference,
                              text: String(text.prefix(Self.maxDraftCharacters)),
                              attachments: attachments, updatedAt: date,
                              messageID: drafts[key]?.messageID ?? UUID().uuidString)
        if draft.isEmpty {
            guard drafts.removeValue(forKey: key) != nil else { return }
            occupied.remove(key)
            flush(removing: [key])
            return
        }
        // The time is not part of "has this changed": a save with the same
        // words in it is not a save.
        if let held = drafts[key], held.text == draft.text, held.attachments == draft.attachments {
            return
        }
        drafts[key] = draft
        occupied.insert(key)
        flush()
    }

    func clear(for reference: WorkReference) {
        guard let key = Self.key(reference), drafts.removeValue(forKey: key) != nil else { return }
        occupied.remove(key)
        flush(removing: [key])
    }

    /// Try the failed write again with what is on screen now.
    func retryFailedSave() {
        saveFailed = false
        flush()
    }

    // MARK: - Storage

    /// Write what is in memory, plus whatever the file holds for windows and
    /// builds this one knows nothing about, minus the keys just removed.
    private func flush(removing doomed: Set<String> = []) {
        let snapshot = drafts
        let directory = directory
        let file = file
        queue.async {
            var merged = Self.read(file).filter { !doomed.contains($0.key) }
            for (key, value) in snapshot { merged[key] = value }
            if merged.count > Self.capacity {
                let keep = merged.sorted { $0.value.updatedAt > $1.value.updatedAt }
                    .prefix(Self.capacity)
                merged = Dictionary(uniqueKeysWithValues: keep.map { ($0.key, $0.value) })
            }
            let ok = Self.write(merged, to: file, in: directory)
            Task { @MainActor in self.saveFailed = !ok }
        }
    }

    private nonisolated static func read(_ file: URL) -> [String: ChatDraft] {
        guard let data = try? Data(contentsOf: file), data.count <= maxFileBytes,
              let stored = try? JSONDecoder().decode([String: ChatDraft].self, from: data)
        else { return [:] }
        return stored.filter { key($0.value.reference) == $0.key && !$0.value.isEmpty }
    }

    private nonisolated static func write(
        _ drafts: [String: ChatDraft], to file: URL, in directory: URL
    ) -> Bool {
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700])
            if drafts.isEmpty {
                if FileManager.default.fileExists(atPath: file.path) {
                    try FileManager.default.removeItem(at: file)
                }
                return true
            }
            let data = try JSONEncoder().encode(drafts)
            // Unsent writing is not reconstructible, so it is backed up like
            // the user data it is. On iOS it stays readable to a background
            // save after first unlock and unreadable to anything before it.
            #if os(macOS)
            try data.write(to: file, options: .atomic)
            #else
            try data.write(to: file, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
            #endif
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
            return true
        } catch {
            return false
        }
    }

    /// One conversation on one machine under one account. Every part is an
    /// identifier, percent-encoded so the separator cannot occur inside one.
    private nonisolated static func key(_ reference: WorkReference) -> String? {
        guard reference.kind == .conversation, let item = reference.itemID, !item.isEmpty,
              !reference.hostIdentity.isEmpty, !reference.workspaceID.isEmpty
        else { return nil }
        return folderPrefix(scope: reference.scope, hostIdentity: reference.hostIdentity,
                            workspaceID: reference.workspaceID) + encode(item)
    }

    /// Everything above the conversation, ending in the separator, so one
    /// folder's keys are exactly the keys carrying this prefix.
    private nonisolated static func folderPrefix(
        scope: WorkReference.Scope, hostIdentity: String, workspaceID: String
    ) -> String {
        [scope.kind.rawValue, scope.origin, scope.identity, hostIdentity, workspaceID]
            .map(encode).joined(separator: "|") + "|"
    }

    private nonisolated static func encode(_ value: String) -> String {
        value.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? ""
    }
}
