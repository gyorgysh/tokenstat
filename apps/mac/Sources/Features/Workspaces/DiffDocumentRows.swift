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

    static func count(_ diffs: [FileDiff], fileHeaders: Bool) -> Int {
        var count = 0
        for diff in diffs {
            guard !Task.isCancelled else { return 0 }
            if fileHeaders { count += 1 }
            if diff.binary || diff.hunks.isEmpty {
                count += 1
            } else {
                for hunk in diff.hunks {
                    guard !Task.isCancelled else { return 0 }
                    count += 1 + hunk.lines.count
                }
            }
        }
        return count
    }

    static func make(_ diffs: [FileDiff], fileHeaders: Bool, lineLimit: Int = .max, rowLimit: Int = .max) -> [Self] {
        var rows: [Self] = []
        var lineCount = 0
        for (fileIndex, diff) in diffs.enumerated() {
            guard !Task.isCancelled else { return [] }
            guard rows.count < rowLimit else { return rows }
            let prefix = "\(fileIndex):\(diff.path)"
            if fileHeaders { rows.append(Self(id: "\(prefix):file", content: .file(diff.path))) }
            guard rows.count < rowLimit else { return rows }
            if diff.binary {
                rows.append(Self(id: "\(prefix):note", content: .note(L10n.text("apple.diffdocumentrows.binary_file_no_text_diff.82944fda"))))
            } else if diff.hunks.isEmpty {
                rows.append(Self(id: "\(prefix):note", content: .note(diff.untracked ? L10n.text("apple.diffdocumentrows.empty_untracked_file.579072e4") : L10n.text("apple.diffdocumentrows.no_text_changes.08722a9e"))))
            } else {
                for (hunkIndex, hunk) in diff.hunks.enumerated() {
                    guard !Task.isCancelled else { return [] }
                    guard rows.count < rowLimit else { return rows }
                    guard lineCount < lineLimit else { return rows }
                    let key = "\(prefix):\(hunkIndex)"
                    rows.append(Self(id: "\(key):header", content: .hunk(hunk.header)))
                    for (lineIndex, line) in hunk.lines.enumerated() {
                        guard !Task.isCancelled else { return [] }
                        guard rows.count < rowLimit else { return rows }
                        guard lineCount < lineLimit else { return rows }
                        rows.append(Self(id: "\(key):\(lineIndex)", content: .line(line)))
                        lineCount += 1
                    }
                }
            }
        }
        return rows
    }
}
