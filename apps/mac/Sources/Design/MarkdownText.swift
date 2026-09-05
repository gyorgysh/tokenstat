// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
//
// Source-available for review, NOT open source. See LICENSE: no rights to
// redistribute, publish, or ship a build are granted. Read it, study it, run
// your own build of it.
// "tokenstat" is a trademark of pueev OU. See TRADEMARK.md.

import Foundation
import SwiftUI
#if os(macOS)
import AppKit
#else
import UIKit
#endif

/// Small, read-only Markdown for pull-request conversations and chat.
///
/// This is deliberately a renderer rather than a web view. GitHub bodies are
/// untrusted text: supported block HTML is converted to native Markdown,
/// unknown tags are discarded, and remote images become links, so opening a
/// conversation never contacts a host the person did not choose. The block
/// parser owns the handful of shapes these conversations need while
/// `AttributedString` handles inline emphasis, code spans and links.
struct MarkdownText: View {
    private let blocks: [MarkdownBlock]
    private let bodyFont: Font
    private let codeFont: Font
    private let style: MarkdownStyle

    init(
        _ markdown: String,
        bodyFont: Font = Theme.body,
        codeFont: Font = Theme.monoText(12, relativeTo: .body),
        style: MarkdownStyle = .document
    ) {
        blocks = MarkdownCache.blocks.value(for: markdown) {
            var parser = MarkdownParser(markdown)
            return parser.blocks()
        }
        self.bodyFont = bodyFont
        self.codeFont = codeFont
        self.style = style
    }

    // A plain stack, deliberately. One message is a handful of blocks, and a
    // lazy stack inside the transcript's own lazy stack is measured against
    // an unbounded proposal by a parent that is itself still deciding how
    // tall it is. That is not laziness, it is a layout the engine has to keep
    // re-solving, and a long conversation of them is how the chat pane hung.
    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.m) {
            ForEach(blocks) { block in
                MarkdownBlockView(
                    block: block,
                    bodyFont: bodyFont,
                    codeFont: codeFont,
                    style: style
                )
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

extension MarkdownText {
    /// Parse these bodies now, off the main thread, so that nothing has to be
    /// parsed later while a row is being laid out.
    ///
    /// This is the whole fix for a scroll that hitches on a long pull request.
    /// A conversation's rows are lazy, so a body is parsed the first time it
    /// scrolls into view, and the parse happens inside `init` on the main
    /// thread, in the middle of a layout pass. A Dependabot release note is
    /// twenty kilobytes of HTML, and turning it into blocks and then into
    /// attributed runs is tens of milliseconds of regular expressions. Doing
    /// that on the frame the row appears is exactly the stall a reader feels.
    ///
    /// Everything here is a pure function of the text and the caches are
    /// `NSCache`, which is thread safe, so the only thing that changes is when
    /// the work happens. If a row is reached before its warm finishes it parses
    /// itself as before and the warm finds the answer already there.
    static func warm(_ sources: [String]) {
        let pending = sources.filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        guard !pending.isEmpty else { return }
        Task.detached(priority: .utility) {
            for source in pending {
                let blocks = MarkdownCache.blocks.value(for: source) {
                    var parser = MarkdownParser(source)
                    return parser.blocks()
                }
                for block in blocks {
                    switch block.kind {
                    case let .heading(_, text):
                        _ = MarkdownInline.attributed(text)
                    case let .paragraph(text):
                        _ = MarkdownInline.attributed(text)
                    case let .quote(text):
                        _ = MarkdownInline.attributed(text)
                    case let .list(items):
                        for item in items { _ = MarkdownInline.attributed(item.text) }
                    case let .table(header, rows):
                        for cell in header { _ = MarkdownInline.attributed(cell) }
                        for row in rows {
                            for cell in row { _ = MarkdownInline.attributed(cell) }
                        }
                    case .code, .rule:
                        break
                    }
                }
            }
        }
    }
}

/// Whether this markdown is the point of the screen or a note beside it.
///
/// `document` is an answer: a document's own title scale, and wide content
/// gets its own sideways scroller so a table or a long line keeps its shape.
///
/// `aside` is reasoning, drawn small and grey. Headings come back to the
/// surrounding text's size, because `##` at 22pt would make a footnote the
/// largest thing on screen, and wide content wraps in place rather than
/// nesting another scroll view inside the transcript's.
enum MarkdownStyle {
    case document
    case aside
}

/// Parsed markdown, kept between draws.
///
/// Both parses here are pure functions of the source text, and a transcript
/// rebuilds its rows whenever anything about the conversation changes. Parsing
/// the same paragraph again on every draw is the largest single cost in
/// showing a long chat, and the answer never differs.
///
/// `NSCache` because it is thread safe and gives the memory back under
/// pressure, which matters when the text being held is a whole conversation.
private final class ParsedTextCache<Value> {
    private final class Held {
        let value: Value
        init(_ value: Value) { self.value = value }
    }

    private let cache = NSCache<NSString, Held>()

    init(limit: Int) {
        cache.countLimit = limit
    }

    func value(for source: String, parse: () -> Value) -> Value {
        let key = source as NSString
        if let held = cache.object(forKey: key) { return held.value }
        let parsed = parse()
        cache.setObject(Held(parsed), forKey: key)
        return parsed
    }

    /// For an answer that cannot be produced here, such as one that has to be
    /// asked for.
    func stored(for source: String) -> Value? {
        cache.object(forKey: source as NSString)?.value
    }

    func store(_ value: Value, for source: String) {
        cache.setObject(Held(value), forKey: source as NSString)
    }
}

private enum MarkdownCache {
    // Sized for a conversation being read back, not for one being read. A
    // reader who pages to the beginning and scrolls forward again crosses
    // every row twice, and a cache that evicted on the way up parses the
    // whole conversation a second time on the way down. These hold structs,
    // and `NSCache` gives the memory back under pressure.
    /// One entry per assistant message and per thinking block, roughly.
    static let blocks = ParsedTextCache<[MarkdownBlock]>(limit: 1500)
    /// One entry per paragraph, list row and table cell, so several per block.
    static let inline = ParsedTextCache<AttributedString>(limit: 6000)
    /// Finished, coloured code, keyed by the fence's digest.
    ///
    /// Spans used to be cached here and turned into a `Text` chain inside a
    /// computed property, which meant every visible fence re-sorted its spans
    /// and rebuilt its whole string on every pass of the enclosing view's
    /// body. During a scroll that is once a frame per fence, and it is what
    /// made a conversation full of code hitch. The colouring is now done once
    /// and what is kept is the answer.
    static let rendered = ParsedTextCache<AttributedString>(limit: 600)
    /// Parsed diff fences, keyed by the fence's source.
    static let diffs = ParsedTextCache<FileDiff>(limit: 300)
    /// Finished prose chains per message, keyed by the caller's font set,
    /// style and markdown (see `MessageMarkdown`). A whole-card hover or a
    /// scroll re-runs the row's `init`, and without this every one of those
    /// rebuilt every `Text` chain of the reply from scratch.
    static let segments = ParsedTextCache<[MessageSegment]>(limit: 800)
}

/// A short, stable name for a piece of text.
///
/// FNV-1a, the same function the host uses for its own stable ids. The point
/// is length: a fence's key is a dozen characters, so using it as a cache key
/// or as a `task(id:)` costs nothing, where the fence's own source costs a
/// walk of the whole thing every time it is compared.
private enum MarkdownDigest {
    static func key(_ language: String?, _ text: String) -> String {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in text.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x0000_0100_0000_01b3
        }
        return "\(language ?? "plain").\(String(hash, radix: 36))"
    }
}

private actor MarkdownHighlightLimiter {
    static let shared = MarkdownHighlightLimiter(limit: 2)
    private let limit: Int
    private var inFlight = 0
    private var waiters: [CheckedContinuation<Void, Never>] = []

    init(limit: Int) { self.limit = limit }

    func wait() async {
        if inFlight < limit {
            inFlight += 1
            return
        }
        await withCheckedContinuation { c in waiters.append(c) }
    }

    func signal() {
        if let next = waiters.first {
            waiters.removeFirst()
            next.resume()
        } else {
            inFlight = max(0, inFlight - 1)
        }
    }
}

private struct MarkdownBlock: Identifiable {
    enum Kind {
        case heading(level: Int, text: String)
        case paragraph(String)
        case list([MarkdownListItem])
        case quote(String)
        /// `key` is a short digest of the language and the source, worked out
        /// once when the block is parsed. Everything downstream that needs to
        /// identify this fence uses it, so no drawing pass ever hashes,
        /// compares or concatenates the fence's whole text again. `widest` is
        /// the longest line in characters, which decides whether this fence
        /// needs a scroller of its own.
        case code(language: String?, text: String, key: String, widest: Int)
        case rule
        case table(header: [String], rows: [[String]])
    }

    let id: Int
    let kind: Kind
}

private struct MarkdownListItem {
    let depth: Int
    let ordinal: Int?
    let checked: Bool?
    let text: String
}

private struct MarkdownBlockView: View {
    let block: MarkdownBlock
    let bodyFont: Font
    let codeFont: Font
    var style: MarkdownStyle = .document

    @ViewBuilder
    var body: some View {
        switch block.kind {
        case let .heading(level, text):
            InlineMarkdown(text, font: headingFont(level))
                .padding(.top, level <= 2 ? Theme.Space.xs : 0)
        case let .paragraph(text):
            InlineMarkdown(text, font: bodyFont)
        case let .list(items):
            VStack(alignment: .leading, spacing: Theme.Space.s) {
                ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                    MarkdownListRow(item: item, bodyFont: bodyFont)
                }
            }
        case let .quote(text):
            HStack(alignment: .top, spacing: Theme.Space.m) {
                RoundedRectangle(cornerRadius: 2, style: .continuous)
                    .fill(
                        LinearGradient(
                            colors: [Theme.accent, Theme.secondary],
                            startPoint: .top,
                            endPoint: .bottom
                        )
                    )
                    .frame(width: 3)
                InlineMarkdown(text, font: bodyFont)
                    .foregroundStyle(.secondary)
            }
            .padding(.vertical, Theme.Space.xs)
            .padding(.horizontal, Theme.Space.m)
            .background(Theme.accentSoft.opacity(0.62))
            .clipShape(RoundedRectangle(cornerRadius: Theme.cardRadius - 4, style: .continuous))
        case let .code(language, text, key, widest):
            MarkdownCodeBlock(language: language, source: text, key: key, widest: widest, font: codeFont, style: style)
        case .rule:
            Capsule(style: .continuous)
                .fill(
                    LinearGradient(
                        colors: [Theme.accent.opacity(0.08), Theme.accent.opacity(0.42), Theme.secondary.opacity(0.10)],
                        startPoint: .leading,
                        endPoint: .trailing
                    )
                )
                .frame(height: 1)
                .padding(.vertical, Theme.Space.xs)
        case let .table(header, rows):
            MarkdownTable(header: header, rows: rows, bodyFont: bodyFont)
        }
    }

    private func headingFont(_ level: Int) -> Font {
        switch style {
        case .aside:
            return bodyFont.weight(level <= 2 ? .bold : .semibold)
        case .document:
            switch level {
            case 1: return Theme.title
            case 2: return Theme.title2
            case 3: return Theme.title3
            default: return Theme.headline
            }
        }
    }
}

