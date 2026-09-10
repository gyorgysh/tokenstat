// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
import Foundation

/// Where somebody had got to in a conversation they were not at the end of.
///
/// A row and how far down the viewport it sat, never a pixel offset into the
/// content: the same conversation is a different height on a phone, at a
/// larger text size, or with an older page loaded above it. The row is the
/// host's own name for that record, so it means the same thing tomorrow.
struct ChatReadingMark: Codable, Equatable, Sendable {
    /// The row that was at the top of the viewport.
    var eventID: String
    /// Its top edge, as a fraction of the viewport's height. Zero is a row
    /// resting against the top edge.
    var offset: Double
    /// How far down the row itself the reader was, as a fraction of the
    /// row's height. Zero is the row's top edge showing. Above zero means
    /// the row's top had scrolled past the viewport's top edge: a long
    /// message the reader is halfway down reopens in its middle rather
    /// than at its first line. A fraction, not points, because the same
    /// row is a different height on a phone or at a larger text size.
    /// Older records carry no value and read as zero.
    var within: Double
    var updatedAt: Date

    init(eventID: String, offset: Double, updatedAt: Date, within: Double = 0) {
        self.eventID = eventID
        self.offset = offset
        self.updatedAt = updatedAt
        self.within = within
    }

    enum CodingKeys: String, CodingKey {
        case offset, updatedAt, within
        case eventID = "eventId"
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        eventID = try values.decode(String.self, forKey: .eventID)
        offset = try values.decode(Double.self, forKey: .offset)
        updatedAt = try values.decode(Date.self, forKey: .updatedAt)
        within = try values.decodeIfPresent(Double.self, forKey: .within) ?? 0
    }

    func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(eventID, forKey: .eventID)
        try values.encode(offset, forKey: .offset)
        try values.encode(updatedAt, forKey: .updatedAt)
        try values.encode(within, forKey: .within)
    }

    /// Whether a row's name will still mean this row after a relaunch.
    ///
    /// The host names a record by where it starts in the archive, which is
    /// fixed for that record's life. A row the host did not name falls back
    /// to its position in the page that was loaded, and the next launch pages
    /// differently, so remembering one of those would send somebody back to
    /// a place that is no longer there.
    static func isStable(eventID: String) -> Bool {
        let parts = eventID.split(separator: "-", omittingEmptySubsequences: false)
        let stamp: Substring
        if parts.count == 1 {
            stamp = parts[0]
        } else if parts.count == 2,
                  ["user", "text", "think", "handoff", "turn", "usage", "failed", "tool", "edit"]
                    .contains(String(parts[0])) {
            stamp = parts[1]
        } else {
            return false
        }
        return stamp.first == "s" && stamp.count > 1
            && stamp.dropFirst().utf8.allSatisfy { (48...57).contains($0) }
    }
}

/// The reading position of every conversation this device has been left in
/// the middle of.
///
/// Device-local and identifiers only. Being at the end of a conversation is
/// the ordinary case and is stored as nothing at all: a record exists exactly
/// when reopening should land somewhere other than the latest turn.
@MainActor
final class ChatReadingStore {
    static let shared = ChatReadingStore()
    private let defaults: UserDefaults
    private let key = "chat.reading.v1"
    /// Enough conversations that a week of reading fits, small enough that
    /// the record stays a preference rather than a database.
    private let capacity = 300

    private struct Envelope: Codable {
        let version: Int
        var marks: [String: ChatReadingMark]
    }

    init(defaults: UserDefaults = .standard) { self.defaults = defaults }

    /// One explicit navigation request, separate from passive reading history.
    /// Ordinary conversation selection always starts at the latest page.
    private var requested: (key: String, mark: ChatReadingMark)?

    func request(_ mark: ChatReadingMark, for reference: WorkReference) {
        guard let key = WorkReferenceKey.conversation(reference),
              ChatReadingMark.isStable(eventID: mark.eventID) else { return }
        remember(mark, for: reference)
        requested = (key, mark)
    }

    func requestLatest(for reference: WorkReference) {
        if requested?.key == WorkReferenceKey.conversation(reference) { requested = nil }
        forget(for: reference)
    }

    func takeRequest(for reference: WorkReference) -> ChatReadingMark? {
        guard let key = WorkReferenceKey.conversation(reference), requested?.key == key else { return nil }
        defer { requested = nil }
        return requested?.mark
    }

    func mark(for reference: WorkReference) -> ChatReadingMark? {
        guard let key = WorkReferenceKey.conversation(reference) else { return nil }
        return read()[key]
    }

    /// Remember where the reading is. A row whose name will not survive a
    /// relaunch is not remembered at all.
    func remember(_ mark: ChatReadingMark, for reference: WorkReference) {
        guard let key = WorkReferenceKey.conversation(reference),
              ChatReadingMark.isStable(eventID: mark.eventID) else { return }
        var marks = read()
        guard marks[key] != mark else { return }
        marks[key] = mark
        write(marks)
    }

    /// Back with the latest turn, which is where a conversation opens anyway.
    func forget(for reference: WorkReference) {
        guard let key = WorkReferenceKey.conversation(reference) else { return }
        var marks = read()
        guard marks.removeValue(forKey: key) != nil else { return }
        write(marks)
    }

    /// Everything under one folder, for a conversation list that has lost its
    /// folder, and one account's worth for a sign-out.
    func remove(scope: WorkReference.Scope, hostIdentity: String, workspaceID: String) {
        let prefix = WorkReferenceKey.folder(scope: scope, hostIdentity: hostIdentity,
                                             workspaceID: workspaceID)
        if requested?.key.hasPrefix(prefix) == true { requested = nil }
        let marks = read().filter { !$0.key.hasPrefix(prefix) }
        write(marks)
    }

    func remove(scope: WorkReference.Scope) {
        let prefix = [scope.kind.rawValue, scope.origin, scope.identity]
            .map(WorkReferenceKey.encode).joined(separator: "|") + "|"
        if requested?.key.hasPrefix(prefix) == true { requested = nil }
        write(read().filter { !$0.key.hasPrefix(prefix) })
    }

    /// Reread on every write, so two windows reading two conversations do not
    /// overwrite each other's places.
    private func read() -> [String: ChatReadingMark] {
        guard let data = defaults.data(forKey: key), data.count <= 512 * 1024,
              let stored = try? JSONDecoder().decode(Envelope.self, from: data),
              stored.version == 1 else { return [:] }
        return stored.marks
    }

    private func write(_ marks: [String: ChatReadingMark]) {
        var kept = marks
        if kept.count > capacity {
            let newest = kept.sorted { $0.value.updatedAt > $1.value.updatedAt }.prefix(capacity)
            kept = Dictionary(uniqueKeysWithValues: newest.map { ($0.key, $0.value) })
        }
        guard let data = try? JSONEncoder().encode(Envelope(version: 1, marks: kept)) else { return }
        defaults.set(data, forKey: key)
    }
}
