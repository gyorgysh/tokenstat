// SPDX-License-Identifier: LicenseRef-tokenstat-source-available

import Foundation

struct ChatToolState: Equatable {
    var callId: String
    var verb: String
    var target: String
    var running: Bool
    var failed: Bool
    var detail: String?
    var startedAtMs: Int64
    var endedAtMs: Int64?
    /// Display lines, split once at construction. `snippet` used to split
    /// the whole detail on every read, and a row reads it half a dozen
    /// times per draw: Codex shell outputs reach megabytes, so one live
    /// row cost several full multi-megabyte splits per poll.
    var snippet: [String]

    var duration: String? {
        ChatClock.duration(from: startedAtMs, to: endedAtMs)
    }

    static func isFileEditVerb(_ verb: String) -> Bool {
        verb == "Edit" || verb == "NotebookEdit"
    }

    /// Display lines for one detail string, split once. See `snippet`.
    static func makeSnippet(verb: String, detail: String?) -> [String] {
        guard let detail, !detail.isEmpty else { return [] }
        let lines = detail.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        // An edit's red/green lines must reach the row unprefixed: a blanket
        // "| " is what made every Tool row read as grey output and broke the
        // Show edit label. This covers both the old/new rendering ("- old")
        // and unified patches ("-hello", "@@" hunks stay grey). Other verbs
        // keep the output marker on every line, so a shell trace like
        // "+ set -x" never poses as a diff.
        // Codex often exposes a unified patch through a command_execution
        // item. Treat Diff like a native edit so +/- lines remain visible and
        // receive the same semantic coloring as Edit/NotebookEdit cards.
        let diffVerbs = ["Edit", "NotebookEdit", "Diff"]
        let isDiff = diffVerbs.contains(verb)
        var out = lines.prefix(Self.snippetLineCap).map { line in
            let shown = Self.clip(line)
            if isDiff, Self.isDiffLine(shown) {
                return shown
            }
            return "| \(shown)"
        }
        if lines.count > Self.snippetLineCap {
            out.append(L10n.text("apple.chatmodel.0_more.8bfcca49", "\(lines.count - Self.snippetLineCap)"))
        }
        return Array(out)
    }

    /// A unified or old/new diff body line. File headers ("--- a/…",
    /// "+++ b/…") are not changes and stay grey.
    static func isDiffLine(_ line: String) -> Bool {
        guard let first = line.first else { return false }
        guard first == "+" || first == "-" else { return false }
        return !(line.hasPrefix("+++ ") || line.hasPrefix("--- "))
    }

    /// Cut one line down to what a row can draw.
    ///
    /// The line cap alone bounds the wrong half. A line is whatever sits
    /// between two newlines, and a tool that answers in JSON answers in one
    /// line however many kilobytes it is: a web search result arrives as a
    /// single forty-kilobyte string. Handing that to one `Text` in a stack
    /// that grows to fit means laying out forty thousand characters, with
    /// wrapping, on every measuring pass the lazy stack makes.
    ///
    /// That is the hang. It is per row and not per transcript, which is why
    /// it survived every bound put on the number of rows: thirty-seven rows
    /// took a second and a half, and a dozen took a third of one.
    ///
    /// The full text stays in `detail`, so copy still yields everything.
    static func clip(_ line: String) -> String {
        guard line.count > Self.snippetColumnCap else { return line }
        return String(line.prefix(Self.snippetColumnCap)) + "…"
    }

    /// A 500-line stdout must not become 500 rows. The full text stays in
    /// `detail` for copy; the row only ever draws this many.
    private static let snippetLineCap = 60
    /// And how much of one line is drawn.
    ///
    /// Roughly four wrapped lines of the row's monospace face in a full-width
    /// reading lane, so ordinary output, long shell commands and minified
    /// source all still read as themselves. What it stops is the single line
    /// that is really a document.
    private static let snippetColumnCap = 600
}

/// A file the agent changed. One card, not a tool row plus a second copy.
struct ChatEditState: Equatable {
    var path: String
    var added: UInt32
    var removed: UInt32
    var patch: String
    /// 1-based count of this path since the last user message. 2 means this
    /// file was already edited earlier in the same turn.
    var revision: Int
    var running: Bool
    var failed: Bool
    var startedAtMs: Int64
    var endedAtMs: Int64?

    var duration: String? {
        ChatClock.duration(from: startedAtMs, to: endedAtMs)
    }

    var fileName: String {
        let name = URL(fileURLWithPath: path).lastPathComponent
        return name.isEmpty ? path : name
    }

