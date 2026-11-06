// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
// Compile with ChatFileIO.swift.
import Foundation

@main enum ChatAttachmentDataTests {
    @MainActor static func main() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("tokenstat-attachment-data-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("sample.bin")
        let bytes = Data((0...255).map(UInt8.init)) + Data("café 日本語 👩🏽‍💻".utf8)
        try bytes.write(to: file)
        for source in [ChatFileIO.DataSource.file(file), .base64(bytes.base64EncodedString())] {
            let loaded = try await ChatFileIO.data(from: source, maximum: bytes.count)
            precondition(loaded == bytes, "Both transport forms preserve every byte at the size limit")
            do {
                _ = try await ChatFileIO.data(from: source, maximum: bytes.count - 1)
                preconditionFailure("An oversized attachment was accepted")
            } catch is CocoaError {}
        }
        for encoded in ["", "%%%", "not base64 🌍", "AAAA", String(repeating: "A", count: 100000)] {
            do {
                _ = try await ChatFileIO.data(from: .base64(encoded), maximum: 1)
                preconditionFailure("Invalid or oversized legacy data was accepted")
            } catch is CocoaError {}
        }
        var multichunk = Data(repeating: 0x5a, count: ChatFileIO.chunkBytes * 2 + 17)
        multichunk[ChatFileIO.chunkBytes] = 0x81
        multichunk[multichunk.count - 1] = 0
        _ = try file.resourceValues(forKeys: [.fileSizeKey])
        try multichunk.write(to: file)
        for source in [ChatFileIO.DataSource.file(file), .base64(multichunk.base64EncodedString())] {
            let loaded = try await ChatFileIO.data(from: source, maximum: multichunk.count)
            precondition(loaded == multichunk, "Chunk boundaries and the final partial chunk preserve every byte")
        }
        try Data().write(to: file)
        do {
            _ = try await ChatFileIO.data(from: .file(file), maximum: 10)
            preconditionFailure("An empty attachment was accepted")
        } catch is CocoaError {}
        let task = Task { @MainActor in
            try await ChatFileIO.data(from: .base64(bytes.base64EncodedString()), maximum: bytes.count)
        }
        task.cancel()
        do { _ = try await task.value; preconditionFailure("Cancelled data was published") }
        catch is CancellationError {}
        print("Attachment data: bounded file/legacy reads, exact bytes, malformed input and cancellation passed")
    }
}
