// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
import Foundation

/// Bounded, in-memory transcript rows. Rendering uses the same view tree as
/// live content; the caller keeps actions disabled until live state arrives.
struct ChatRecentMessages<Row> {
    private var entries: [String: [Row]] = [:]
    private var order: [String] = []
    static var conversationLimit: Int { 8 }
    static var messageLimit: Int { 150 }
    static var byteLimit: Int { 512 * 1024 }

    mutating func store(_ messages: [Row], for key: String, cost: (Row) -> Int) {
        var remaining = Self.byteLimit
        var kept: [Row] = []
        for message in messages.suffix(Self.messageLimit).reversed() {
            let bytes = max(0, cost(message))
            guard bytes <= remaining else { break }
            kept.append(message)
            remaining -= bytes
        }
        remove(key)
        guard !kept.isEmpty else { return }
        entries[key] = kept.reversed()
        order.append(key)
        while order.count > Self.conversationLimit { remove(order[0]) }
    }

    mutating func messages(for key: String) -> [Row] {
        guard let messages = entries[key] else { return [] }
        order.removeAll { $0 == key }
        order.append(key)
        return messages
    }

    mutating func remove(_ key: String) {
        entries[key] = nil
        order.removeAll { $0 == key }
    }

    mutating func retain(_ keys: Set<String>, in folder: String) {
        for key in order where key.hasPrefix(folder) && !keys.contains(key) { remove(key) }
    }

    mutating func removeAll() {
        entries.removeAll()
        order.removeAll()
    }
}
