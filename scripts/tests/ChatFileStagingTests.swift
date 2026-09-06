// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
// Compile with ChatFileStaging.swift using swiftc -parse-as-library, then run.
import Foundation

@main
struct ChatFileStagingTests {
    static func require(_ condition: Bool, _ message: String) {
        precondition(condition, message)
    }

    static func main() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("tokenstat-staging-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let bytes = Data("galaxy".utf8)
        let url = try ChatFileStaging.stage(
            bytes, id: "output-1", name: "galaxy.jpg", into: root
        )
        require(url.lastPathComponent == "galaxy.jpg", "Keeps the real name")
        require(
            url.deletingLastPathComponent().lastPathComponent == "output-1",
            "Lives under the attachment id"
        )
        require(try Data(contentsOf: url) == bytes, "Bytes round trip")

        let again = try ChatFileStaging.stage(
            bytes, id: "output-1", name: "galaxy.jpg", into: root
        )
        require(again.path == url.path, "Same size reuses the copy")

        let changed = Data("galaxy!!".utf8)
        let rewritten = try ChatFileStaging.stage(
            changed, id: "output-1", name: "galaxy.jpg", into: root
        )
        require(try Data(contentsOf: rewritten) == changed, "Size change overwrites")

        let escaped = try ChatFileStaging.stage(
            Data("x".utf8), id: "id", name: "../etc/passwd", into: root
        )
        require(escaped.lastPathComponent == "passwd", "Strips directory components")
        require(
            escaped.deletingLastPathComponent().lastPathComponent == "id",
            "Traversal stays inside the id folder"
        )

        let unnamed = try ChatFileStaging.stage(
            Data("x".utf8), id: "id", name: "..", into: root
        )
        require(unnamed.lastPathComponent == "attachment", "Dot-dot becomes attachment")

        require(ChatFileStaging.sanitized("galaxy.jpg") == "galaxy.jpg", "Plain name")
        require(ChatFileStaging.sanitized("/tmp/galaxy.jpg") == "galaxy.jpg", "Absolute path")
        require(ChatFileStaging.sanitized("") == "attachment", "Empty name")
        require(ChatFileStaging.sanitized("a:b.jpg") == "a_b.jpg", "Colon is a separator")

        print("ChatFileStagingTests passed")
    }
}
