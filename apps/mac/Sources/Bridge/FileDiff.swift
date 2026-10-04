// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
import Foundation

/// What one line of a diff is.
enum DiffLineKind: String, Codable, Sendable {
    case context, added, removed
}

/// One line of a diff, with the numbers each side shows in its gutter.
struct DiffLine: Codable, Sendable, Hashable, Identifiable {
    var kind: DiffLineKind
    var oldLine: UInt32?
    var newLine: UInt32?
    /// The line without its leading `+`, `-` or space.
    var text: String

    /// Unique within a hunk: a line is one or the other, never neither.
    var id: String { "\(oldLine.map(String.init) ?? "")-\(newLine.map(String.init) ?? "")" }
}

struct DiffHunk: Codable, Sendable, Hashable, Identifiable {
    var header: String
    var lines: [DiffLine]

    var id: String { header }
}

/// One file's diff against HEAD.
struct FileDiff: Codable, Sendable, Hashable {
    /// One decoded snapshot. Layout tasks compare this small identity instead
    /// of hashing megabytes of source text on the main actor.
    var renderRevision = UUID()
    var path: String
    var hunks: [DiffHunk]
    /// True when git refused to diff it as text. Showing nothing without saying
    /// why looks like an empty file.
    var binary: Bool
    /// True when the file is not tracked, so every line reads as added.
    var untracked: Bool

    private enum CodingKeys: String, CodingKey { case path, hunks, binary, untracked }

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.path == rhs.path && lhs.hunks == rhs.hunks && lhs.binary == rhs.binary && lhs.untracked == rhs.untracked
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(path)
        hasher.combine(hunks)
        hasher.combine(binary)
        hasher.combine(untracked)
    }

    var fileName: String { String(path.split(separator: "/").last ?? "") }

    /// The first `limit` body lines of this diff, and how many were left out.
    ///
    /// For a card inside a transcript, which draws a diff beside hundreds of
    /// other rows and has no viewport of its own to be lazy against. The file
    /// viewer shows the whole thing and does not call this.
    func clipped(toLines limit: Int) -> (diff: FileDiff, cut: Int) {
        let total = hunks.reduce(0) { $0 + $1.lines.count }
        guard total > limit else { return (self, 0) }
        var kept: [DiffHunk] = []
        var room = limit
        for hunk in hunks {
            guard room > 0 else { break }
            if hunk.lines.count <= room {
                kept.append(hunk)
                room -= hunk.lines.count
            } else {
                kept.append(DiffHunk(header: hunk.header, lines: Array(hunk.lines.prefix(room))))
                room = 0
            }
        }
        var out = self
        out.hunks = kept
        return (out, total - limit)
    }

    /// Build a diff from a chat Edit snippet (`- old` / `+ new` lines).
    ///
    /// Those previews are not unified diffs: they have no hunk header and no
    /// line numbers. DiffBody still needs a FileDiff, so this invents a single
    /// hunk and sequential gutters so the existing renderer can draw it.
    static func fromEditPatch(path: String, patch: String) -> FileDiff {
        var lines: [DiffLine] = []
        var oldLine: UInt32 = 1
        var newLine: UInt32 = 1
        for raw in patch.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = String(raw)
            if line.hasPrefix("+") {
                lines.append(
                    DiffLine(kind: .added, oldLine: nil, newLine: newLine, text: strip(line, mark: "+"))
                )
                newLine += 1
            } else if line.hasPrefix("-") {
                lines.append(
                    DiffLine(kind: .removed, oldLine: oldLine, newLine: nil, text: strip(line, mark: "-"))
                )
                oldLine += 1
            } else if !line.isEmpty {
                lines.append(
                    DiffLine(kind: .context, oldLine: oldLine, newLine: newLine, text: line)
                )
                oldLine += 1
                newLine += 1
            }
        }
        return FileDiff(
            path: path,
            hunks: lines.isEmpty ? [] : [DiffHunk(header: "@@ preview @@", lines: lines)],
            binary: false,
            untracked: false
        )
    }

    private static func strip(_ line: String, mark: String) -> String {
        if line.hasPrefix("\(mark) ") { return String(line.dropFirst(2)) }
        if line.hasPrefix(mark) { return String(line.dropFirst()) }
        return line
    }
}
