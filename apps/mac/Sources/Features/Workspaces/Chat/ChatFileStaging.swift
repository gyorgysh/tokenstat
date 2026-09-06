// SPDX-License-Identifier: LicenseRef-tokenstat-source-available

import Foundation

/// Writing a downloaded attachment somewhere the system can open it.
///
/// The bytes live in memory and in a hashed cache file with no extension, and
/// neither is something Quick Look, the share sheet, Save to Files or Finder
/// can be pointed at. This is the copy with the real name on it.
enum ChatFileStaging {
    /// Where staged copies go. The attachment cache prunes this directory on
    /// the same budget as the downloads, so a copy can be gone by the next
    /// time a row is tapped. Staging is therefore cheap and repeatable rather
    /// than done once.
    static var directory: URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("tokenstat-chat-files", isDirectory: true)
    }

    /// The staged copy, made if it is not already there.
    ///
    /// Throws rather than returning nil. A silent failure here is a card that
    /// does nothing when tapped and says nothing about why.
    static func stage(_ data: Data, id: String, name: String, into root: URL? = nil) throws -> URL {
        let safeID = sanitized(id)
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
            withIntermediateDirectories: true
        )
        let filePath = (folderPath as NSString).appendingPathComponent(safeName)
        let prefix = folderPath.hasSuffix("/") ? folderPath : folderPath + "/"
        guard filePath.hasPrefix(prefix),
              (filePath as NSString).lastPathComponent == safeName
        else {
            throw CocoaError(.fileWriteInvalidFileName)
        }
        let url = URL(fileURLWithPath: filePath, isDirectory: false)
        if let existing = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize,
           existing == data.count {
            return url
        }
        #if os(macOS)
        try data.write(to: url, options: .atomic)
        #else
        try data.write(
            to: url,
            options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication]
        )
        #endif
        return url
    }

    /// One path component, whatever the host called the file.
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
