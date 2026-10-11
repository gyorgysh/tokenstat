// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
import Foundation
import CryptoKit

enum ChatFileIO {
    static let maximumBytes: UInt64 = 256 * 1024 * 1024
    static let chunkBytes = 512 * 1024
    /// Copy into a new private file without allocating the whole original.
    static func copy(_ source: URL, to destination: URL) throws {
        let values = try source.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
        guard values.isRegularFile == true, let expected = values.fileSize, expected > 0,
              UInt64(expected) <= maximumBytes else { throw CocoaError(.fileReadTooLarge) }
        guard !FileManager.default.fileExists(atPath: destination.path),
              FileManager.default.createFile(atPath: destination.path, contents: nil, attributes: [.posixPermissions: 0o600]) else { throw CocoaError(.fileWriteFileExists) }
        do {
            let input = try FileHandle(forReadingFrom: source); defer { try? input.close() }
            let output = try FileHandle(forWritingTo: destination); defer { try? output.close() }
            var count: UInt64 = 0
            while let chunk = try input.read(upToCount: chunkBytes), !chunk.isEmpty {
                try Task.checkCancellation()
                count += UInt64(chunk.count)
                guard count <= UInt64(expected) else { throw CocoaError(.fileReadCorruptFile) }
                try output.write(contentsOf: chunk)
            }
            guard count == UInt64(expected) else { throw CocoaError(.fileReadCorruptFile) }
            try output.synchronize()
        } catch { try? FileManager.default.removeItem(at: destination); throw error }
    }
    static func hash(_ file: URL) throws -> (UInt64, String) {
        let values = try file.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
        guard values.isRegularFile == true, let size = values.fileSize, size > 0,
              UInt64(size) <= maximumBytes else { throw CocoaError(.fileReadTooLarge) }
        let handle = try FileHandle(forReadingFrom: file)
        defer { try? handle.close() }
        var hash = SHA256()
        var count: UInt64 = 0
        while let data = try handle.read(upToCount: chunkBytes), !data.isEmpty {
            try Task.checkCancellation()
            count += UInt64(data.count)
            guard count <= maximumBytes else { throw CocoaError(.fileReadTooLarge) }
            hash.update(data: data)
        }
        guard count == UInt64(size) else { throw CocoaError(.fileReadCorruptFile) }
        return (count, hash.finalize().map { String(format: "%02x", $0) }.joined())
    }
}
