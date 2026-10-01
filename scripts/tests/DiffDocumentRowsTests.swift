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
        let pageStart = ContinuousClock.now
        let firstPage = DiffDocumentRow.make([file, file], fileHeaders: true, lineLimit: 2_000)
        precondition(firstPage.count == 2_002, "one page must bound the entire document, not each file")
        let expanded = DiffDocumentRow.make([file, file], fileHeaders: true, lineLimit: 4_000)
        precondition(expanded.count == 4_002)
        precondition(Array(expanded.prefix(firstPage.count)).map(\.id) == firstPage.map(\.id), "expanding preserves reading anchors")
        let multiFile = DiffDocumentRow.make([
            FileDiff(path: "a", hunks: [DiffHunk(header: "@@", lines: Array(lines.prefix(2)))], binary: false, untracked: false),
            FileDiff(path: "b", hunks: [DiffHunk(header: "@@", lines: Array(lines.prefix(2)))], binary: false, untracked: false)
        ], fileHeaders: true, lineLimit: 3)
        precondition(multiFile.filter { if case .line = $0.content { return true }; return false }.count == 3)
        let binaryFiles = (0..<100_000).map { FileDiff(path: "binary\($0)", hunks: [], binary: true, untracked: false) }
        let binaryPage = DiffDocumentRow.make(binaryFiles, fileHeaders: true, rowLimit: 2_000)
        precondition(binaryPage.count == 2_000, "binary files must obey the page budget")
        precondition(DiffDocumentRow.count(binaryFiles, fileHeaders: true) == 200_000)
        let emptyHunks = FileDiff(path: "empty-hunks", hunks: Array(repeating: DiffHunk(header: "@@", lines: []), count: 100_000), binary: false, untracked: false)
        let emptyPage = DiffDocumentRow.make([emptyHunks], fileHeaders: false, rowLimit: 60)
        precondition(emptyPage.count == 60, "empty hunks must obey the preview budget")
        let nextPage = DiffDocumentRow.make([emptyHunks], fileHeaders: false, rowLimit: 120)
        precondition(Array(nextPage.prefix(60)).map(\.id) == emptyPage.map(\.id))
        precondition(Set(nextPage.map(\.id)).count == nextPage.count)
        for headers in [true, false] {
            let mixed = [file, emptyHunks] + Array(binaryFiles.prefix(2))
            precondition(DiffDocumentRow.count(mixed, fileHeaders: headers) == DiffDocumentRow.make(mixed, fileHeaders: headers).count)
            precondition(DiffDocumentRow.make(mixed, fileHeaders: headers, rowLimit: 0).isEmpty)
        }
        print("Bounded 400,000-line document pages and stable expansion passed (\(pageStart.duration(to: .now)))")
        print("Diff document: 200,000 lines, unique IDs, ordering, binary/empty files passed (\(start.duration(to: .now)))")
    }
}
