// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
// Compile with DiffDocumentRows.swift.
import Foundation

struct DiffLine: Sendable { let text: String }
struct DiffHunk: Sendable { let header: String; let lines: [DiffLine] }
struct FileDiff: Sendable { let path: String; let hunks: [DiffHunk]; let binary: Bool; let untracked: Bool }

@main enum DiffDocumentRowsTests {
    static func main() {
        let lines = (0..<100_000).map { DiffLine(text: "line \($0)") }
        let hunk = DiffHunk(header: "@@ repeated @@", lines: lines)
        let file = FileDiff(path: "large.swift", hunks: [hunk, hunk], binary: false, untracked: false)
        let start = ContinuousClock.now
        let rows = DiffDocumentRow.make([file], fileHeaders: true)
        precondition(rows.count == 200_003)
        precondition(Set(rows.map(\.id)).count == rows.count, "repeated headers must not duplicate identities")
        guard case let .line(first) = rows[2].content,
              case let .line(last) = rows.last?.content else { fatalError("missing lines") }
        precondition(first.text == "line 0" && last.text == "line 99999")
        let notes = DiffDocumentRow.make([
            FileDiff(path: "binary", hunks: [], binary: true, untracked: false),
            FileDiff(path: "empty", hunks: [], binary: false, untracked: true)
        ], fileHeaders: true)
        precondition(notes.count == 4)
        let bare = DiffDocumentRow.make([FileDiff(path: "file", hunks: [DiffHunk(header: "@@", lines: [DiffLine(text: "x")])], binary: false, untracked: false)], fileHeaders: false)
        precondition(bare.count == 2)
        print("Diff document: 200,000 lines, unique IDs, ordering, binary/empty files passed (\(start.duration(to: .now)))")
    }
}
