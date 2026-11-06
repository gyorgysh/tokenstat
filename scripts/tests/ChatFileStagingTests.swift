// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
// Compile with ChatFileStaging.swift using swiftc -parse-as-library, then run.
import Foundation

@main
struct ChatFileStagingTests {
    static func require(_ condition: Bool, _ message: String) {
        precondition(condition, message)
    }

    @MainActor static func main() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("tokenstat-staging-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let bytes = Data("galaxy".utf8)
        let url = try ChatFileStaging.stage(
            bytes, id: "output-1", name: "galaxy.jpg", into: root
        )
        require(url.lastPathComponent == "galaxy.jpg", "Keeps the real name")
        require(
            url.deletingLastPathComponent().lastPathComponent.count == 64,
            "Lives under a content digest"
        )
        require(try Data(contentsOf: url) == bytes, "Bytes round trip")

        let again = try ChatFileStaging.stage(
            bytes, id: "output-1", name: "galaxy.jpg", into: root
        )
        require(again.path == url.path, "Same bytes land on the same path")

        let collision = Data("galaxy".utf8.reversed())
        require(collision.count == bytes.count, "Collision fixture really collides")
        let fixed = try ChatFileStaging.stage(
            collision, id: "output-1", name: "galaxy.jpg", into: root
        )
        require(try Data(contentsOf: fixed) == collision, "Same size never reuses wrong bytes")
        require(fixed != url, "A reused ID never overwrites an already opened copy")
        require(try Data(contentsOf: url) == bytes, "The original open copy keeps its bytes")

        let changed = Data("galaxy!!".utf8)
        let rewritten = try ChatFileStaging.stage(
            changed, id: "output-1", name: "galaxy.jpg", into: root
        )
        require(try Data(contentsOf: rewritten) == changed, "Size change has its own bytes")

        let escaped = try ChatFileStaging.stage(
            Data("x".utf8), id: "id", name: "../etc/passwd", into: root
        )
        require(escaped.lastPathComponent == "passwd", "Strips directory components")
        require(
            escaped.deletingLastPathComponent().deletingLastPathComponent().standardizedFileURL == root.standardizedFileURL,
            "Traversal stays inside the staging root"
        )

        let unnamed = try ChatFileStaging.stage(
            Data("x".utf8), id: "id", name: "..", into: root
        )
        require(unnamed.lastPathComponent == "attachment", "Dot-dot becomes attachment")

        require(ChatFileStaging.sanitized("galaxy.jpg") == "galaxy.jpg", "Plain name")
        require(ChatFileStaging.sanitized("/tmp/galaxy.jpg") == "galaxy.jpg", "Absolute path")
        require(ChatFileStaging.sanitized("") == "attachment", "Empty name")
        require(ChatFileStaging.sanitized("a:b.jpg") == "a_b.jpg", "Colon is a separator")

        var checks = 0
        let prepared = try await ChatFileStaging.prepare(bytes, id: "output-1", name: "galaxy.jpg", into: root) {
            checks += 1
            return true
        }
        require(try Data(contentsOf: prepared) == bytes && checks == 2, "Preparation checks access before and after staging")
        let refused = root.appendingPathComponent("refused")
        do {
            _ = try await ChatFileStaging.prepare(bytes, id: "denied", name: "file", into: refused) { false }
            preconditionFailure("Denied preparation returned a file")
        } catch is CancellationError {}
        require(!FileManager.default.fileExists(atPath: refused.path), "Denied work never creates a staged copy")
        checks = 0
        do {
            _ = try await ChatFileStaging.prepare(bytes, id: "changed-owner", name: "file", into: root) {
                checks += 1
                return checks == 1
            }
            preconditionFailure("Preparation published after its owner or access changed")
        } catch is CancellationError {}
        require(checks == 2, "The completed file is checked against fresh access")
        let cancelled = root.appendingPathComponent("cancelled")
        let task = Task { @MainActor in
            try await ChatFileStaging.prepare(bytes, id: "cancelled", name: "file", into: cancelled) { true }
        }
        task.cancel()
        do { _ = try await task.value; preconditionFailure("Cancelled preparation returned a file") }
        catch is CancellationError {}
        require(!FileManager.default.fileExists(atPath: cancelled.path), "Pre-cancelled work never creates a staged copy")

        print("ChatFileStagingTests passed")
    }
}
