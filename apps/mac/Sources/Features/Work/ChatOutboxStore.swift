// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
import Foundation
import Darwin

struct ChatQueuedMessage: Identifiable, Equatable, Codable, Sendable {
    enum Delivery: String, Codable, Sendable { case waiting, sending, deliveryUnknown, failed }
    var id: String
    var text: String
    var attachments: [ChatAttachment]
    var delivery: Delivery = .waiting
    /// Fixed at the first attempt, including retries of a refused send.
    var firstAttemptAt: Date? = nil
    var attemptedAt: Date? = nil
    var whenConnected = false
    var sourceDraftText: String? = nil

    var needsReceipt: Bool { delivery == .sending || delivery == .deliveryUnknown }
    var canEdit: Bool { !needsReceipt }
}

/// Queued messages are durable user writing, separate from reconstructible
/// caches. Each mutation merges into the current file while holding a process
/// lock; a window cannot publish its stale snapshot over another window's work.
@MainActor final class ChatOutboxStore {
    static let shared = ChatOutboxStore()
    static let capacity = 20
    private let directory: URL
    private let file: URL
    private let byteLimit: Int
    private var active: Set<String> = []

    struct Queue: Codable {
        let reference: WorkReference
        var items: [ChatQueuedMessage]
    }
    private struct Envelope: Codable {
        var version = 1
        var queues: [String: Queue] = [:]
    }
    enum Failure: Error { case invalid, full, unavailable, conflict }

    init(directory: URL? = nil, byteLimit: Int = 8 * 1024 * 1024) {
        self.directory = directory ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("tokenstat-drafts", isDirectory: true)
        file = self.directory.appendingPathComponent("outbox.v1.json")
        self.byteLimit = min(max(1, byteLimit), 8 * 1024 * 1024)
    }

    func items(for reference: WorkReference) throws -> [ChatQueuedMessage] {
        guard let key = WorkReferenceKey.conversation(reference) else { throw Failure.invalid }
        return try locked { try read().queues[key]?.items ?? [] }
    }

    func queues(in scope: WorkReference.Scope) throws -> [Queue] {
        try locked { try read().queues.values.filter { $0.reference.scope == scope } }
    }

    @discardableResult
    func update(_ reference: WorkReference, _ mutation: (inout [ChatQueuedMessage]) throws -> Void) throws -> [ChatQueuedMessage] {
        guard let key = WorkReferenceKey.conversation(reference) else { throw Failure.invalid }
        return try locked {
            var envelope = try read()
            var items = envelope.queues[key]?.items ?? []
            let original = items
            try mutation(&items)
            guard items != original else { return items }
            guard items.count <= Self.capacity else { throw Failure.full }
            guard Set(items.map(\.id)).count == items.count,
                  items.allSatisfy({ !$0.id.isEmpty && $0.id.utf8.count <= 256 }) else { throw Failure.invalid }
            if items.isEmpty { envelope.queues.removeValue(forKey: key) }
            else {
                var root = reference
                root.anchor = nil
                envelope.queues[key] = Queue(reference: root, items: items)
            }
            let data = try JSONEncoder().encode(envelope)
            guard data.count <= byteLimit else { throw Failure.full }
            #if os(macOS)
            try data.write(to: file, options: .atomic)
            #else
            try data.write(to: file, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
            #endif
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
            let handle = try FileHandle(forWritingTo: file)
            defer { try? handle.close() }
            try handle.synchronize()
            let parent = Darwin.open(directory.path, O_RDONLY)
            guard parent >= 0 else { throw Failure.unavailable }
            defer { Darwin.close(parent) }
            guard Darwin.fsync(parent) == 0 else { throw Failure.unavailable }
            return items
        }
    }

    /// One active send per conversation across this process's windows. The
    /// persisted sending state survives a process exit and needs a receipt.
    func beginDelivery(_ reference: WorkReference) -> Bool {
        guard let key = WorkReferenceKey.conversation(reference) else { return false }
        return active.insert(key).inserted
    }
    func endDelivery(_ reference: WorkReference) {
        if let key = WorkReferenceKey.conversation(reference) { active.remove(key) }
    }

    private func read() throws -> Envelope {
        guard FileManager.default.fileExists(atPath: file.path) else { return Envelope() }
        let handle = try FileHandle(forReadingFrom: file)
        defer { try? handle.close() }
        let data = try handle.read(upToCount: byteLimit + 1) ?? Data()
        guard data.count <= byteLimit else { throw Failure.full }
        let envelope = try JSONDecoder().decode(Envelope.self, from: data)
        guard envelope.version == 1, envelope.queues.allSatisfy({ key, queue in
            WorkReferenceKey.conversation(queue.reference) == key && queue.items.count <= Self.capacity
                && Set(queue.items.map(\.id)).count == queue.items.count
                && queue.items.allSatisfy { !$0.id.isEmpty && $0.id.utf8.count <= 256 }
        }) else { throw Failure.invalid }
        return envelope
    }

    private func locked<T>(_ work: () throws -> T) throws -> T {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                               attributes: [.posixPermissions: 0o700])
        let lock = Darwin.open(directory.appendingPathComponent("outbox.lock").path, O_CREAT | O_RDWR, 0o600)
        guard lock >= 0 else { throw Failure.unavailable }
        defer { Darwin.close(lock) }
        var region = flock()
        region.l_type = Int16(F_WRLCK)
        region.l_whence = Int16(SEEK_SET)
        guard Darwin.fcntl(lock, F_SETLKW, &region) != -1 else { throw Failure.unavailable }
        // Closing this descriptor releases the advisory write lock.
        return try work()
    }
}
