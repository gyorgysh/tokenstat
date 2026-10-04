// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
// Compile with FileDiff.swift.
import Foundation

@main enum FileDiffTests {
    static func main() throws {
        let raw = Data(#"{"path":"large.json","hunks":[{"header":"@@","lines":[{"kind":"added","newLine":1,"text":"hello"}]}],"binary":false,"untracked":false}"#.utf8)
        let first = try JSONDecoder().decode(FileDiff.self, from: raw)
        let second = try JSONDecoder().decode(FileDiff.self, from: raw)
        precondition(first == second && first.hashValue == second.hashValue)
        precondition(first.renderRevision != second.renderRevision, "equal snapshots must restart content layout")
        let encoded = try JSONEncoder().encode(first)
        precondition(!String(decoding: encoded, as: UTF8.self).contains("renderRevision"))
        precondition(first.hunks[0].lines[0].oldLine == nil)
        let preview = FileDiff.fromEditPatch(path: "file", patch: "- old\n+ new\n context")
        precondition(preview.hunks[0].lines.map(\.kind) == [.removed, .added, .context])
        let clipped = preview.clipped(toLines: 1)
        precondition(clipped.cut == 2 && clipped.diff.hunks[0].lines.count == 1)
        precondition(clipped.diff.renderRevision == preview.renderRevision)
        print("File diffs: wire compatibility, semantic equality, snapshot identity and preview clipping passed")
    }
}
