// SPDX-License-Identifier: LicenseRef-tokenstat-source-available

import CryptoKit
import Foundation

/// Small, atomic, account-scoped checkpoints. This store never receives secrets.
struct ClientSetupStore {
    private static let maximumBytes = 32_768
    var directory: URL

    init(directory: URL? = nil) {
        self.directory = directory ?? FileManager.default.urls(
            for: .applicationSupportDirectory, in: .userDomainMask
        )[0].appendingPathComponent("tokenstat-setup", isDirectory: true)
    }

    func load(scope: ClientSetupScope) throws -> ClientSetupDraft? {
        let url = try fileURL(scope: scope)
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        let file = try FileHandle(forReadingFrom: url)
        defer { try? file.close() }
        let data = try file.read(upToCount: Self.maximumBytes + 1) ?? Data()
        guard data.count <= Self.maximumBytes else { throw ClientSetupDraftError.invalid }
        let draft = try JSONDecoder().decode(ClientSetupDraft.self, from: data)
        guard draft.version == ClientSetupDraft.currentVersion else {
            throw ClientSetupDraftError.unsupportedVersion
        }
        guard draft.scope == scope else { throw ClientSetupDraftError.invalid }
        try draft.validate()
        return draft
    }

    func save(_ draft: ClientSetupDraft) throws {
        try draft.validate()
        let data = try JSONEncoder().encode(draft)
        guard data.count <= Self.maximumBytes else { throw ClientSetupDraftError.invalid }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700])
        let url = try fileURL(scope: draft.scope)
        try data.write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        var excluded = url
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try excluded.setResourceValues(values)
    }

    func remove(scope: ClientSetupScope) throws {
        let url = try fileURL(scope: scope)
        if FileManager.default.fileExists(atPath: url.path) {
            try FileManager.default.removeItem(at: url)
        }
    }

    private func fileURL(scope: ClientSetupScope) throws -> URL {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        let hash = SHA256.hash(data: try encoder.encode(scope))
            .map { String(format: "%02x", $0) }.joined()
        return directory.appendingPathComponent("\(hash).json")
    }
}
