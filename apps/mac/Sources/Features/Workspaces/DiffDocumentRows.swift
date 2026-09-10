// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
import Foundation

/// A single flat list gives the lazy layout one item per visible diff line.
/// File/hunk indices also disambiguate repeated hunk headers and line numbers.
struct DiffDocumentRow: Identifiable, Sendable {
    let id: String
    let content: Content
    enum Content: Sendable {
        case file(String)
        case hunk(String)
        case line(DiffLine)
        case note(String)
    }

    static func make(_ diffs: [FileDiff], fileHeaders: Bool) -> [Self] {
        var rows: [Self] = []
        for (fileIndex, diff) in diffs.enumerated() {
            guard !Task.isCancelled else { return [] }
            let prefix = "\(fileIndex):\(diff.path)"
            if fileHeaders { rows.append(Self(id: "\(prefix):file", content: .file(diff.path))) }
            if diff.binary {
                rows.append(Self(id: "\(prefix):note", content: .note("Binary file · no text diff")))
            } else if diff.hunks.isEmpty {
                rows.append(Self(id: "\(prefix):note", content: .note(diff.untracked ? "Empty untracked file" : "No text changes")))
            } else {
                for (hunkIndex, hunk) in diff.hunks.enumerated() {
                    guard !Task.isCancelled else { return [] }
                    let key = "\(prefix):\(hunkIndex)"
                    rows.append(Self(id: "\(key):header", content: .hunk(hunk.header)))
                    for (lineIndex, line) in hunk.lines.enumerated() {
                        rows.append(Self(id: "\(key):\(lineIndex)", content: .line(line)))
                    }
                }
            }
        }
        return rows
    }
}
