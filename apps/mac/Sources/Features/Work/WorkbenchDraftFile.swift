// SPDX-License-Identifier: LicenseRef-tokenstat-source-available

import CryptoKit
import Darwin
import Foundation

private enum WorkbenchDraftIO {
    static let mutex = NSLock()
}

/// Original writing stays in protected, backed-up files. Each target has its
/// own file and revision, so another app instance cannot silently overwrite it.
actor WorkbenchDraftFile<Value: Codable & Sendable & Equatable> {
    struct Record: Codable, Sendable {
        let revision: String
        let value: Value
    }
    enum Failure: LocalizedError {
        case changed, tooLarge, unavailable
        var errorDescription: String? {
            switch self {
            case .changed: L10n.text("apple.workbenchdraftfile.this_draft_changed_in_another_window_your.631f32ab")
            case .tooLarge: L10n.text("apple.workbenchdraftfile.this_draft_is_too_large_to_save_on_this_de.1920c688")
            case .unavailable: L10n.text("apple.workbenchdraftfile.this_draft_could_not_be_saved_on_this_devi.bf2381df")
            }
        }
    }

    private let file: URL
    private let directory: URL
    private let access: OriginalFileCoordination.Registration
    private let limit: Int

    init(key: String, directory: URL? = nil, maximumBytes: Int = 2 * 1024 * 1024) {
        limit = maximumBytes
        let root = directory ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("tokenstat-workbench-drafts", isDirectory: true)
        self.directory = root
        access = OriginalFileCoordination.Registration(directory: root)
        let name = SHA256.hash(data: Data(key.utf8)).map { String(format: "%02x", $0) }.joined()
        file = root.appendingPathComponent(name + ".json")
    }

    func load() throws -> Record? {
        _ = try access.get()
        return try read()
    }

    func save(_ value: Value, expectedRevision: String?) throws -> Record {
        WorkbenchDraftIO.mutex.lock()
        defer { WorkbenchDraftIO.mutex.unlock() }
        _ = try access.get()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        let lock = Darwin.open(file.appendingPathExtension("lock").path, O_CREAT | O_RDWR | O_CLOEXEC | O_NOFOLLOW, 0o600)
        guard lock >= 0 else { throw Failure.unavailable }
        defer { Darwin.close(lock) }
        var region = flock()
        region.l_type = Int16(F_WRLCK)
        region.l_whence = Int16(SEEK_SET)
        while fcntl(lock, F_SETLKW, &region) != 0 {
            guard errno == EINTR else { throw Failure.unavailable }
        }
        let current = try read()
        if let current, current.value == value { return current }
        guard current?.revision == expectedRevision else { throw Failure.changed }
        let record = Record(revision: UUID().uuidString, value: value)
        let data = try JSONEncoder().encode(record)
        guard data.count <= limit else { throw Failure.tooLarge }
        #if os(macOS)
        try data.write(to: file, options: .atomic)
        #else
        try data.write(to: file, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        #endif
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
        let handle = try FileHandle(forWritingTo: file)
        defer { try? handle.close() }
        try handle.synchronize()
        let descriptor = Darwin.open(directory.path, O_RDONLY | O_CLOEXEC)
        guard descriptor >= 0 else { throw Failure.unavailable }
        defer { Darwin.close(descriptor) }
        guard Darwin.fsync(descriptor) == 0 else { throw Failure.unavailable }
        return record
    }

    private func read() throws -> Record? {
        guard FileManager.default.fileExists(atPath: file.path) else { return nil }
        let handle = try FileHandle(forReadingFrom: file)
        defer { try? handle.close() }
        let data = try handle.read(upToCount: limit + 1) ?? Data()
        guard data.count <= limit else { throw Failure.tooLarge }
        return try JSONDecoder().decode(Record.self, from: data)
    }
}
