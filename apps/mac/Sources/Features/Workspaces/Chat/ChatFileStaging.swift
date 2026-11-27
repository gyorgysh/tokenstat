// SPDX-License-Identifier: LicenseRef-tokenstat-source-available

import Foundation
import CryptoKit

/// Writing a downloaded attachment somewhere the system can open it.
///
/// The bytes live in memory and in a hashed cache file with no extension, and
/// neither is something Quick Look, the share sheet, Save to Files or Finder
/// can be pointed at. This is the copy with the real name on it.
enum ChatFileStaging {
    static var directory: URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("tokenstat-chat-files", isDirectory: true)
    }

    @MainActor
    static func prepare(_ data: Data, id: String, name: String, into root: URL? = nil,
                        canUse: @MainActor () -> Bool) async throws -> URL {
        try Task.checkCancellation()
        guard canUse() else { throw CancellationError() }
        let worker = Task.detached(priority: .userInitiated) {
            try stage(data, id: id, name: name, into: root)
        }
        let url = try await withTaskCancellationHandler {
            try await worker.value
        } onCancel: { worker.cancel() }
        try Task.checkCancellation()
        guard canUse() else { throw CancellationError() }
        return url
    }

    static func stage(_ data: Data, id: String, name: String, into root: URL? = nil) throws -> URL {
        try Task.checkCancellation()
        let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        let safeID = digest
        let safeName = sanitized(name)
        let base = root ?? directory
        // Join with path strings, not `URL.appendingPathComponent`. On iOS a
        // file URL can canonicalize `/var` to `/private/var` while the folder
        // URL stays on `/var`, so a prefix check on those two paths rejected
        // every Open of a downloaded chat file as an invalid name.
        let folderPath = (base.path(percentEncoded: false) as NSString)
            .appendingPathComponent(safeID)
        try FileManager.default.createDirectory(
            atPath: folderPath,
            withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700]
        )
        let filePath = (folderPath as NSString).appendingPathComponent(safeName)
        let prefix = folderPath.hasSuffix("/") ? folderPath : folderPath + "/"
        guard filePath.hasPrefix(prefix),
              (filePath as NSString).lastPathComponent == safeName
        else {
            throw CocoaError(.fileWriteInvalidFileName)
        }
        let url = URL(fileURLWithPath: filePath, isDirectory: false)
        try Task.checkCancellation()
        #if os(macOS)
        try data.write(to: url, options: .atomic)
        #else
        try data.write(
            to: url,
            options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication]
        )
        #endif
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: filePath)
        try Task.checkCancellation()
        return url
    }

    static func sanitized(_ raw: String) -> String {
        let leaf = (raw as NSString).lastPathComponent
        let cleaned = leaf
            .filter { !$0.isNewline && !$0.unicodeScalars.contains(where: \.properties.isDefaultIgnorableCodePoint) }
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "\0", with: "")
        if cleaned.isEmpty || cleaned == "." || cleaned == ".." { return "attachment" }
        let flat = cleaned
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "\\", with: "_")
            .replacingOccurrences(of: ":", with: "_")
        return flat.isEmpty ? "attachment" : flat
    }
}