private struct MarkdownListRow: View {
    let item: MarkdownListItem
    let bodyFont: Font

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: Theme.Space.s) {
            marker
                .frame(width: 20, alignment: .trailing)
            InlineMarkdown(item.text, font: bodyFont)
        }
        .padding(.leading, CGFloat(item.depth) * Theme.Space.l)
    }

    @ViewBuilder
    private var marker: some View {
        if let checked = item.checked {
            Image(systemName: checked ? "checkmark.square.fill" : "square")
                .font(Theme.font(13, weight: .semibold, relativeTo: .body))
                .foregroundStyle(checked ? Theme.accent : Theme.stateIdle)
                .accessibilityLabel(checked ? "Completed" : "Not completed")
        } else if let ordinal = item.ordinal {
            Text("\(ordinal).")
                .font(Theme.numeric(11, weight: .semibold))
                .foregroundStyle(Theme.accent)
        } else {
            Circle()
                .fill(Theme.accent)
                .frame(width: 5, height: 5)
                .accessibilityHidden(true)
        }
    }
}

/// One run of inline markdown, parsed once and kept.
///
/// Separated from the view so the same work can be done ahead of time, off the
/// main thread, by `MarkdownText.warm`.
private enum MarkdownInline {
    static func attributed(_ source: String) -> AttributedString {
        MarkdownCache.inline.value(for: source) {
            let safe = MarkdownSanitizer.inline(source)
            let options = AttributedString.MarkdownParsingOptions(
                interpretedSyntax: .inlineOnlyPreservingWhitespace,
                failurePolicy: .returnPartiallyParsedIfPossible
            )
            return (try? AttributedString(markdown: safe, options: options)) ?? AttributedString(source)
        }
    }
}

