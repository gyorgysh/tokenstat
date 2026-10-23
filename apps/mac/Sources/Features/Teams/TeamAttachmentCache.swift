// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
import Foundation

/// Downloaded attachments are a viewing cache, never an archive. Bound both
/// retained bytes and entry count, and retire files when their rows leave.
struct TeamAttachmentCache<Value> {
    private struct Entry { let value: Value; let bytes: Int }
    private var entries: [String: Entry] = [:]
    private var order: [String] = []
    private(set) var byteCount = 0
    let byteLimit: Int
    let entryLimit: Int

    init(byteLimit: Int, entryLimit: Int = 16) {
        precondition(byteLimit > 0 && entryLimit > 0)
        self.byteLimit = byteLimit; self.entryLimit = entryLimit
    }
    subscript(id: String) -> Value? { entries[id]?.value }
    @discardableResult mutating func insert(_ value: Value, id: String, bytes: Int) -> Bool {
        guard bytes >= 0 && bytes <= byteLimit else { return false }
        remove(id)
        while order.count >= entryLimit || byteCount > byteLimit - bytes {
            remove(order[0])
        }
        entries[id] = Entry(value: value, bytes: bytes); order.append(id); byteCount += bytes
        return true
    }
    mutating func retain(_ visible: Set<String>) {
        for id in order where !visible.contains(id) { remove(id) }
    }
    private mutating func remove(_ id: String) {
        if let old = entries.removeValue(forKey: id) { byteCount -= old.bytes }
        order.removeAll { $0 == id }
    }
}

enum TeamAttachmentLimits {
    static let maximumBytes = 5 * 1024 * 1024
    static func decode(_ encoded: String, size: Int64?) -> Data? {
        guard let size, size >= 0, size <= maximumBytes, encoded.utf8.count <= 8 * 1024 * 1024,
              let bytes = Data(base64Encoded: encoded), bytes.count == size, bytes.count <= maximumBytes else { return nil }
        return bytes
    }
}
