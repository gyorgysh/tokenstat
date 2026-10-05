// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
import Foundation

/// A single flat list gives the lazy layout one item per visible diff line.
/// File/hunk indices also disambiguate repeated hunk headers and line numbers.
struct DiffDocumentRow: Identifiable, Sendable {
    /// Keep a minified source line from becoming one enormous wrapped lazy item.
    static let wrappedLineCharacterLimit = 256
    let id: String
    let content: Content
    /// A bounded piece of the same source line, rather than a new source line.
    var continuation = false
    enum Content: Sendable {
        case file(String)
        case hunk(String)
        case line(DiffLine)
        case note(String)
    }

    static func count(_ diffs: [FileDiff], fileHeaders: Bool, maxLineCharacters: Int = .max) -> Int {
        let chunkSize = max(1, maxLineCharacters)
        var count = 0
        for diff in diffs {
            guard !Task.isCancelled else { return 0 }
            if fileHeaders { count += 1 }
            if diff.binary || diff.hunks.isEmpty {
                count += 1
            } else {
                for hunk in diff.hunks {
                    guard !Task.isCancelled else { return 0 }
                    count += 1
                    if chunkSize == .max {
                        count += hunk.lines.count
                    } else {
                        for line in hunk.lines {
                            guard !Task.isCancelled else { return 0 }
                            if line.text.isEmpty { count += 1; continue }
                            var start = line.text.startIndex
                            while start < line.text.endIndex {
                                guard !Task.isCancelled else { return 0 }
                                start = end(of: line.text, from: start, limit: chunkSize)
                                count += 1
                            }
                        }
                    }
                }
            }
        }
        return count
    }

    static func make(_ diffs: [FileDiff], fileHeaders: Bool, lineLimit: Int = .max, rowLimit: Int = .max,
                     maxLineCharacters: Int = .max) -> [Self] {
        var rows: [Self] = []
        var lineCount = 0
        let chunkSize = max(1, maxLineCharacters)
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
                        let lineKey = "\(key):\(lineIndex)"
                        if chunkSize == .max || line.text.isEmpty {
                            rows.append(Self(id: lineKey, content: .line(line)))
                        } else {
                            // A grapheme can itself contain megabytes of
                            // combining marks. Scalar boundaries keep layout
                            // bounded while preserving every Unicode scalar.
                            let scalars = line.text.unicodeScalars
                            var start = scalars.startIndex
                            var part = 0
                            while start < scalars.endIndex {
                                guard !Task.isCancelled else { return [] }
                                guard rows.count < rowLimit else { return rows }
                                let end = end(of: line.text, from: start, limit: chunkSize)
                                var piece = line
                                piece.text = String(line.text[start..<end])
                                rows.append(Self(id: part == 0 ? lineKey : "\(lineKey):wrap:\(part)",
                                                 content: .line(piece), continuation: part > 0))
                                start = end
                                part += 1
                            }
                        }
                        lineCount += 1
                    }
                }
            }
        }
        return rows
    }

    /// Preserve ordinary graphemes at a wrap boundary, using at most one
    /// bounded lookahead. A pathological grapheme is split on scalar
    /// boundaries so it cannot turn into a multi-megabyte layout item.
    private static func end(of text: String, from start: String.Index, limit: Int) -> String.Index {
        let scalars = text.unicodeScalars
        let end = scalars.index(start, offsetBy: limit, limitedBy: scalars.endIndex) ?? scalars.endIndex
        guard end < scalars.endIndex, scalars[end].value >= 128 else { return end }
        let lookahead = scalars.index(after: end)
        let candidate = String(scalars[start..<lookahead])
        guard let last = candidate.last else { return end }
        let lastUnits = last.unicodeScalars.count
        let units = candidate.unicodeScalars.count
        guard lastUnits > 1, lastUnits < units else { return end }
        return scalars.index(start, offsetBy: units - lastUnits)
    }
}