    /// Last two folders of the parent path, enough to tell two same-named
    /// files apart without drawing the whole absolute path as the title.
    var location: String {
        let folder = (path as NSString).deletingLastPathComponent
        let last = (folder as NSString).lastPathComponent
        let grand = ((folder as NSString).deletingLastPathComponent as NSString).lastPathComponent
        if last.isEmpty || last == "/" { return "" }
        if grand.isEmpty || grand == "/" { return last }
        return "\(grand)/\(last)"
    }

    /// Nil on the first change of a file in a turn. Later ones name themselves.
    var changeLabel: String? {
        guard revision >= 2 else { return nil }
        return L10n.text("apple.chatmodel.0_change.d4ef778c", "\(ChatClock.ordinal(revision))")
    }

    mutating func applyPatch(added: UInt32, removed: UInt32, patch: String) {
        if added > 0 { self.added = added }
        if removed > 0 { self.removed = removed }
        if !patch.isEmpty { self.patch = patch }
        recountIfNeeded()
    }

    mutating func applyDetail(_ detail: String?) {
        guard patch.isEmpty, let detail, !detail.isEmpty else { return }
        patch = detail
        recountIfNeeded()
    }

    mutating func recountIfNeeded() {
        guard added == 0, removed == 0, !patch.isEmpty else { return }
        var plus: UInt32 = 0
        var minus: UInt32 = 0
        for line in patch.split(separator: "\n", omittingEmptySubsequences: false) {
            let shown = String(line)
            guard ChatToolState.isDiffLine(shown), let first = shown.first else { continue }
            if first == "+" { plus += 1 }
            if first == "-" { minus += 1 }
        }
        added = plus
        removed = minus
    }
}

enum ChatClock {
    static func duration(from startedAtMs: Int64, to endedAtMs: Int64?) -> String? {
        guard let endedAtMs else { return nil }
        let (elapsed, overflow) = endedAtMs.subtractingReportingOverflow(startedAtMs)
        guard !overflow else { return nil }
        let ms = max(0, elapsed)
        if ms < 1000 { return "\(ms)ms" }
        let seconds = Double(ms) / 1000
        if seconds < 10 {
            return String(format: "%.1fs", seconds)
        }
        return "\(Int(seconds.rounded()))s"
    }

    static func ordinal(_ value: Int) -> String {
        let mod100 = value % 100
        let mod10 = value % 10
        if (11...13).contains(mod100) { return "\(value)th" }
        switch mod10 {
        case 1: return "\(value)st"
        case 2: return "\(value)nd"
        case 3: return "\(value)rd"
        default: return "\(value)th"
        }
    }
}

/// A message waiting for the current turn to finish.
/// Equatable so a transcript can skip the rows that did not move. A chat
/// redraws whenever anything about it changes, and without this every visible
/// row rebuilds itself because one of them grew by a word.
struct ChatDisplayItem: Identifiable, Equatable {
    let id: String
    let kind: Kind
    /// Inclusive end of a coalesced text/thinking block in the loaded archive.
    /// Lets a mark from a partial page resolve after earlier deltas arrive.
    var lastSequence: UInt64? = nil
    /// The folded step group this row was opened from, when it is one of a
    /// group's steps shown below its header. Nil for every top-level row.
    /// See `ChatTranscriptFold`.
    var groupID: String? = nil

    enum Kind: Equatable {
        case user(String)
        case assistant(String, backend: String?)
        case turnSeparator(String)
        /// A conversation changing hands, with the summary the incoming agent
        /// was given so the person can read exactly what it was told.
        case handoff(to: String, brief: String)
        case thinking(String)
        case tool(ChatToolState)
        case edit(ChatEditState)
        case attachment(ChatAttachment)
        case approval(ChatApproval)
        case usage(input: UInt64, output: UInt64, cost: Double?)
        case failed(String)
        /// Steps folded into one line by the chat's detail level. The steps
        /// themselves follow as their own rows when the group is open.
        case group(ChatStepGroup)
        /// A question the agent asked, with the answer once there is one.
        case question(ChatQuestion)
        /// The files a finished turn edited. Added by the fold, after the
        /// turn's last row, at every detail level.
        case changes(ChatTurnChanges)
    }
}

/// What one turn changed, file by file, from its edit rows.
///
/// Counts are summed over the turn's edits to a file, so a file edited
/// twice shows both. That is what the agent did, which is what this card
/// is about. The working tree's own totals live in the Changes panel.
struct ChatTurnChanges: Equatable, Sendable {
    struct File: Equatable, Sendable, Identifiable {
        let path: String
        var added: UInt32
        var removed: UInt32
        var id: String { path }

        var fileName: String {
            let name = (path as NSString).lastPathComponent
            return name.isEmpty ? path : name
        }
    }

    let id: String
    var files: [File]

    var added: UInt32 { files.reduce(0) { $0 + $1.added } }
    var removed: UInt32 { files.reduce(0) { $0 + $1.removed } }
}
