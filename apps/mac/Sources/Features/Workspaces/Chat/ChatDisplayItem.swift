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
    var snippet: [String]

    var duration: String? {
        ChatClock.duration(from: startedAtMs, to: endedAtMs)
    }

    static func isFileEditVerb(_ verb: String) -> Bool {
        verb == "Edit" || verb == "NotebookEdit"
    }

    static func makeSnippet(verb: String, detail: String?) -> [String] {
        guard let detail, !detail.isEmpty else { return [] }
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
        let scalars = line.unicodeScalars.prefix(Self.snippetColumnCap * 4 + 1)
        let bounded = String(String.UnicodeScalarView(scalars.prefix(Self.snippetColumnCap * 4)))
        let prefix = bounded.prefix(Self.snippetColumnCap + 1)
        if scalars.count <= Self.snippetColumnCap * 4 && prefix.count <= Self.snippetColumnCap { return bounded }
        return String(prefix.prefix(Self.snippetColumnCap)) + "…"
    }

    private static let snippetLineCap = 60
    private static let snippetColumnCap = 600
}

struct ChatEditState: Equatable, Sendable {
    var path: String
    var added: UInt32
    var removed: UInt32
    var patch: String
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

    var location: String {
        let folder = (path as NSString).deletingLastPathComponent
        let last = (folder as NSString).lastPathComponent
        let grand = ((folder as NSString).deletingLastPathComponent as NSString).lastPathComponent
        if last.isEmpty || last == "/" { return "" }
        if grand.isEmpty || grand == "/" { return last }
        return "\(grand)/\(last)"
    }

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

struct ChatDisplayItem: Identifiable, Equatable, Sendable {
    var isSteer: Bool = false
    private(set) var id: String
    let kind: Kind
    var lastSequence: UInt64? = nil
    var firstSequence: UInt64? = nil
    var groupID: String? = nil
    var plainStep: PlainStep? = nil
    var imageAttachments: [ChatAttachment] = []
    var imageRowIDs: [String] = []
    var sourceBackend: String? = nil
    var part: ChatReplyPart? = nil

    enum PlainStep: Equatable, Sendable {
        case detail
        case line
    }

    enum Kind: Equatable, Sendable {
        case user(String)
        case assistant(String, backend: String?)
        case turnSeparator(String)
        case handoff(to: String, brief: String)
        case thinking(String)
        case tool(ChatToolState)
        case edit(ChatEditState)
        case attachment(ChatAttachment)
        case approval(ChatApproval)
        case usage(input: UInt64, output: UInt64, cost: Double?)
        case failed(String)
        case group(ChatStepGroup)
        case question(ChatQuestion)
        case changes(ChatTurnChanges)
        case plan([ChatPlanStep])
    }
}

struct ChatPlanStep: Equatable, Sendable {
    var text: String
    var status: String
}

struct ChatTurnChanges: Equatable, Sendable {
    struct File: Equatable, Sendable, Identifiable {
        let path: String
        var added: UInt64
        var removed: UInt64
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

    /// Every file the loaded turns changed, one row per path with its totals.
    static func merged(_ items: [ChatDisplayItem]) -> ChatTurnChanges? {
        var order: [String] = []
        var byPath: [String: File] = [:]
        for item in items {
            guard case let .changes(turn) = item.kind else { continue }
            for file in turn.files {
                if var known = byPath[file.path] {
                    known.added += file.added
                    known.removed += file.removed
                    known.patches += file.patches
                    byPath[file.path] = known
                } else {
                    order.append(file.path)
                    byPath[file.path] = file
                }
            }
        }
        guard !order.isEmpty else { return nil }
        return ChatTurnChanges(id: "chat", files: order.compactMap { byPath[$0] })
    }
}

extension ChatDisplayItem {
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
            return base + tool.callId.utf8.count + tool.verb.utf8.count + tool.target.utf8.count
                + (tool.detail?.utf8.count ?? 0) + tool.snippet.count * 16
        case let .edit(edit):
            return base + edit.path.utf8.count + edit.patch.utf8.count
        case .attachment:
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


struct ChatReplyPart: Equatable, Sendable {
    var index: Int
    var isFirst: Bool
    var isLast: Bool
    var gapBefore: Bool
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
    static let minimumLines = 90
    static let headingPeriod: UInt64 = 3
    static let paragraphPeriod: UInt64 = 8
    static let listPeriod: UInt64 = 40

    struct Piece: Equatable {
        var text: String
        var firstLine: String
        var gapBefore: Bool
    }

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

    static func rows(for item: ChatDisplayItem, text: String, backend: String?) -> [ChatDisplayItem]? {
        let pieces = pieces(text)
        guard pieces.count > 1 else { return nil }
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

    final class Cache {
        private var entries: [String: (count: Int, tail: Substring, rows: [ChatDisplayItem]?)] = [:]

        func rows(for item: ChatDisplayItem, text: String) -> [ChatDisplayItem]?? {
            guard let entry = entries[item.id], entry.count == text.utf8.count,
                  entry.tail == text.suffix(48) else { return nil }
            guard var rows = entry.rows else { return .some(nil) }
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
