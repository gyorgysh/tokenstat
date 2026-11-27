// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
import Foundation

struct ChatRecentMessages<Row> {
    private var entries: [String: [Row]] = [:]
    private var order: [String] = []
    private var speculative: Set<String> = []
    static var perFolderLimit: Int { 10 }
    static var conversationLimit: Int {
        #if os(iOS)
        24
        #else
        60
        #endif
    }
    static var messageLimit: Int { 600 }
    static var byteLimit: Int { 1024 * 1024 }

    mutating func store(_ messages: [Row], for key: String, speculative: Bool = false, cost: (Row) -> Int) {
        var remaining = Self.byteLimit
        var kept: [Row] = []
        for message in messages.suffix(Self.messageLimit).reversed() {
            let bytes = max(0, cost(message))
            guard bytes <= remaining else { break }
            kept.append(message)
            remaining -= bytes
        }
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

    func contains(_ key: String) -> Bool { entries[key] != nil }

    func peek(_ key: String) -> [Row] { entries[key] ?? [] }

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
