// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
// Compile with ChatFileIO.swift.
import Foundation
import CryptoKit
import Darwin

@main enum ChatFileIOTests {
    static func main() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("tokenstat-file-io-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("source.bin")
        try Data(repeating: 1, count: 8).write(to: file)
        _ = try file.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
        for size in [19, 3, ChatFileIO.chunkBytes * 2 + 17] {
            var bytes = Data(repeating: 0x81, count: size)
            bytes[size - 1] = 0
            try bytes.write(to: file)
            let (count, digest) = try ChatFileIO.hash(file)
            let expected = SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
            precondition(count == bytes.count && digest == expected, "Hash uses current file bytes after a cached URL is rewritten")
            let copy = root.appendingPathComponent("copy-\(size).bin")
            try ChatFileIO.copy(file, to: copy)
            let copied = try Data(contentsOf: copy)
            precondition(copied == bytes, "Copy preserves current bytes, including chunk boundaries")
            do {
                try ChatFileIO.copy(file, to: copy)
                preconditionFailure("An existing destination was overwritten")
            } catch {}
            let retained = try Data(contentsOf: copy)
            precondition(retained == bytes)
        }

        let empty = root.appendingPathComponent("empty.bin")
        try Data().write(to: empty)
        let oversized = root.appendingPathComponent("oversized.bin")
        try Data().write(to: oversized)
        let handle = try FileHandle(forWritingTo: oversized)
        try handle.truncate(atOffset: ChatFileIO.maximumBytes + 1)
        try handle.close()
        let pipe = root.appendingPathComponent("pipe")
        precondition(mkfifo(pipe.path, 0o600) == 0)
        let link = root.appendingPathComponent("link.bin")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: file)
        for source in [empty, oversized, root, pipe, link, URL(string: "https://example.invalid/source.bin")!] {
            do {
                _ = try ChatFileIO.hash(source)
                preconditionFailure("Invalid hash source was accepted")
            } catch {}
            let destination = root.appendingPathComponent(UUID().uuidString)
            do {
                try ChatFileIO.copy(source, to: destination)
                preconditionFailure("Invalid copy source was accepted")
            } catch {}
            precondition(!FileManager.default.fileExists(atPath: destination.path), "Refused input leaves no destination")
            do {
                _ = try await ChatFileIO.data(from: .file(source), maximum: 1024)
                preconditionFailure("Invalid read source was accepted")
            } catch {}
        }
        print("Attachment file I/O: rewritten URL metadata, exact hash/copy bytes, exclusive destinations, bounds and non-regular inputs passed")
    }
}
