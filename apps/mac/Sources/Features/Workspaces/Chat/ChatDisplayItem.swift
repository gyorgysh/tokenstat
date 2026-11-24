// SPDX-License-Identifier: LicenseRef-tokenstat-source-available

import Foundation
import Darwin

struct ChatToolState: Equatable, Sendable {
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
        var out: [String] = []
        out.reserveCapacity(Self.snippetLineCap + 1)
        func append(_ line: Substring) {
            let shown = Self.clip(line)
            if isDiff, Self.isDiffLine(shown) {
                out.append(shown)
            } else {
                out.append("| \(shown)")
            }
        }
        // Large tool logs are mostly omitted. Scan their contiguous bytes
        // without advancing a Swift String index for every byte; create
        // String indices only for the lines the row will actually display.
        if let lineCount = detail.utf8.withContiguousStorageIfAvailable({ bytes -> Int in
            guard let base = bytes.baseAddress else { return 1 }
            var start = 0, search = 0, count = 1
            while search < bytes.count,
                  let found = memchr(base + search, 10, bytes.count - search) {
                let end = base.distance(to: found.assumingMemoryBound(to: UInt8.self))
                search = end + 1
                if end > 0 && bytes[end - 1] == 13 { continue }
                if out.count < Self.snippetLineCap {
                    let lower = detail.utf8.index(detail.utf8.startIndex, offsetBy: start)
                    let upper = detail.utf8.index(detail.utf8.startIndex, offsetBy: end)
                    append(detail[lower..<upper])
                }
                count += 1
                start = search
            }
            if out.count < Self.snippetLineCap {
                let lower = detail.utf8.index(detail.utf8.startIndex, offsetBy: start)
                append(detail[lower...])
            }
            return count
        }) {
            if lineCount > Self.snippetLineCap {
                out.append(L10n.text("apple.chatmodel.0_more.8bfcca49", "\(lineCount - Self.snippetLineCap)"))
            }
            return out
        }
        // Count the omitted lines without materializing them. LF is the
        // existing Character separator; CRLF is one different Character.
        // ASCII newline boundaries are also valid String slice boundaries.
        var start = detail.startIndex
        var index = detail.utf8.startIndex
        var previous: UInt8 = 0
        var lineCount = 1
        while index < detail.utf8.endIndex {
            let byte = detail.utf8[index]
            let next = detail.utf8.index(after: index)
            if byte == 10, previous != 13 {
                if out.count < Self.snippetLineCap { append(detail[start..<index]) }
                lineCount += 1
                start = next
            }
            previous = byte
            index = next
        }
        if out.count < Self.snippetLineCap { append(detail[start...]) }
        if lineCount > Self.snippetLineCap {
            out.append(L10n.text("apple.chatmodel.0_more.8bfcca49", "\(lineCount - Self.snippetLineCap)"))
        }
        return out
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
    static func clip<S: StringProtocol>(_ line: S) -> String {
        // A hostile grapheme may contain thousands of combining marks.
        // Bound scalars before the usual display-column clipping.
        let scalars = line.unicodeScalars.prefix(Self.snippetColumnCap * 4 + 1)
        let bounded = String(String.UnicodeScalarView(scalars.prefix(Self.snippetColumnCap * 4)))
        let prefix = bounded.prefix(Self.snippetColumnCap + 1)
        if scalars.count <= Self.snippetColumnCap * 4 && prefix.count <= Self.snippetColumnCap { return bounded }
        return String(prefix.prefix(Self.snippetColumnCap)) + "…"
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
struct ChatEditState: Equatable, Sendable {
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
struct ChatDisplayItem: Identifiable, Equatable, Sendable {
    var isSteer: Bool = false
    /// Settable only here, by `carrying(id:)`.
    private(set) var id: String
    let kind: Kind
    /// Inclusive end of a coalesced text/thinking block in the loaded archive.
    /// Lets a mark from a partial page resolve after earlier deltas arrive.
    var lastSequence: UInt64? = nil
    /// Where that block actually starts in the loaded archive. Usually what
    /// its id says, but not after `ChatRowContinuity` kept an id across a
    /// page that brought the block's earlier deltas.
    var firstSequence: UInt64? = nil
    var groupID: String? = nil
    /// How a step under an open Compact line is drawn. Nil everywhere else.
    var plainStep: PlainStep? = nil
    /// Presentation-only galleries. Raw attachment rows remain searchable.
    var imageAttachments: [ChatAttachment] = []
    /// Original attachment row anchors represented by this gallery.
    var imageRowIDs: [String] = []
    /// Backend provenance for explicit image/tool correlation.
    var sourceBackend: String? = nil
    /// One piece of a long reply drawn as several rows. See `ChatReplySplit`.
    var part: ChatReplyPart? = nil

    /// A Compact line already says what its step was, so a lone step drops
    /// its card and shows only what it produced. Several steps under one
    /// line, a run of reads, keep a plain line each so each names its file.
    enum PlainStep: Equatable, Sendable {
        case detail
        case line
    }

    enum Kind: Equatable, Sendable {
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
        /// The agent's plan as last reported. A newer report replaces the
        /// older row, so the checklist sits where the latest update arrived.
        case plan([ChatPlanStep])
    }
}

/// One line of a reported plan: its words and where it stands.
struct ChatPlanStep: Equatable, Sendable {
    var text: String
    var status: String
}

/// What one turn changed, file by file, from its edit rows.
///
/// Counts are summed over the turn's edits to a file, so a file edited
/// twice shows both. That is what the agent did, which is what this card
/// is about. The working tree's own totals live in the Changes panel.
struct ChatTurnChanges: Equatable, Sendable {
    struct File: Equatable, Sendable, Identifiable {
        let path: String
        var added: UInt64
        var removed: UInt64
        /// The recorded edits survive commits and later turns. Empty entries
        /// mean that the agent reported an edit without its patch.
        var patches: [String] = []
        var id: String { path }

        var fileName: String {
            let name = (path as NSString).lastPathComponent
            return name.isEmpty ? path : name
        }
    }

    let id: String
    var files: [File]

    var added: UInt64 { files.reduce(0) { $0 + $1.added } }
    var removed: UInt64 { files.reduce(0) { $0 + $1.removed } }
}

extension ChatDisplayItem {
    /// A low estimate of the row's height in points, for `TranscriptSlice.split`.
    ///
    /// The smallest each kind measured on a long chat of every kind of row:
    /// a one-line step 24, a usage line 14, a turn's changes 78, a plan 125
    /// (about 20 a step past its title), a picture 128. One guess for every
    /// row that is not text undercounted plans and pictures several times
    /// over, so the newest rows measured exactly did not cover the screen.
    var tailHeightFloor: Double {
        func prose(_ text: String) -> Double {
            var lines = 0
            var run = 0
            for unit in text.utf8 {
                if unit == 10 { lines += 1 + run / 140; run = 0 } else { run += 1 }
            }
            lines += 1 + run / 140
            return min(1200, Double(lines) * 16 + 24)
        }
        let gap: Double = 8
        switch kind {
        case let .user(text), let .thinking(text), let .failed(text): return prose(text) + gap
        case let .assistant(text, _): return prose(text) + gap
        case let .handoff(_, brief): return min(prose(brief), 60) + gap
        case .usage: return 14 + gap
        case .changes: return 78 + gap
        case let .plan(steps): return 40 + 20 * Double(steps.count) + gap
        case .attachment: return 128 + gap
        case .edit, .approval, .question: return 60 + gap
        default: return 20 + gap
        }
    }

    /// What the recent-message cache budgets a row at: the strings it holds,
    /// nested tool output and patches included, plus a fixed cost per row.
    ///
    /// `String(reflecting:)` arrived at a similar number by printing the
    /// whole row, nested types and all. That ran on the main thread for up to
    /// 150 rows every time a chat was left, and again for every preview a
    /// folder warmed, and was most of what leaving a long chat cost.
    var estimatedBytes: Int {
        let base = 96 + id.utf8.count
        switch kind {
        case let .user(text), let .turnSeparator(text), let .thinking(text), let .failed(text):
            return base + text.utf8.count
        case let .assistant(text, backend):
            return base + text.utf8.count + (backend?.utf8.count ?? 0)
        case let .handoff(to, brief):
            return base + to.utf8.count + brief.utf8.count
        case let .tool(tool):
            // The snippet is the detail split into lines, so the detail
            // already counts it.
            return base + tool.callId.utf8.count + tool.verb.utf8.count + tool.target.utf8.count
                + (tool.detail?.utf8.count ?? 0) + tool.snippet.count * 16
        case let .edit(edit):
            return base + edit.path.utf8.count + edit.patch.utf8.count
        case .attachment:
            // Metadata only. Downloaded bytes are never held here.
            return base + 256
        case .approval:
            return base + 512
        case .usage:
            return base
        case let .group(group):
            return base + group.memberIDs.reduce(0) { $0 + $1.utf8.count + 16 }
                + group.recentActivity.reduce(0) { $0 + $1.verb.utf8.count + $1.target.utf8.count + 32 }
        case let .question(question):
            return base + question.question.utf8.count + question.options.reduce(0) { $0 + $1.utf8.count }
                + (question.answer?.utf8.count ?? 0)
        case let .changes(changes):
            return base + changes.files.reduce(0) { total, file in
                total + file.path.utf8.count + file.patches.reduce(0) { $0 + $1.utf8.count }
            }
        case let .plan(steps):
            return base + steps.reduce(0) { $0 + $1.text.utf8.count + $1.status.utf8.count }
        }
    }
}

extension ChatDisplayItem {
    /// The same row under the identity it already had on screen.
    func carrying(id: String) -> ChatDisplayItem {
        var row = self
        row.id = id
        return row
    }
}

/// Keep a folded group's or an image gallery's identity when a page brings
/// rows in front of it.
///
/// Both are named after their first member. A page whose last rows belong to
/// the same group or gallery as the first rows on screen makes one of those
/// the new first member, and the row is renamed. To SwiftUI that is a row
/// removed and another inserted, which loses whatever was holding the
/// reader's place on it, and a group opened by hand closes again because
/// the open state is kept by id. A group that still holds a member it had
/// last time is that group, so it keeps the id it had.
///
/// One per transcript, handed to the fold through `current`, and reset when
/// the conversation changes: archive row ids repeat across conversations.
final class ChatFoldContinuity: @unchecked Sendable {
    @TaskLocal static var current: ChatFoldContinuity?

    private var previous: [String: String] = [:]
    private var next: [String: String] = [:]
    private var claimed: Set<String> = []

    /// The id for a group or gallery with these members. `kind` keeps the two
    /// apart: a gallery's member is a raw row, a group's member may be a
    /// gallery.
    func id(_ kind: String, members: [String], fresh: String) -> String {
        var chosen = fresh
        for member in members {
            if let was = previous[kind + "|" + member], !claimed.contains(was) {
                chosen = was
                break
            }
        }
        #if DEBUG
        if chosen != fresh { TranscriptHoldTrace.note("carry \(kind) \(fresh.prefix(20)) -> \(chosen.prefix(20))") }
        #endif
        claimed.insert(chosen)
        for member in members { next[kind + "|" + member] = chosen }
        return chosen
    }

    /// One fold is complete. What it named is what the next one starts from.
    func finish() {
        previous = next
        next = [:]
        claimed = []
    }

    func reset() {
        previous = [:]
        next = [:]
        claimed = []
    }
}


/// Where a row sits inside a long reply that is drawn as several rows.
struct ChatReplyPart: Equatable, Sendable {
    var index: Int
    var isFirst: Bool
    var isLast: Bool
    /// Paragraph spacing above this piece: the cut fell between blocks. A cut
    /// between two list items has none, so the list reads as one.
    var gapBefore: Bool
    /// The whole reply, for copying it.
    var reply: String
}

/// Long replies, drawn as several rows that read as one.
///
/// A reply of several hundred lines was one transcript row thousands of
/// points tall. The lazy stack only estimates rows it has not built, and an
/// estimate is an average: wrong by a screen or more when one row is a
/// sentence and the next is a whole document. Every time it built such a
/// row, the content above the reader changed height and the text under
/// their hand moved: on the first scroll from the latest message, and on
/// every step while reading back. Rows of bounded height keep the estimates
/// close, so the whole loaded history can stay built.
///
/// Cuts fall only between blocks: before a paragraph or heading after a
/// blank line, or before a top-level list item. Never inside a code fence,
/// a table or a quote. Which of those places is a cut depends on the line
/// that starts there, not on how far it is from the start, so a reply that
/// grows while it streams, or that gains its beginning when an earlier page
/// lands, keeps its other pieces and their ids.
enum ChatReplySplit {
    /// Weighted lines below which a reply stays one row.
    static let minimumLines = 90
    /// About one cut every N headings, paragraph starts, or list items.
    /// Pieces stay under a couple of screens without building a new row
    /// for every few lines scrolled.
    static let headingPeriod: UInt64 = 3
    static let paragraphPeriod: UInt64 = 8
    static let listPeriod: UInt64 = 40

    struct Piece: Equatable {
        var text: String
        var firstLine: String
        var gapBefore: Bool
    }

    /// The rows to draw: every long assistant reply replaced by its pieces.
    static func split(_ items: [ChatDisplayItem], cache: Cache? = nil) -> [ChatDisplayItem] {
        var out: [ChatDisplayItem] = []
        out.reserveCapacity(items.count)
        for item in items {
            guard case let .assistant(text, backend) = item.kind, item.part == nil else {
                out.append(item)
                continue
            }
            let pieces: [ChatDisplayItem]?
            if let cache, let hit = cache.rows(for: item, text: text) {
                pieces = hit
            } else {
                pieces = rows(for: item, text: text, backend: backend)
                cache?.store(pieces, for: item, text: text)
            }
            if let pieces { out += pieces } else { out.append(item) }
        }
        return out
    }

    /// The pieces of one reply as rows, or nil when it stays one row.
    static func rows(for item: ChatDisplayItem, text: String, backend: String?) -> [ChatDisplayItem]? {
        let pieces = pieces(text)
        guard pieces.count > 1 else { return nil }
        // A piece is named by the cut that ends it: the next piece's first
        // line. Text that arrives at a reply's start (an earlier page) grows
        // its first piece without moving that cut, and text that streams in
        // at its end grows the last, named "end". Either way the names of
        // the pieces already on screen hold.
        var seen: [String: Int] = [:]
        return pieces.enumerated().map { index, piece in
            var key = index + 1 < pieces.count ? digest(pieces[index + 1].firstLine) : "end"
            let repeatCount = seen[key, default: 0]
            seen[key] = repeatCount + 1
            if repeatCount > 0 { key += "-\(repeatCount)" }
            var row = ChatDisplayItem(
                id: "\(item.id)~\(key)",
                kind: .assistant(piece.text, backend: backend)
            )
            row.isSteer = item.isSteer
            row.lastSequence = item.lastSequence
            row.firstSequence = item.firstSequence
            row.groupID = item.groupID
            row.sourceBackend = item.sourceBackend
            row.part = ChatReplyPart(
                index: index, isFirst: index == 0, isLast: index == pieces.count - 1,
                gapBefore: piece.gapBefore, reply: text
            )
            return row
        }
    }

    /// The row id a reply's original id now lives at: itself, or its first
    /// piece. Search results and reading marks name the reply.
    static func rowID(for id: String, in rows: [ChatDisplayItem]) -> String? {
        if rows.contains(where: { $0.id == id }) { return id }
        let prefix = id + "~"
        return rows.first(where: { $0.id.hasPrefix(prefix) })?.id
    }

    static func pieces(_ text: String) -> [Piece] {
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
        var weighted = 0
        for line in lines { weighted += 1 + line.utf8.count / 110 }
        guard weighted >= minimumLines else { return [] }

        var cuts: [(line: Int, gap: Bool)] = []
        var inFence = false
        for (index, line) in lines.enumerated() {
            let trimmed = line.drop(while: { $0 == " " })
            let fence = trimmed.hasPrefix("```") || trimmed.hasPrefix("~~~")
            defer { if fence { inFence.toggle() } }
            // No minimum length: whether a line is a cut must depend on the
            // line alone, or text arriving at the reply's start would move
            // the cuts after it and rename the pieces on screen.
            guard index > 0, !inFence, !fence, !trimmed.isEmpty else { continue }
            let previous = lines[index - 1]
            let previousTrimmed = previous.drop(while: { $0 == " " })
            let indented = line.first == " " || line.first == "\t"
            if indented || trimmed.hasPrefix("|") || trimmed.hasPrefix(">") { continue }
            let afterBlank = previousTrimmed.isEmpty
            let heading = afterBlank && trimmed.hasPrefix("#")
            let listItem = !afterBlank && isListItem(line) && !previousTrimmed.hasPrefix("|")
                && !previousTrimmed.hasPrefix(">")
            guard afterBlank || listItem else { continue }
            let period = heading ? headingPeriod : listItem ? listPeriod : paragraphPeriod
            let chosen = hash(line) % period == 0
            guard chosen else { continue }
            cuts.append((index, afterBlank))
        }
        guard !cuts.isEmpty else { return [] }

        var pieces: [Piece] = []
        var start = 0
        var gap = false
        for cut in cuts + [(line: lines.count, gap: false)] {
            let body = lines[start..<cut.line].joined(separator: "\n")
            let trimmedBody = body.trimmingCharacters(in: .newlines)
            if !trimmedBody.isEmpty {
                let first = lines[start..<cut.line].first { !$0.allSatisfy(\.isWhitespace) } ?? ""
                pieces.append(Piece(text: trimmedBody, firstLine: String(first), gapBefore: gap))
            }
            start = cut.line
            gap = cut.gap
        }
        return pieces
    }

    private static func isListItem(_ line: Substring) -> Bool {
        guard let first = line.first else { return false }
        if first == "-" || first == "*" || first == "+" {
            return line.dropFirst().first == " "
        }
        var rest = line[...]
        var digits = 0
        while let ch = rest.first, ch.isASCII, ch.isNumber {
            digits += 1
            rest = rest.dropFirst()
        }
        guard digits > 0, let mark = rest.first, mark == "." || mark == ")" else { return false }
        return rest.dropFirst().first == " "
    }

    /// FNV-1a, stable across launches, so a piece keeps its id.
    private static func hash(_ text: Substring) -> UInt64 {
        var value: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in text.utf8 {
            value ^= UInt64(byte)
            value = value &* 0x100_0000_01b3
        }
        return value
    }

    private static func digest(_ text: String) -> String {
        String(hash(text[...]) % 2_176_782_336, radix: 36)
    }

    /// The last split of each reply, so a settled reply is not scanned again
    /// on every poll. Keyed by row id and checked against the text.
    final class Cache {
        private var entries: [String: (count: Int, tail: Substring, rows: [ChatDisplayItem]?)] = [:]

        func rows(for item: ChatDisplayItem, text: String) -> [ChatDisplayItem]?? {
            guard let entry = entries[item.id], entry.count == text.utf8.count,
                  entry.tail == text.suffix(48) else { return nil }
            guard var rows = entry.rows else { return .some(nil) }
            // Fields other than the text can change under a settled reply.
            for index in rows.indices {
                rows[index].isSteer = item.isSteer
                rows[index].lastSequence = item.lastSequence
                rows[index].firstSequence = item.firstSequence
                rows[index].groupID = item.groupID
            }
            return .some(rows)
        }

        func store(_ rows: [ChatDisplayItem]?, for item: ChatDisplayItem, text: String) {
            if entries.count > 2_000 { entries.removeAll(keepingCapacity: true) }
            entries[item.id] = (text.utf8.count, text.suffix(48), rows)
        }

        func reset() { entries.removeAll(keepingCapacity: true) }
    }
}