private struct InlineMarkdown: View {
    private let attributed: AttributedString
    private let font: Font

    init(_ source: String, font: Font) {
        self.font = font
        attributed = MarkdownInline.attributed(source)
    }

    var body: some View {
        Text(attributed)
            .font(font)
            .tint(Theme.accent)
            .textSelection(.enabled)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// A chat message body whose prose selects as one element.
///
/// Separate SwiftUI `Text` views are each their own selection: a drag that
/// starts in one paragraph dies at its end, which is why responses only ever
/// selected a line or a bullet at a time. `Text` values joined with `+` are
/// the opposite: one element, one selection, mixed styling intact. So every
/// prose block here (headings, paragraphs, list items) joins a single chain
/// and one mouse drag covers the whole reply, line breaks and bullets
/// included. Anything that cannot live inline (fences with backgrounds and
/// scrollers, tables, quotes, rules) keeps its own view between chains and
/// stays individually selectable with its own copy action.
///
/// One chain never grows without bound: a whole reply as a single `Text`
/// lays out up front on the main thread, which is exactly the stall that
/// used to freeze long readers. Chains flush every few thousand characters
/// (at block boundaries, sooner for pathological blocks), so a drag covers
/// a long stretch and a novel-length reply stays a row of cheap ones.
/// One prose chain or one block needing its own view. File scope so the
/// segment cache can hold finished chains across view inits.
private enum MessageSegment {
    case text(Text)
    case block(MarkdownBlock)
}

struct MessageMarkdown: View {
    private let cachedSegments: [MessageSegment]
    private let bodyFont: Font
    private let codeFont: Font
    private let style: MarkdownStyle
    /// Selectable text owns a SelectionOverlay per chain and a hit-test
    /// entry per chain. On the one row that is rewritten on every token
    /// that is rebuilt 2.5x a second for the whole reply; settled rows
    /// keep it, the live row gets it back when the turn ends.
    private let selectable: Bool

    init(
        _ markdown: String,
        bodyFont: Font = Theme.body,
        codeFont: Font = Theme.monoText(12, relativeTo: .body),
        style: MarkdownStyle = .document,
        selectable: Bool = true,
        cacheScope: String = "chat"
    ) {
        let parsed = MarkdownCache.blocks.value(for: markdown) {
            var parser = MarkdownParser(markdown)
            return parser.blocks()
        }
        self.bodyFont = bodyFont
        self.codeFont = codeFont
        self.style = style
        self.selectable = selectable
        // Built once per message text and held across inits. A whole-card
        // hover or a scroll re-runs this `init` without changing the text;
        // rebuilding every `Text` chain there was the per-edge cost that
        // brought the hitches back. The scope names the caller's font set,
        // which is baked into the chains and cannot be keyed from `Font`.
        let key = "\(cacheScope):\(style == .aside ? "a" : "d"):\(markdown)"
        cachedSegments = MarkdownCache.segments.value(for: key) {
            Self.makeSegments(blocks: parsed, bodyFont: bodyFont, style: style)
        }
    }

    /// Characters per selectable chain. Long enough that a normal reply is
    /// one drag, short enough that no single `Text` ever costs a frame.
    private static let chainCharCap = 8000

    private static func makeSegments(blocks: [MarkdownBlock], bodyFont: Font, style: MarkdownStyle) -> [MessageSegment] {
        var out: [MessageSegment] = []
        var chain: Text? = nil
        var chainLength = 0
        func gap() -> Text { Text("\n\n").font(bodyFont) }
        func flush() {
            if let current = chain {
                out.append(.text(current))
                chain = nil
                chainLength = 0
            }
        }
        func push(_ piece: Text, length: Int, separator: Text? = nil) {
            if chain != nil, chainLength + length > Self.chainCharCap {
                flush()
            }
            if let current = chain {
                chain = current + (separator ?? gap()) + piece
                chainLength += length + 2
            } else {
                chain = piece
                chainLength = length
            }
        }
        /// Split an oversized block on blank lines (then lines), so no
        /// single piece can blow past the cap on its own.
        func chunks(_ text: String) -> [String] {
            if text.count <= Self.chainCharCap { return [text] }
            var pieces: [String] = []
            for para in text.components(separatedBy: "\n\n") {
                if para.count <= Self.chainCharCap {
                    if !para.isEmpty { pieces.append(para) }
                    continue
                }
                var current = ""
                for line in para.components(separatedBy: "\n") {
                    if !current.isEmpty, current.count + 1 + line.count > Self.chainCharCap {
                        pieces.append(current)
                        current = ""
                    }
                    current = current.isEmpty ? line : current + "\n" + line
                }
                if !current.isEmpty { pieces.append(current) }
            }
            return pieces.isEmpty ? [text] : pieces
        }
        func listRow(_ item: MarkdownListItem, text: AttributedString) -> Text {
            var row = Text(String(repeating: "  ", count: item.depth * 2))
                .font(bodyFont)
            if item.checked != nil {
                row = row + Text(item.checked == true ? "☑ " : "☐ ")
                    .font(bodyFont)
                    .foregroundStyle(Theme.accent)
            } else if let ordinal = item.ordinal {
                row = row + Text("\(ordinal). ")
                    .font(Theme.numeric(11, weight: .semibold))
                    .foregroundStyle(Theme.accent)
            } else {
                row = row + Text("• ")
                    .font(bodyFont)
                    .foregroundStyle(Theme.accent)
            }
            return row + Text(text).font(bodyFont)
        }
        for block in blocks {
            switch block.kind {
            case let .heading(level, text):
                push(
                    Text(MarkdownInline.attributed(text))
                        .font(Self.headingFont(style: style, bodyFont: bodyFont, level: level)),
                    length: text.count
                )
            case let .paragraph(text):
                for chunk in chunks(text) {
                    push(
                        Text(MarkdownInline.attributed(chunk))
                            .font(bodyFont),
                        length: chunk.count
                    )
                }
            case let .list(items):
                let total = items.reduce(0) { $0 + $1.text.count }
                if total <= Self.chainCharCap {
                    var list: Text? = nil
                    for item in items {
                        let row = listRow(item, text: MarkdownInline.attributed(item.text))
                        if let acc = list {
                            list = acc + Text("\n").font(bodyFont) + row
                        } else {
                            list = row
                        }
                    }
                    if let list { push(list, length: total) }
                } else {
                    // Huge lists chain item by item; a giant item chunks
                    // further, marker on its first piece only.
                    for (index, item) in items.enumerated() {
                        let parts = chunks(item.text)
                        for (part, chunk) in parts.enumerated() {
                            let piece = (part == 0)
                                ? listRow(item, text: MarkdownInline.attributed(chunk))
                                : Text(MarkdownInline.attributed(chunk)).font(bodyFont)
                            push(
                                piece,
                                length: chunk.count,
                                separator: index == 0 && part == 0
                                    ? nil : Text("\n").font(bodyFont)
                            )
                        }
                    }
                }
            case .code, .table, .quote, .rule:
                flush()
                out.append(.block(block))
            }
        }
        flush()
        return out
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.m) {
            ForEach(Array(cachedSegments.enumerated()), id: \.offset) { _, segment in
                switch segment {
                case let .text(chain):
                    Group {
                        if selectable {
                            chain
                                .tint(Theme.accent)
                                .textSelection(.enabled)
                                .fixedSize(horizontal: false, vertical: true)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        } else {
                            chain
                                .tint(Theme.accent)
                                .fixedSize(horizontal: false, vertical: true)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                case let .block(block):
                    MarkdownBlockView(
                        block: block,
                        bodyFont: bodyFont,
                        codeFont: codeFont,
                        style: style
                    )
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private static func headingFont(style: MarkdownStyle, bodyFont: Font, level: Int) -> Font {
        switch style {
        case .aside:
            return bodyFont.weight(level <= 2 ? .bold : .semibold)
        case .document:
            switch level {
            case 1: return Theme.title
            case 2: return Theme.title2
            case 3: return Theme.title3
            default: return Theme.headline
            }
        }
    }
}

private struct MarkdownCodeBlock: View {
    let language: String?
    let source: String
    /// The fence's digest, from the parser. Cheap to compare and to hash.
    let key: String
    /// The longest line, in characters.
    let widest: Int
    let font: Font
    var style: MarkdownStyle = .document

    @State private var coloured: AttributedString?
    @State private var hovering = false

    private var isDiff: Bool {
        ["diff", "patch"].contains(language?.lowercased())
    }

    /// Whether this fence gets a scroller of its own.
    ///
    /// On macOS every `ScrollView` is a real `NSScrollView`, with a clip view,
    /// scrollers and its own place in event routing, and a conversation full
    /// of fences put a dozen of them inside the one the reader is actually
    /// using. Most fences do not need it: a shell one-liner or a small JSON
    /// object fits any pane this app opens in. So the scroller is bought only
    /// for a fence wide enough to want it, measured in characters at parse
    /// time, and everything narrower is a plain wrapping `Text`.
    ///
    /// An aside never gets one. The fixed size inside a scroller is what keeps
    /// a line's shape, and it is also what would propose an unbounded width to
    /// the transcript around it.
    private var needsScroller: Bool {
        style == .document && widest > 54
    }

    /// One parsed diff per fence, held across the evaluations a scroll causes.
    private static func parsed(_ source: String) -> FileDiff {
        MarkdownCache.diffs.value(for: source) {
            FileDiff.fromEditPatch(path: "Change", patch: source)
        }
    }

    /// What to draw right now: the coloured version if it has arrived, the
    /// plain one otherwise.
    ///
    /// Both are looked up by the short key, so a fence that has been on screen
    /// before costs one small hash and no string work at all. This used to
    /// build a fresh `Text` chain out of the whole source on every evaluation.
    private var shown: AttributedString {
        if let coloured { return coloured }
        if let done = MarkdownCache.rendered.stored(for: "c" + key) { return done }
        return MarkdownCache.rendered.value(for: "p" + key) { AttributedString(source) }
    }

    var body: some View {
        Group {
            if isDiff {
                MarkdownSideways {
                    // Parsed by the cache rather than here: this ran on every
                    // evaluation, and a fence is evaluated on every measuring
                    // pass the transcript makes over the message holding it.
                    // Not lazy, for the reason on `DiffBody.lazy`: a lazy
                    // stack nested inside the transcript's own turns one row
                    // into hundreds of items to re-stamp through the graph.
                    DiffBody(diff: Self.parsed(source), lazy: false)
                        .padding(.vertical, Theme.Space.xs)
                }
            } else {
                VStack(alignment: .leading, spacing: 0) {
                    if let language {
                        HStack(spacing: Theme.Space.s) {
                            Text(language.uppercased())
                                .font(Theme.mono(10, weight: .semibold))
                                .foregroundStyle(Theme.accent)
                            Spacer(minLength: 0)
                            #if os(macOS)
                            RowCopyButton(text: source, help: "Copy code", visible: hovering)
                            #else
                            RowCopyButton(text: source, help: "Copy code")
                            #endif
                        }
                        .padding(.horizontal, Theme.Space.m)
                        .padding(.vertical, Theme.Space.s)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(Theme.accentSoft)
                    }

                    // An aside wraps its code instead of scrolling it. The
                    // fixed size below is what makes the line keep its shape
                    // inside a scroller, and it is also what would propose an
                    // unbounded width to the transcript around it.
                    if needsScroller {
                        ScrollView(.horizontal) {
                            Text(shown)
                                .font(font)
                                .textSelection(.enabled)
                                .fixedSize(horizontal: true, vertical: false)
                                .padding(Theme.Space.m)
                        }
                    } else {
                        Text(shown)
                            .font(font)
                            .textSelection(.enabled)
                            .padding(Theme.Space.m)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }
        }
        .background(Theme.panel)
        .clipShape(RoundedRectangle(cornerRadius: Theme.cardRadius - 2, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: Theme.cardRadius - 2, style: .continuous)
                .stroke(Theme.border, lineWidth: 1)
        }
        #if os(macOS)
        .overlay(alignment: .topTrailing) {
            // Fences without a language have no header row; the copy action
            // lives overlaid instead, on the same block hover.
            if language == nil {
                RowCopyButton(text: source, help: "Copy code", visible: hovering)
                    .padding(Theme.Space.xs)
            }
        }
        .onHover { hovering = $0 }
        #endif
        .contextMenu {
            Button("Copy code") { ChatClipboard.copy(source) }
        }
        .task(id: key) {
            // `ForEach` identifies blocks by their position in one message.
            // When a streaming message edits a fence in place SwiftUI keeps
            // this view's state, so the colour from the old fence must not win
            // over the new source while its own highlight is being fetched.
            coloured = nil
            if let done = MarkdownCache.rendered.stored(for: "c" + key) {
                coloured = done
                return
            }
            guard let path = highlightPath else { return }
            // A flick through a long conversation builds dozens of fences in
            // a second. Cap concurrent highlights so the scroll, not the
            // host, gets the thread.
            await MarkdownHighlightLimiter.shared.wait()
            guard !Task.isCancelled else {
                await MarkdownHighlightLimiter.shared.signal()
                return
            }
            try? await Task.sleep(for: .milliseconds(140))
            guard !Task.isCancelled else {
                await MarkdownHighlightLimiter.shared.signal()
                return
            }
            let result = try? await Bridge.highlight(path: path, text: source)
            await MarkdownHighlightLimiter.shared.signal()
            guard !Task.isCancelled, let spans = result?.spans else { return }
            // An empty answer is still an answer, and it is stored as the
            // plain text. Otherwise a fence the highlighter has nothing to say
            // about asks it again every time it scrolls back into view.
            let text = spans.isEmpty
                ? MarkdownCache.rendered.value(for: "p" + key) { AttributedString(source) }
                : Self.colouring(source, with: spans)
            MarkdownCache.rendered.store(text, for: "c" + key)
            coloured = text
        }
    }

    /// The highlighter detects a language from a filename. Common fence names
    /// are normalised to an extension; an unknown tag stays honest plain text.
    private var highlightPath: String? {
        guard let language = language?.lowercased() else { return nil }
        let extensionByFence = [
            "bash": "sh", "cjs": "js", "html": "html", "javascript": "js",
            "js": "js", "json": "json", "jsonc": "json", "jsx": "jsx",
            "markdown": "md", "md": "md", "mdx": "mdx", "mjs": "js",
            "py": "py", "python": "py", "rs": "rs", "rust": "rs",
            "shell": "sh", "sh": "sh", "swift": "swift", "toml": "toml",
            "ts": "ts", "tsx": "tsx", "typescript": "ts", "yaml": "yaml",
            "yml": "yml", "zsh": "zsh", "css": "css", "go": "go",
        ]
        guard let ext = extensionByFence[language] else { return nil }
        return "pull-request-fence.\(ext)"
    }

    /// Paint the spans onto the source, once. Called from the task that
    /// fetched them, never from a body.
    private static func colouring(_ source: String, with spans: [SyntaxSpan]) -> AttributedString {
        let string = source as NSString
        let length = string.length
        var cursor = 0
        var result = AttributedString()

        for span in spans.sorted(by: { $0.start < $1.start }) {
            guard span.start >= cursor,
                  span.len > 0,
                  span.start + span.len <= length else { continue }
            if span.start > cursor {
                result += AttributedString(string.substring(with: NSRange(location: cursor, length: span.start - cursor)))
            }
            var token = AttributedString(string.substring(with: span.range))
            token.foregroundColor = Theme.syntax(span.kind)
            result += token
            cursor = span.start + span.len
        }
        if cursor < length {
            result += AttributedString(string.substring(from: cursor))
        }
        return result
    }
}

/// A sideways scroller for content that cannot wrap.
///
/// A scroll view inside the transcript's scrolling stack is measured against
/// an unbounded proposal by a parent that has not settled its own height yet,
/// and a conversation full of them is a layout the engine keeps re-solving.
/// That is why an aside's code fences wrap in place instead.
///
/// A table and a diff cannot wrap, though, so they keep theirs whatever the
/// style. Clipping them was the alternative and it hid the right-hand columns
/// of a table with no way to reach them. They are rare inside reasoning,
/// which is what makes keeping them affordable.
private struct MarkdownSideways<Content: View>: View {
    @ViewBuilder let content: Content

    var body: some View {
        ScrollView(.horizontal) { content }
    }
}

private struct MarkdownTable: View {
    let header: [String]
    let rows: [[String]]
    let bodyFont: Font

    private var columnCount: Int {
        max(header.count, rows.map(\.count).max() ?? 0)
    }

    var body: some View {
        MarkdownSideways {
            VStack(alignment: .leading, spacing: 0) {
                tableRow(header, header: true)
                ForEach(Array(rows.enumerated()), id: \.offset) { index, row in
                    tableRow(row, header: false)
                        .background(index.isMultiple(of: 2) ? Theme.panel : Theme.accentSoft.opacity(0.34))
                }
            }
        }
        .background(Theme.panel)
        .clipShape(RoundedRectangle(cornerRadius: Theme.cardRadius - 2, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: Theme.cardRadius - 2, style: .continuous)
                .stroke(Theme.border, lineWidth: 1)
        }
    }

    private func tableRow(_ values: [String], header: Bool) -> some View {
        HStack(alignment: .top, spacing: 0) {
            ForEach(0..<columnCount, id: \.self) { column in
                InlineMarkdown(
                    column < values.count ? values[column] : "",
                    font: header ? Theme.headline : bodyFont
                )
                .padding(.horizontal, Theme.Space.m)
                .padding(.vertical, Theme.Space.s)
                .frame(width: 180, alignment: .leading)
                .overlay(alignment: .trailing) {
                    if column < columnCount - 1 {
                        Rectangle().fill(Theme.border).frame(width: 1)
                    }
                }
            }
        }
        .background(header ? Theme.accentSoft : Color.clear)
        .overlay(alignment: .bottom) {
            Rectangle().fill(Theme.border).frame(height: 1)
        }
    }
}

private enum MarkdownSanitizer {
    static func inline(_ source: String) -> String {
        // Local file links are promoted to first-class chat attachments by
        // the host. Keep only their human label in the prose so an absolute
        // filesystem path is not duplicated above the attachment card.
        var safe = replacingLocalAttachmentLinks(in: source)
        safe = replacingImages(in: safe)
        return safe
    }

    /// Turn GitHub's block HTML into actual Markdown structure before the
    /// block parser runs.
    ///
    /// Doing this in `inline` is too late: a Dependabot release body then
    /// reaches SwiftUI as a handful of enormous paragraphs, each one a single
    /// selectable `Text`. Those monolithic text layouts are what made the PR
    /// reader hitch on every scroll. Headings, list items and paragraphs must
    /// become blocks first, so layout and selection work on small rows.
    static func blocks(_ source: String) -> String {
        let normalized = source.replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
        var output: [String] = []
        var prose: [String] = []
        var fence: (marker: Character, count: Int)?

        func flushProse() {
            guard !prose.isEmpty else { return }
            output.append(convertHTMLBlocks(prose.joined(separator: "\n")))
            prose.removeAll(keepingCapacity: true)
        }

        for line in normalized.components(separatedBy: "\n") {
            if let open = fence {
                output.append(line)
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                let count = trimmed.prefix { $0 == open.marker }.count
                if count >= open.count, trimmed.dropFirst(count).isEmpty { fence = nil }
                continue
            }
            if let opening = blockFence(in: line) {
                flushProse()
                output.append(line)
                fence = opening
            } else {
                prose.append(line)
            }
        }
        flushProse()
        return output.joined(separator: "\n")
    }

    private static func convertHTMLBlocks(_ source: String) -> String {
        var safe = source
        var codeSpans: [String] = []

        // Most bodies are plain Markdown with no tags and no entities in them.
        // Everything between here and the whitespace tidy-up exists to turn
        // GitHub's HTML into Markdown, and running twenty regular expressions
        // and as many whole-string copies over a document that contains no
        // markup is pure cost, paid on the main thread while a row is being
        // laid out. One scan to find out is worth it.
        if source.contains("<") || source.contains("&") {

        // Literal `<thing>` inside an inline code span is source text, not an
        // HTML tag. Hide those spans while tags are converted and restore them
        // afterwards. Fenced blocks are excluded by `blocks` above.
        safe = replace(pattern: #"`[^`\n]*`"#, in: safe) { match, string in
            let slot = codeSpans.count
            codeSpans.append(substring(match.range, in: string))
            return "\u{E000}\(slot)\u{E001}"
        }

        // Preserve links before stripping their tags. A linked `<code>` label
        // deliberately becomes a normal linked label: AttributedString cannot
        // express code styling nested inside a Markdown link consistently.
        safe = replace(
            pattern: #"(?i)<a\s+[^>]*href\s*=\s*[\"']([^\"']+)[\"'][^>]*>([\s\S]*?)</a\s*>"#,
            in: safe
        ) { match, string in
            let href = substring(match.range(at: 1), in: string)
            var label = substring(match.range(at: 2), in: string)
            label = label.replacingOccurrences(of: #"<[^>]+>"#, with: "", options: .regularExpression)
            label = label.trimmingCharacters(in: .whitespacesAndNewlines)
            if label.isEmpty { label = href }
            // A body is untrusted text. Only hand the URL handler a scheme the
            // author would have chosen to open; anything else is shown as its
            // label, so a `javascript:` or `file:` href can no more become a
            // live link than it could when this tag was escaped outright.
            if let scheme = URL(string: href)?.scheme?.lowercased(),
               !["http", "https", "mailto"].contains(scheme) {
                return label
            }
            return "[\(label)](\(href))"
        }

        // Inline emphasis survives the HTML-to-Markdown boundary.
        safe = replace(pattern: #"(?i)<strong[^>]*>"#, in: safe) { _, _ in "**" }
        safe = replace(pattern: #"(?i)</strong\s*>"#, in: safe) { _, _ in "**" }
        safe = replace(pattern: #"(?i)<em[^>]*>"#, in: safe) { _, _ in "*" }
        safe = replace(pattern: #"(?i)</em\s*>"#, in: safe) { _, _ in "*" }
        safe = replace(pattern: #"(?i)<code[^>]*>"#, in: safe) { _, _ in "`" }
        safe = replace(pattern: #"(?i)</code\s*>"#, in: safe) { _, _ in "`" }

        // A summary is the visible label of a GitHub details block. The
        // native renderer has no disclosure control, so show it as a compact
        // heading above the content that GitHub would reveal.
        safe = replace(pattern: #"(?i)<summary[^>]*>"#, in: safe) { _, _ in "\n\n### " }
        safe = replace(pattern: #"(?i)</summary\s*>"#, in: safe) { _, _ in "\n\n" }
        for level in 1...6 {
            safe = replace(pattern: "(?i)<h\(level)[^>]*>", in: safe) { _, _ in
                "\n\n\(String(repeating: "#", count: level)) "
            }
            safe = replace(pattern: "(?i)</h\(level)\\s*>", in: safe) { _, _ in "\n\n" }
        }

        // Lists need markers before parsing. Without them 81 Dependabot
        // entries become one 20 KB Text even though the source clearly
        // provides row boundaries.
        safe = replace(pattern: #"(?i)<li[^>]*>"#, in: safe) { _, _ in "\n- " }
        safe = replace(pattern: #"(?i)</li\s*>"#, in: safe) { _, _ in "\n" }
        safe = replace(pattern: #"(?i)</?ul[^>]*>|</?ol[^>]*>"#, in: safe) { _, _ in "\n" }

        safe = replace(pattern: #"(?i)<br\s*/?>"#, in: safe) { _, _ in "\n" }
        safe = replace(pattern: #"(?i)<p[^>]*>"#, in: safe) { _, _ in "\n\n" }
        safe = replace(pattern: #"(?i)</p\s*>"#, in: safe) { _, _ in "\n\n" }
        safe = replace(
            pattern: #"(?i)</?(?:div|blockquote|details|section|article|table|thead|tbody|tr)[^>]*>"#,
            in: safe
        ) { _, _ in "\n\n" }

        safe = replace(pattern: #"<!--[\s\S]*?-->"#, in: safe) { _, _ in "" }
        // Only discard things that actually have the shape of HTML tags.
        // A broad `<[^>]+>` also eats Markdown autolinks such as
        // `<https://example.com>` and prose such as `one < two and three >
        // two`, both of which are ordinary conversation content.
        safe = replace(
            pattern: #"(?i)</?[a-z][a-z0-9:-]*(?:\s+[^<>]*?)?\s*/?>"#,
            in: safe
        ) { _, _ in "" }
        safe = decodeEntities(in: safe)
        }

        // Source indentation beside HTML tags is not content. Keep exactly
        // one blank line between blocks: compact on screen, still enough for
        // the parser to end one block before beginning the next.
        safe = safe.replacingOccurrences(of: #"[ \t]+\n"#, with: "\n", options: .regularExpression)
        safe = safe.replacingOccurrences(of: #"\n[ \t]+"#, with: "\n", options: .regularExpression)
        safe = safe.replacingOccurrences(of: #"\n{3,}"#, with: "\n\n", options: .regularExpression)
        // Consecutive HTML `<li>` rows should be one Markdown list, not 81
        // one-row lists separated by card-sized paragraph spacing.
        safe = safe.replacingOccurrences(of: #"\n{2,}(?=- )"#, with: "\n", options: .regularExpression)
        for (slot, code) in codeSpans.enumerated() {
            safe = safe.replacingOccurrences(of: "\u{E000}\(slot)\u{E001}", with: code)
        }
        return safe.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func blockFence(in line: String) -> (marker: Character, count: Int)? {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard let marker = trimmed.first, marker == "`" || marker == "~" else { return nil }
        let count = trimmed.prefix { $0 == marker }.count
        guard count >= 3 else { return nil }
        return (marker, count)
    }

    private static func replacingLocalAttachmentLinks(in source: String) -> String {
        replace(
            pattern: #"!?\[([^\]]*)\]\((?:<)?(?:file://|sandbox:)?/[^\)\n>]+(?:>)?\)"#,
            in: source
        ) { match, string in
            let label = substring(match.range(at: 1), in: string)
            return label.isEmpty ? "Attachment" : label
        }
    }

    /// Keep the alt text and destination visible as a normal link. SwiftUI
    /// therefore makes no image request; the URL is touched only if pressed.
    private static func replacingImages(in source: String) -> String {
        replace(
            pattern: #"!\[([^\]]*)\]\(([^\s\)]+)(?:\s+[\"'][^\"']*[\"'])?\)"#,
            in: source
        ) { match, string in
            let alt = substring(match.range(at: 1), in: string)
            let destination = substring(match.range(at: 2), in: string)
            let label = alt.isEmpty ? "Image" : "Image: \(alt)"
            return "[\(label)](\(destination))"
        }
    }

    private static func decodeEntities(in source: String) -> String {
        source.replacingOccurrences(of: "&amp;", with: "&")
            .replacingOccurrences(of: "&quot;", with: "\"")
            .replacingOccurrences(of: "&#39;", with: "'")
            .replacingOccurrences(of: "&apos;", with: "'")
    }

    private static func replace(
        pattern: String,
        in source: String,
        transform: (NSTextCheckingResult, NSString) -> String
    ) -> String {
        guard let expression = try? NSRegularExpression(pattern: pattern) else { return source }
        let string = source as NSString
        let matches = expression.matches(in: source, range: NSRange(location: 0, length: string.length))
        let result = NSMutableString(string: source)
        for match in matches.reversed() {
            result.replaceCharacters(in: match.range, with: transform(match, string))
        }
        return result as String
    }

    private static func substring(_ range: NSRange, in string: NSString) -> String {
        guard range.location != NSNotFound else { return "" }
        return string.substring(with: range)
    }
}

private struct MarkdownParser {
    private let lines: [String]
    private var index = 0
    private var nextID = 0

    init(_ markdown: String) {
        lines = MarkdownSanitizer.blocks(markdown)
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
            .components(separatedBy: "\n")
    }

    mutating func blocks() -> [MarkdownBlock] {
        var result: [MarkdownBlock] = []
        while index < lines.count {
            if lines[index].trimmingCharacters(in: .whitespaces).isEmpty {
                index += 1
                continue
            }
            if let block = readFence()
                ?? readHeading()
                ?? readRule()
                ?? readTable()
                ?? readQuote()
                ?? readList()
                ?? readParagraph()
            {
                result.append(block)
            }
        }
        return result
    }

    private mutating func make(_ kind: MarkdownBlock.Kind) -> MarkdownBlock {
        defer { nextID += 1 }
        return MarkdownBlock(id: nextID, kind: kind)
    }

    private mutating func readFence() -> MarkdownBlock? {
        guard let opening = fence(in: lines[index]) else { return nil }
        index += 1
        var body: [String] = []
        while index < lines.count {
            if closesFence(lines[index], opening: opening) {
                index += 1
                break
            }
            body.append(lines[index])
            index += 1
        }
        let language = opening.language.isEmpty ? nil : opening.language
        let text = body.joined(separator: "\n")
        return make(.code(
            language: language,
            text: text,
            key: MarkdownDigest.key(language, text),
            widest: body.map(\.count).max() ?? 0
        ))
    }

    private mutating func readHeading() -> MarkdownBlock? {
        let trimmed = lines[index].trimmingCharacters(in: .whitespaces)
        let hashes = trimmed.prefix { $0 == "#" }.count
        guard (1...6).contains(hashes),
              trimmed.dropFirst(hashes).first == " " else { return nil }
        let text = String(trimmed.dropFirst(hashes + 1))
        index += 1
        return make(.heading(level: hashes, text: text))
    }

    private mutating func readRule() -> MarkdownBlock? {
        guard isRule(lines[index]) else { return nil }
        index += 1
        return make(.rule)
    }

    private mutating func readTable() -> MarkdownBlock? {
        guard index + 1 < lines.count else { return nil }
        let header = tableCells(lines[index])
        let separator = tableCells(lines[index + 1])
        guard header.count >= 2,
              separator.count == header.count,
              separator.allSatisfy(isTableSeparator) else { return nil }
        index += 2
        var rows: [[String]] = []
        while index < lines.count {
            let cells = tableCells(lines[index])
            guard cells.count >= 2, !lines[index].trimmingCharacters(in: .whitespaces).isEmpty else { break }
            rows.append(cells)
            index += 1
        }
        return make(.table(header: header, rows: rows))
    }

    private mutating func readQuote() -> MarkdownBlock? {
        guard quoteLine(lines[index]) != nil else { return nil }
        var quoted: [String] = []
        while index < lines.count, let line = quoteLine(lines[index]) {
            quoted.append(line)
            index += 1
        }
        return make(.quote(quoted.joined(separator: "\n")))
    }

    private mutating func readList() -> MarkdownBlock? {
        guard listItem(lines[index]) != nil else { return nil }
        var items: [MarkdownListItem] = []
        while index < lines.count, var item = listItem(lines[index]) {
            index += 1
            var continuation: [String] = []
            while index < lines.count,
                  !lines[index].trimmingCharacters(in: .whitespaces).isEmpty,
                  listItem(lines[index]) == nil,
                  !startsBlock(at: index)
            {
                continuation.append(lines[index].trimmingCharacters(in: .whitespaces))
                index += 1
            }
            if !continuation.isEmpty {
                item = MarkdownListItem(
                    depth: item.depth,
                    ordinal: item.ordinal,
                    checked: item.checked,
                    text: ([item.text] + continuation).joined(separator: "\n")
                )
            }
            items.append(item)
        }
        return make(.list(items))
    }

    private mutating func readParagraph() -> MarkdownBlock? {
        var paragraph: [String] = []
        while index < lines.count,
              !lines[index].trimmingCharacters(in: .whitespaces).isEmpty,
              (paragraph.isEmpty || !startsBlock(at: index))
        {
            paragraph.append(lines[index])
            index += 1
        }
        guard !paragraph.isEmpty else {
            // A malformed construct must not trap the parser on one line.
            let line = lines[index]
            index += 1
            return make(.paragraph(line))
        }
        return make(.paragraph(paragraph.joined(separator: "\n")))
    }

    private func startsBlock(at line: Int) -> Bool {
        guard line < lines.count else { return false }
        let value = lines[line]
        if fence(in: value) != nil || heading(value) || isRule(value)
            || quoteLine(value) != nil || listItem(value) != nil
        {
            return true
        }
        guard line + 1 < lines.count else { return false }
        let header = tableCells(value)
        let separator = tableCells(lines[line + 1])
        return header.count >= 2 && separator.count == header.count && separator.allSatisfy(isTableSeparator)
    }

    private func heading(_ line: String) -> Bool {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        let hashes = trimmed.prefix { $0 == "#" }.count
        return (1...6).contains(hashes) && trimmed.dropFirst(hashes).first == " "
    }

    private func isRule(_ line: String) -> Bool {
        let compact = line.filter { !$0.isWhitespace }
        guard compact.count >= 3, let first = compact.first, ["-", "*", "_"].contains(first) else {
            return false
        }
        return compact.allSatisfy { $0 == first }
    }

    private func quoteLine(_ line: String) -> String? {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard trimmed.first == ">" else { return nil }
        return String(trimmed.dropFirst()).trimmingCharacters(in: .whitespaces)
    }

    private func listItem(_ line: String) -> MarkdownListItem? {
        let spaces = line.prefix { $0 == " " || $0 == "\t" }.reduce(0) { count, character in
            count + (character == "\t" ? 4 : 1)
        }
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        let depth = spaces / 2
        var ordinal: Int?
        var text: String

        if trimmed.hasPrefix("- ") || trimmed.hasPrefix("* ") || trimmed.hasPrefix("+ ") {
            text = String(trimmed.dropFirst(2))
        } else {
            let digits = trimmed.prefix { $0.isNumber }
            guard !digits.isEmpty,
                  trimmed.dropFirst(digits.count).hasPrefix(". "),
                  let number = Int(digits) else { return nil }
            ordinal = number
            text = String(trimmed.dropFirst(digits.count + 2))
        }

        var checked: Bool?
        if text.count >= 4, text.first == "[", text.dropFirst(2).prefix(2) == "] " {
            let mark = text[text.index(after: text.startIndex)]
            if mark == " " || mark == "x" || mark == "X" {
                checked = mark != " "
                text = String(text.dropFirst(4))
            }
        }
        return MarkdownListItem(depth: depth, ordinal: ordinal, checked: checked, text: text)
    }

    private func tableCells(_ line: String) -> [String] {
        var value = line.trimmingCharacters(in: .whitespaces)
        if value.hasPrefix("|") { value.removeFirst() }
        if value.hasSuffix("|") { value.removeLast() }

        var cells: [String] = []
        var cell = ""
        var escaped = false
        var inCode = false
        for character in value {
            if escaped {
                cell.append(character)
                escaped = false
            } else if character == "\\" {
                cell.append(character)
                escaped = true
            } else if character == "`" {
                cell.append(character)
                inCode.toggle()
            } else if character == "|" && !inCode {
                cells.append(cell.trimmingCharacters(in: .whitespaces))
                cell = ""
            } else {
                cell.append(character)
            }
        }
        cells.append(cell.trimmingCharacters(in: .whitespaces))
        return cells
    }

    private func isTableSeparator(_ cell: String) -> Bool {
        let trimmed = cell.trimmingCharacters(in: .whitespaces)
        let core = trimmed.trimmingCharacters(in: CharacterSet(charactersIn: ":"))
        return core.count >= 3 && core.allSatisfy { $0 == "-" }
    }

    private func fence(in line: String) -> (marker: Character, count: Int, language: String)? {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard let marker = trimmed.first, marker == "`" || marker == "~" else { return nil }
        let count = trimmed.prefix { $0 == marker }.count
        guard count >= 3 else { return nil }
        let language = trimmed.dropFirst(count)
            .trimmingCharacters(in: .whitespaces)
            .split(whereSeparator: \.isWhitespace)
            .first
            .map(String.init) ?? ""
        return (marker, count, language)
    }

    private func closesFence(
        _ line: String,
        opening: (marker: Character, count: Int, language: String)
    ) -> Bool {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        let count = trimmed.prefix { $0 == opening.marker }.count
        return count >= opening.count && trimmed.dropFirst(count).isEmpty
    }
}

/// One clipboard for both apps. Mac uses AppKit, the phone UIKit.
enum ChatClipboard {
    static func copy(_ text: String) {
        guard !text.isEmpty else { return }
        #if os(macOS)
        let board = NSPasteboard.general
        board.clearContents()
        board.setString(text, forType: .string)
        #else
        UIPasteboard.general.string = text
        #endif
    }
}

/// Small hover copy action for chat rows and code fences.
///
/// Two states, owned in two places. The *block* owns visibility: it passes
/// `visible` from its own hover, so the button only ever appears while the
/// pointer is over the message or fence. The *button* owns the highlight and
/// the copied tick: hovering the icon itself brightens it, and pressing pins
/// a checkmark in the same fixed frame for a moment, so the confirmation
/// plays in place even if the pointer has already left the block.
///
/// The frame is always laid out and only the opacity changes, so appearing
/// never shifts the text. Hit testing follows visibility.
///
/// Selection across separate SwiftUI `Text` views is per-block by design, so
/// a mouse drag selects within one paragraph or fence. This button (plus the
/// right-click menu on the row) is the whole-message path: no drag needed.
struct RowCopyButton: View {
    let text: String
    var help: String = "Copy"
    var visible: Bool = true
    @State private var hovering = false
    @State private var copied = false

    private var opacity: Double {
        if copied { return 1 }
        guard visible else { return 0 }
        return hovering ? 1 : 0.55
    }

    var body: some View {
        Button {
            ChatClipboard.copy(text)
            copied = true
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(1.2))
                copied = false
            }
        } label: {
            Image(systemName: copied ? "checkmark" : ActionIcon.copy.symbol)
                .font(Theme.font(11, weight: .medium))
                .foregroundStyle(copied ? Theme.accent : hovering ? .primary : .secondary)
                .frame(width: 22, height: 22, alignment: .center)
                .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .opacity(opacity)
        .animation(.easeOut(duration: 0.15), value: opacity)
        .allowsHitTesting(visible || copied)
        .accessibilityHidden(!(visible || copied))
        .help(copied ? "Copied" : help)
        #if os(macOS)
        .onHover { hovering = $0 }
        #endif
        .accessibilityLabel(help)
    }
}
