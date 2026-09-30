// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
import Foundation

/// Bounded, in-memory transcript rows. Rendering uses the same view tree as
/// live content; the caller keeps actions disabled until live state arrives.
struct ChatRecentMessages<Row> {
    private var entries: [String: [Row]] = [:]
    private var order: [String] = []
    /// Read ahead, not opened. Prefer dropping these when a project is full.
    private var speculative: Set<String> = []
    /// Ten warm conversations per project: the whole loop set.
    /// Counted per project, because one shared ten meant browsing a second
    /// project pushed the first one's chats out, and coming back reloaded.
    static var perFolderLimit: Int { 10 }
    /// Across every project, so a long session cannot grow without bound.
    /// Each conversation is capped by `byteLimit`, so this is about 30 MB.
    static var conversationLimit: Int { 60 }
    static var messageLimit: Int { 150 }
    static var byteLimit: Int { 512 * 1024 }

    mutating func store(_ messages: [Row], for key: String, speculative: Bool = false, cost: (Row) -> Int) {
        var remaining = Self.byteLimit
        var kept: [Row] = []
        for message in messages.suffix(Self.messageLimit).reversed() {
            let bytes = max(0, cost(message))
            guard bytes <= remaining else { break }
            kept.append(message)
            remaining -= bytes
        }
        // Nothing to keep leaves an earlier copy alone. A chat left before
        // its page arrived would otherwise erase the warm copy it opened on.
        guard !kept.isEmpty else { return }
        remove(key)
        entries[key] = kept.reversed()
        order.append(key)
        if speculative { self.speculative.insert(key) }
        let folder = Self.folder(of: key)
        var sameFolder = order.filter { Self.folder(of: $0) == folder }
        while sameFolder.count > Self.perFolderLimit {
            let victim = sameFolder.first { self.speculative.contains($0) && $0 != key } ?? sameFolder[0]
            remove(victim)
            sameFolder.removeAll { $0 == victim }
        }
        while order.count > Self.conversationLimit {
            remove(order.first { self.speculative.contains($0) && $0 != key } ?? order[0])
        }
    }

    /// Whether a conversation is held, without counting as a use of it.
    /// A warm-up asking this for every chat in a project must not make
    /// those chats look more recent than the one somebody just left.
    func contains(_ key: String) -> Bool { entries[key] != nil }

    /// The rows, without counting as a use.
    func peek(_ key: String) -> [Row] { entries[key] ?? [] }

    /// The project part of a key: everything up to its last separator. Ids
    /// are percent-encoded, so a separator never appears inside one.
    private static func folder(of key: String) -> Substring {
        guard let bar = key.lastIndex(of: "|") else { return key[key.startIndex..<key.startIndex] }
        return key[...bar]
    }

    mutating func messages(for key: String) -> [Row] {
        guard let messages = entries[key] else { return [] }
        order.removeAll { $0 == key }
        order.append(key)
        speculative.remove(key)
        return messages
    }

    mutating func remove(_ key: String) {
        entries[key] = nil
        order.removeAll { $0 == key }
        speculative.remove(key)
    }

    mutating func retain(_ keys: Set<String>, in folder: String) {
        for key in order where key.hasPrefix(folder) && !keys.contains(key) { remove(key) }
    }

    mutating func removeAll() {
        entries.removeAll()
        order.removeAll()
        speculative.removeAll()
    }
}
