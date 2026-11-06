// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
import Foundation
import CryptoKit
import Darwin

enum ChatFileIO {
    static let maximumBytes: UInt64 = 256 * 1024 * 1024
    static let chunkBytes = 512 * 1024

    enum DataSource: Sendable {
        case file(URL)
        case base64(String)
    }

    /// Small attachments stay in memory; file-backed large transfers do not
    /// use this path. Keep both file I/O and legacy decoding off the UI actor.
    static func data(from source: DataSource, maximum: Int) async throws -> Data {
        guard maximum > 0, maximum <= Int(maximumBytes) else { throw CocoaError(.fileReadTooLarge) }
        try Task.checkCancellation()
        let worker = Task.detached(priority: .userInitiated) {
            try Task.checkCancellation()
            let result: Data
            switch source {
            case let .file(url):
                let (input, expected) = try openFile(url, maximum: UInt64(maximum))
                defer { try? input.close() }
                let size = Int(expected)
                var bytes = Data()
                bytes.reserveCapacity(size)
                while bytes.count <= size {
                    try Task.checkCancellation()
                    let chunk = try input.read(upToCount: min(chunkBytes, size + 1 - bytes.count)) ?? Data()
                    if chunk.isEmpty { break }
                    bytes.append(chunk)
                }
                guard bytes.count == size else { throw CocoaError(.fileReadCorruptFile) }
                result = bytes
            case let .base64(encoded):
                guard encoded.utf8.count <= ((maximum + 2) / 3) * 4,
                      let decoded = Data(base64Encoded: encoded), !decoded.isEmpty,
                      decoded.count <= maximum else { throw CocoaError(.fileReadCorruptFile) }
                result = decoded
            }
            try Task.checkCancellation()
            return result
        }
        let result = try await withTaskCancellationHandler {
            try await worker.value
        } onCancel: { worker.cancel() }
        try Task.checkCancellation()
        return result
    }

    /// Validate the opened file, since URL metadata can outlive a rewrite.
    /// Nonblocking open also lets us reject pipes without waiting for a writer.
    private static func openFile(_ url: URL, maximum: UInt64) throws -> (FileHandle, UInt64) {
        guard url.isFileURL else { throw CocoaError(.fileReadUnsupportedScheme) }
        try Task.checkCancellation()
        let descriptor = url.withUnsafeFileSystemRepresentation { path in
            guard let path else { errno = EINVAL; return Int32(-1) }
            return Darwin.open(path, O_RDONLY | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK)
        }
        guard descriptor >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        let file = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        do {
            var metadata = stat()
            guard Darwin.fstat(descriptor, &metadata) == 0 else {
                throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            }
            guard metadata.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG), metadata.st_size > 0,
                  UInt64(metadata.st_size) <= maximum else { throw CocoaError(.fileReadTooLarge) }
            return (file, UInt64(metadata.st_size))
        } catch {
            try? file.close()
            throw error
        }
    }

    /// Copy into a new private file without allocating the whole original.
    static func copy(_ source: URL, to destination: URL) throws {
        let (input, expected) = try openFile(source, maximum: maximumBytes)
        defer { try? input.close() }
        // The existence check and creation must be one operation: another
        // store/process may retain this same original at the same time.
        let descriptor = Darwin.open(destination.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard descriptor >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        let output = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        defer { try? output.close() }
        do {
            var count: UInt64 = 0
            while let chunk = try input.read(upToCount: chunkBytes), !chunk.isEmpty {
                try Task.checkCancellation()
                count += UInt64(chunk.count)
                guard count <= expected else { throw CocoaError(.fileReadCorruptFile) }
                try output.write(contentsOf: chunk)
            }
            guard count == expected else { throw CocoaError(.fileReadCorruptFile) }
            try output.synchronize()
        } catch { try? FileManager.default.removeItem(at: destination); throw error }
    }
    static func hash(_ file: URL) throws -> (UInt64, String) {
        let (handle, size) = try openFile(file, maximum: maximumBytes)
        defer { try? handle.close() }
        var hash = SHA256()
        var count: UInt64 = 0
        while let data = try handle.read(upToCount: chunkBytes), !data.isEmpty {
            try Task.checkCancellation()
            count += UInt64(data.count)
            guard count <= maximumBytes else { throw CocoaError(.fileReadTooLarge) }
            hash.update(data: data)
        }
        guard count == size else { throw CocoaError(.fileReadCorruptFile) }
        return (count, hash.finalize().map { String(format: "%02x", $0) }.joined())
    }
}
