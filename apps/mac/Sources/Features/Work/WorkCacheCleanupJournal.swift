// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
import Foundation
import Darwin

/// Durable sign-out intent contains only cache ownership, never keys, query
/// text or draft data. Unfinished cleanup is retried after a verified account
/// answer, including after an app restart.
@MainActor final class WorkCacheCleanupJournal {
    static let shared = WorkCacheCleanupJournal()
    private struct Entry: Codable, Equatable {
        let id: UUID
        let scope: String
        var confirmed: Bool
    }
    private struct Journal: Codable { var version = 1; var entries: [Entry] = [] }
    private let file: URL
    private var active: Set<String> = []
    private nonisolated static var defaultFile: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("tokenstat-work-cleanup/journal.v1.json")
    }
    init(file: URL? = nil) { self.file = file ?? Self.defaultFile }

    /// A pending cleanup cannot be made readable again through a saved page
    /// or recreate a key while a deletion is waiting on local transport I/O.
    nonisolated static func blocks(_ scope: String, file: URL? = nil) -> Bool {
        let file = file ?? defaultFile
        guard FileManager.default.fileExists(atPath: file.path) else { return false }
        guard let journal = try? read(file) else { return true }
        return journal.entries.contains { $0.scope == scope }
    }
    func prepare(scope: String) throws {
        var journal = try Self.read(file)
        journal.entries.removeAll { $0.scope == scope }
        journal.entries.append(Entry(id: UUID(), scope: scope, confirmed: false))
        try write(journal)
    }
    func confirm(scope: String) throws {
        var journal = try Self.read(file)
        guard let index = journal.entries.firstIndex(where: { $0.scope == scope }) else { return }
        journal.entries[index].confirmed = true
        try write(journal)
    }
    func pendingScopes() throws -> Set<String> { Set(try Self.read(file).entries.map(\.scope)) }

    func recover(verifiedScope: String?, accountKnown: Bool,
                 stillValid: () -> Bool = { true },
                 deleteKey: (String) -> Bool,
                 clear: (String) async throws -> Void) async {
        guard accountKnown, stillValid(), let journal = try? Self.read(file) else { return }
        for entry in journal.entries {
            guard stillValid() else { return }
            guard !active.contains(entry.scope) else { continue }
            // A fresh answer still identifies the original signed-in account:
            // an unconfirmed sign-out did not establish a cleanup boundary.
            if entry.scope == verifiedScope && !entry.confirmed {
                try? remove(entry)
                continue
            }
            active.insert(entry.scope)
            // Destroy the key before the first suspension. Failure keeps the
            // journal and blocks reads until the keychain becomes available.
            guard deleteKey(entry.scope) else { active.remove(entry.scope); continue }
            do {
                try await clear(entry.scope)
                try remove(entry)
            } catch { /* The durable entry makes the next recovery retry. */ }
            active.remove(entry.scope)
        }
    }
    private func remove(_ entry: Entry) throws {
        var journal = try Self.read(file)
        journal.entries.removeAll { $0 == entry }
        try write(journal)
    }
    private nonisolated static func read(_ file: URL) throws -> Journal {
        guard FileManager.default.fileExists(atPath: file.path) else { return Journal() }
        let handle = try FileHandle(forReadingFrom: file)
        defer { try? handle.close() }
        let data = try handle.read(upToCount: 262_145) ?? Data()
        guard data.count <= 262_144 else { throw CocoaError(.fileReadTooLarge) }
        let journal = try JSONDecoder().decode(Journal.self, from: data)
        guard journal.version == 1, journal.entries.count <= 256,
              Set(journal.entries.map(\.scope)).count == journal.entries.count,
              journal.entries.allSatisfy({ !$0.scope.isEmpty && $0.scope.utf8.count <= 4096 }) else { throw CocoaError(.fileReadCorruptFile) }
        return journal
    }
    private func write(_ journal: Journal) throws {
        let data = try JSONEncoder().encode(journal)
        guard data.count <= 262_144, journal.entries.count <= 256,
              journal.entries.allSatisfy({ !$0.scope.isEmpty && $0.scope.utf8.count <= 4096 }) else { throw CocoaError(.fileWriteOutOfSpace) }
        let directory = file.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
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
        guard parent >= 0 else { throw CocoaError(.fileWriteUnknown) }
        defer { Darwin.close(parent) }
        guard Darwin.fsync(parent) == 0 else { throw CocoaError(.fileWriteUnknown) }
    }
}
