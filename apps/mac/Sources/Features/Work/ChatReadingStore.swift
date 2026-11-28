// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
import Foundation

struct ChatReadingMark: Codable, Equatable, Sendable {
    var eventID: String
    var offset: Double
    var within: Double
    var updatedAt: Date
    var revealTarget: Bool

    init(eventID: String, offset: Double, updatedAt: Date, within: Double = 0, revealTarget: Bool = false) {
        self.eventID = eventID
        self.offset = offset
        self.updatedAt = updatedAt
        self.within = within
        self.revealTarget = revealTarget
    }

    enum CodingKeys: String, CodingKey {
        case offset, updatedAt, within, revealTarget
        case eventID = "eventId"
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        eventID = try values.decode(String.self, forKey: .eventID)
        offset = try values.decode(Double.self, forKey: .offset)
        updatedAt = try values.decode(Date.self, forKey: .updatedAt)
        within = try values.decodeIfPresent(Double.self, forKey: .within) ?? 0
        revealTarget = try values.decodeIfPresent(Bool.self, forKey: .revealTarget) ?? false
    }

    func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(eventID, forKey: .eventID)
        try values.encode(offset, forKey: .offset)
        try values.encode(updatedAt, forKey: .updatedAt)
        try values.encode(within, forKey: .within)
        if revealTarget { try values.encode(true, forKey: .revealTarget) }
    }

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

@MainActor
final class ChatReadingStore {
    static let shared = ChatReadingStore()
    private let defaults: UserDefaults
    private let key = "chat.reading.v1"
    private let capacity = 300

    private struct Envelope: Codable {
        let version: Int
        var marks: [String: ChatReadingMark]
    }

    init(defaults: UserDefaults = .standard) { self.defaults = defaults }

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

    func hasRequest(for reference: WorkReference) -> Bool {
        guard let key = WorkReferenceKey.conversation(reference) else { return false }
        return requested?.key == key
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

    func remember(_ mark: ChatReadingMark, for reference: WorkReference) {
        guard let key = WorkReferenceKey.conversation(reference),
              ChatReadingMark.isStable(eventID: mark.eventID) else { return }
        var marks = read()
        guard marks[key] != mark else { return }
        marks[key] = mark
        write(marks)
    }

    func forget(for reference: WorkReference) {
        guard let key = WorkReferenceKey.conversation(reference) else { return }
        var marks = read()
        guard marks.removeValue(forKey: key) != nil else { return }
        write(marks)
    }

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
