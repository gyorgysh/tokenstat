// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
//
// Source-available: source sharing and own builds are permitted.
// Store and commercial distribution of builds is reserved. See LICENSE.
// "tokenstat" is a trademark of pueev OU. See TRADEMARK.md.

import Foundation
import SwiftUI
#if os(macOS)
import AppKit
#else
import UIKit
#endif

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
    static func warm(_ sources: [String]) {
        guard !sources.isEmpty else { return }
        Task.detached(priority: .utility) {
            for source in sources {
                await MarkdownWarmup.shared.warm(source)
            }
        }
    }
}

private actor MarkdownWarmup {
    static let shared = MarkdownWarmup()

    func warm(_ source: String) {
        guard !source.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        let blocks = MarkdownCache.blocks.value(for: source) {
            var parser = MarkdownParser(source)
            return parser.blocks()
        }
        for block in blocks {
            switch block.kind {
            case let .heading(_, text), let .paragraph(text), let .quote(text):
                _ = MarkdownInline.parse(text)
            case let .list(items):
                for item in items { _ = MarkdownInline.parse(item.text) }
            case let .table(header, rows, _):
                for cell in header { _ = MarkdownInline.parse(cell) }
                for row in rows {
                    for cell in row { _ = MarkdownInline.parse(cell) }
                }
            case .code, .rule:
                break
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
enum MarkdownStyle: String {
    case document
    case chat
    case aside

    func headingFont(bodyFont: Font, level: Int) -> Font {
        if self == .aside {
            return bodyFont.weight(level <= 2 ? .bold : .semibold)
        }
        if self == .chat {
            switch level {
            case 1: return Theme.chatHeading
            case 2: return Theme.chatSubheading
            default: return bodyFont.weight(.semibold)
            }
        }
        switch level {
        case 1: return Theme.title
        case 2: return Theme.title2
        case 3: return Theme.title3
        default: return Theme.headline
        }
    }
}

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

    func stored(for source: String) -> Value? {
        cache.object(forKey: source as NSString)?.value
    }

    func store(_ value: Value, for source: String) {
        cache.setObject(Held(value), forKey: source as NSString)
    }
}

private enum MarkdownCache {
    static let blocks = ParsedTextCache<[MarkdownBlock]>(limit: 3000)
    static let inline = ParsedTextCache<AttributedString>(limit: 10000)
    static let rendered = ParsedTextCache<[AttributedString]>(limit: 600)
    static let diffs = ParsedTextCache<FileDiff>(limit: 300)
    static let segments = ParsedTextCache<[MessageSegment]>(limit: 800)

    static var appearanceKey: String { AppAppearance.shared.markdownCacheKey }

    static let live = LiveMarkdown()
}

private final class LiveMarkdown {
    static var cadence: TimeInterval { readerAway ? 1.0 : 0.05 }

    static var readerAway = false

    private final class Revision {
        let text: String
        let segments: [MessageSegment]
        let parsedAt: TimeInterval

        init(text: String, segments: [MessageSegment], parsedAt: TimeInterval) {
            self.text = text
            self.segments = segments
            self.parsedAt = parsedAt
        }
    }

    private let revisions = NSCache<NSString, Revision>()
    private var lastParse: TimeInterval = 0

    init() {
        revisions.countLimit = 4
    }

    func take(slot: String, text: String) -> (segments: [MessageSegment], needsRefresh: Bool)? {
        guard let revision = revisions.object(forKey: slot as NSString) else { return nil }
        if revision.text == text { return (revision.segments, false) }
        if Date.timeIntervalSinceReferenceDate - lastParse < Self.cadence {
            return (revision.segments, true)
        }
        return nil
    }

    func store(_ segments: [MessageSegment], text: String, slot: String) {
        lastParse = Date.timeIntervalSinceReferenceDate
        revisions.setObject(
            Revision(text: text, segments: segments, parsedAt: lastParse),
            forKey: slot as NSString
        )
    }

    func remaining() -> TimeInterval {
        max(0, Self.cadence - (Date.timeIntervalSinceReferenceDate - lastParse))
    }
}

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

private struct MessageSegmentBuilder {
    let bodyFont: Font
    let style: MarkdownStyle
    let maximumCharacters: Int
    let streaming: Bool
    private var out: [MessageSegment] = []
    private var wordCount = 0
    private var chain: [Text] = []
    private var chainLength = 0
    private var chainLineBreaks = 0
    private var chainWordCount = 0
    private var chainHasLinks = false
    private var chainContinues = false
    private var nextContinues = false

    init(bodyFont: Font, style: MarkdownStyle, maximumCharacters: Int, streaming: Bool) {
        self.bodyFont = bodyFont
        self.style = style
        self.maximumCharacters = maximumCharacters
        self.streaming = streaming
    }

    func finished() -> [MessageSegment] {
        var copy = self
        copy.flush()
        return copy.out
    }

    private mutating func prose(_ value: AttributedString) -> Text {
        streaming ? StreamingWordAttribute.text(value, next: &wordCount) : MarkdownLinks.text(value)
    }

    private func gap() -> Text { Text("\n\n").font(bodyFont) }

    private mutating func flush() {
        guard !chain.isEmpty else { return }
        out.append(.text(MarkdownLinks.joined(chain[...]), hasLinks: chainHasLinks, wordCount: chainWordCount,
                         continues: chainContinues, length: chainLength))
        chain.removeAll(keepingCapacity: true)
        chainLength = 0
        chainLineBreaks = 0
        chainHasLinks = false
    }

    private mutating func push(_ piece: Text, length: Int, lineBreaks: Int, separator: Text? = nil, links: Bool = false) {
        let gapLines = separator == nil ? 2 : 1
        if !chain.isEmpty, chainLength + length > maximumCharacters ||
            chainLineBreaks + gapLines + lineBreaks > MarkdownTextChunks.maximumLineBreaks {
            flush()
            nextContinues = separator != nil
        }
        if !chain.isEmpty {
            chain.append(separator ?? gap())
            chainLength += length + 2
            chainLineBreaks += gapLines + lineBreaks
        } else {
            chainLength = length
            chainLineBreaks = lineBreaks
            chainContinues = nextContinues
            nextContinues = false
        }
        chain.append(piece)
        chainWordCount = wordCount
        chainHasLinks = chainHasLinks || links
    }

    private func chunks(_ text: String) -> [AttributedString] {
        MarkdownTextChunks.split(MarkdownInline.attributed(text), maximum: maximumCharacters)
    }

    private mutating func listRow(_ item: MarkdownListItem, text: AttributedString) -> Text {
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
        return row + prose(text).font(bodyFont)
    }

    mutating func add(_ block: MarkdownBlock) {
        switch block.kind {
        case let .heading(level, text):
            for chunk in chunks(text) {
                push(
                    prose(chunk).font(MessageMarkdownContent.headingFont(style: style, bodyFont: bodyFont, level: level)),
                    length: chunk.characters.count, lineBreaks: chunk.characters.lazy.filter(\.isNewline).count,
                    links: chunk.runs.contains { $0.link != nil }
                )
            }
        case let .paragraph(text):
            for chunk in chunks(text) {
                push(
                    prose(chunk).font(bodyFont),
                    length: chunk.characters.count, lineBreaks: chunk.characters.lazy.filter(\.isNewline).count,
                    links: chunk.runs.contains { $0.link != nil }
                )
            }
        case let .list(items):
            for (index, item) in items.enumerated() {
                let parsed = chunks(item.text)
                let parts = parsed.isEmpty ? [AttributedString()] : parsed
                for (part, chunk) in parts.enumerated() {
                    let piece = (part == 0)
                        ? listRow(item, text: chunk)
                        : prose(chunk).font(bodyFont)
                    push(
                        piece,
                        length: chunk.characters.count,
                        lineBreaks: chunk.characters.lazy.filter(\.isNewline).count,
                        separator: index == 0 && part == 0
                            ? nil : Text("\n").font(bodyFont),
                        links: chunk.runs.contains { $0.link != nil }
                    )
                }
            }
        case .code, .table, .quote, .rule:
            flush()
            out.append(.block(block))
        }
    }
}

private final class LiveSegmentPrefix {
    static let shared = LiveSegmentPrefix()
    struct State {
        let blocks: [MarkdownBlock]
        let builder: MessageSegmentBuilder
    }
    private var states: [String: State] = [:]
    private var order: [String] = []

    func state(for slot: String) -> State? { states[slot] }

    func save(_ state: State, for slot: String) {
        if states.updateValue(state, forKey: slot) == nil {
            order.append(slot)
            if order.count > 4 { states.removeValue(forKey: order.removeFirst()) }
        }
    }
}

private struct MarkdownBlock: Identifiable, Equatable {
    enum Kind: Equatable {
        case heading(level: Int, text: String)
        case paragraph(String)
        case list([MarkdownListItem])
        case quote(String)
        case code(language: String?, text: String, key: String, widest: Int)
        case rule
        case table(header: [String], rows: [[String]], overflow: Int)
    }

    let id: Int
    let kind: Kind
}

private struct MarkdownListItem: Equatable {
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
    var selectable: Bool = true

    @ViewBuilder
    var body: some View {
        switch block.kind {
        case let .heading(level, text):
            InlineMarkdown(text, font: headingFont(level), selectable: selectable)
                .padding(.top, level <= 2 ? Theme.Space.xs : 0)
        case let .paragraph(text):
            InlineMarkdown(text, font: bodyFont, selectable: selectable)
        case let .list(items):
            VStack(alignment: .leading, spacing: Theme.Space.s) {
                ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                    MarkdownListRow(item: item, bodyFont: bodyFont, selectable: selectable)
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
                InlineMarkdown(text, font: bodyFont, selectable: selectable)
                    .foregroundStyle(.secondary)
            }
            .padding(.vertical, Theme.Space.xs)
            .padding(.horizontal, Theme.Space.m)
            .background(Theme.accentSoft.opacity(0.62))
            .clipShape(RoundedRectangle(cornerRadius: Theme.cardRadius - 4, style: .continuous))
        case let .code(language, text, key, widest):
            MarkdownCodeBlock(
                language: language, source: text, key: key, widest: widest,
                font: codeFont, style: style, selectable: selectable
            )
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
        case let .table(header, rows, overflow):
            MarkdownTable(
                header: header,
                rows: rows,
                overflow: overflow,
                bodyFont: bodyFont,
                selectable: selectable
            )
        }
    }

    private func headingFont(_ level: Int) -> Font {
        style.headingFont(bodyFont: bodyFont, level: level)
    }
}

private struct MarkdownListRow: View {
    let item: MarkdownListItem
    let bodyFont: Font
    var selectable: Bool = true

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: Theme.Space.s) {
            marker
                .frame(width: 20, alignment: .trailing)
            InlineMarkdown(item.text, font: bodyFont, selectable: selectable)
        }
        .padding(.leading, CGFloat(item.depth) * Theme.Space.l)
    }

    @ViewBuilder
    private var marker: some View {
        if let checked = item.checked {
            Image(systemName: checked ? "checkmark.square.fill" : "square")
                .font(Theme.font(13, weight: .semibold, relativeTo: .body))
                .foregroundStyle(checked ? Theme.accent : Theme.stateIdle)
                .accessibilityLabel(checked ? L10n.text("common.completed") : L10n.text("apple.markdowntext.not_completed.01925024"))
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

private enum MarkdownInline {
    static func attributed(_ source: String) -> AttributedString {
        MarkdownLinks.styled(parse(source), color: Theme.accent)
    }

    static func parse(_ source: String) -> AttributedString {
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
    private let selectable: Bool

    init(_ source: String, font: Font, selectable: Bool = true) {
        self.font = font
        self.selectable = selectable
        attributed = MarkdownInline.attributed(source)
    }

    var body: some View {
        let text = MarkdownLinks.text(attributed)
            .font(font)
            .tint(Theme.accent)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
        if selectable {
            text.textSelection(.enabled).modifier(MarkdownLinkHover(enabled: attributed.runs.contains { $0.link != nil }))
        } else {
            text
        }
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
/// One chain of a reply that is not selectable, which is the live row.
///
/// Every revision of a streaming reply rebuilds its `Text` values, and a
/// `Text` never compares equal to a rebuilt one, so each token resolved and
/// redrew every chain of a 400-line reply. Only the last chain is still
/// growing: the builder resumes after every finished block, so an earlier
/// chain with the same word range and length is the same text. Those compare equal here
/// and SwiftUI leaves them alone.
private struct SettledAwareText: View, Equatable {
    let text: Text
    let live: Bool
    let arrivals: [Int: TimeInterval]
    let wordStart: Int
    let wordEnd: Int
    let length: Int
    let settled: Bool

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.settled && rhs.settled && lhs.wordStart == rhs.wordStart && lhs.wordEnd == rhs.wordEnd
            && lhs.length == rhs.length
            && lhs.arrivals.isEmpty && rhs.arrivals.isEmpty
    }

    var body: some View {
        StreamingText(text: text, live: live, arrivals: arrivals, revision: wordEnd)
            .tint(Theme.accent)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private enum MessageSegment {
    case text(Text, hasLinks: Bool, wordCount: Int, continues: Bool = false, length: Int = 0)
    case block(MarkdownBlock)
}

@MainActor
enum LiveMarkdownReader {
    private static var away: [ObjectIdentifier: Bool] = [:]

    static func setAway(_ isAway: Bool, for transcript: AnyObject) {
        away[ObjectIdentifier(transcript)] = isAway
        LiveMarkdown.readerAway = !away.isEmpty && away.values.allSatisfy { $0 }
    }

    static func remove(_ transcript: AnyObject) {
        away[ObjectIdentifier(transcript)] = nil
        LiveMarkdown.readerAway = !away.isEmpty && away.values.allSatisfy { $0 }
    }
}

struct MessageMarkdown: View {
    private let markdown: String
    private let bodyFont: Font
    private let codeFont: Font
    private let style: MarkdownStyle
    private let selectable: Bool
    private let cacheScope: String
    private let live: Bool
    private let liveID: String?
    @Environment(\.dynamicTypeSize) private var typeSize

    init(
        _ markdown: String,
        bodyFont: Font = Theme.body,
        codeFont: Font = Theme.monoText(12, relativeTo: .body),
        style: MarkdownStyle = .document,
        selectable: Bool = true,
        cacheScope: String = "chat",
        live: Bool = false,
        liveID: String? = nil
    ) {
        self.markdown = markdown
        self.bodyFont = bodyFont
        self.codeFont = codeFont
        self.style = style
        self.selectable = selectable
        self.cacheScope = cacheScope
        self.live = live
        self.liveID = liveID
    }

    var body: some View {
        let maximum = typeSize.isAccessibilitySize ? 256 : typeSize > .large ? 1024 : 2048
        MessageMarkdownContent(markdown, bodyFont: bodyFont, codeFont: codeFont, style: style,
            selectable: selectable, cacheScope: cacheScope, live: live, liveID: liveID,
            maximumCharacters: maximum)
            .id(maximum)
    }
}

#if os(macOS)
@available(macOS 15, *)
private struct VisibleMarkdownLines: TextRenderer {
    func draw(layout: Text.Layout, in context: inout GraphicsContext) {
        let clip = context.clipBoundingRect
        for line in layout where clip.intersects(line.typographicBounds.rect) {
            context.draw(line)
        }
    }
}

private struct MarkdownLineDrawing: ViewModifier {
    let enabled: Bool

    func body(content: Content) -> some View {
        if #available(macOS 15, *), enabled {
            content.textRenderer(VisibleMarkdownLines())
        } else {
            content
        }
    }
}
#endif

private struct MessageMarkdownContent: View {
    private let cachedSegments: [MessageSegment]
    private let source: String
    private let liveSlot: String
    private let isLive: Bool
    private let needsRefresh: Bool
    private let bodyFont: Font
    private let codeFont: Font
    private let style: MarkdownStyle
    private let maximumCharacters: Int
    private let selectable: Bool
    @State private var refreshed: (source: String, segments: [MessageSegment])?
    @State private var wordArrivals = StreamingWordArrivals()
    @AppStorage("chat.smoothStreaming") private var smoothStreaming = true
    @Environment(\.accessibilityReduceMotion) private var reduceStreamingMotion

    init(
        _ markdown: String,
        bodyFont: Font = Theme.body,
        codeFont: Font = Theme.monoText(12, relativeTo: .body),
        style: MarkdownStyle = .document,
        selectable: Bool = true,
        cacheScope: String = "chat",
        live: Bool = false,
        liveID: String? = nil,
        maximumCharacters: Int
    ) {
        self.bodyFont = bodyFont
        self.codeFont = codeFont
        self.style = style
        self.selectable = selectable
        self.source = markdown
        self.isLive = live
        self.maximumCharacters = maximumCharacters
        if live, let liveID {
            // A row still being written keeps one revision in its own slot
            // rather than joining the conversation's: its text is a new
            // string on every token, and storing revisions there evicts the
            // settled rows, which then reparse on the next measuring pass the
            // lazy stack makes. See `MarkdownCache.live`. The revision is
            // replaced at most once per `LiveMarkdown.cadence`; a token that
            // arrives sooner keeps the revision on screen and is picked up by
            // the body's task.
            let slot = "\(MarkdownCache.appearanceKey):\(liveID.utf8.count):\(liveID):\(cacheScope):\(style.rawValue):\(maximumCharacters)"
            self.liveSlot = slot
            let cache = MarkdownCache.live
            if let shown = cache.take(slot: slot, text: markdown) {
                cachedSegments = shown.segments
                needsRefresh = shown.needsRefresh
            } else {
                var parser = MarkdownParser(markdown)
                let parsed = parser.blocks()
                let segments = Self.makeLiveSegments(blocks: parsed, slot: slot, bodyFont: bodyFont,
                    style: style, maximumCharacters: maximumCharacters)
                cache.store(segments, text: markdown, slot: slot)
                cachedSegments = segments
                needsRefresh = false
            }
        } else {
            let parsed = MarkdownCache.blocks.value(for: markdown) {
                var parser = MarkdownParser(markdown)
                return parser.blocks()
            }
            let key = "\(MarkdownCache.appearanceKey):\(cacheScope):\(style.rawValue):\(maximumCharacters):\(markdown)"
            self.liveSlot = ""
            needsRefresh = false
            cachedSegments = MarkdownCache.segments.value(for: key) {
                Self.makeSegments(blocks: parsed, bodyFont: bodyFont, style: style,
                    maximumCharacters: maximumCharacters)
            }
        }
    }

    private static func makeSegments(
        blocks: [MarkdownBlock],
        bodyFont: Font,
        style: MarkdownStyle, maximumCharacters: Int, streaming: Bool = false
    ) -> [MessageSegment] {
        var builder = MessageSegmentBuilder(bodyFont: bodyFont, style: style,
            maximumCharacters: maximumCharacters, streaming: streaming)
        for block in blocks { builder.add(block) }
        return builder.finished()
    }

    private static func makeLiveSegments(
        blocks: [MarkdownBlock], slot: String,
        bodyFont: Font, style: MarkdownStyle, maximumCharacters: Int
    ) -> [MessageSegment] {
        let stable = max(0, blocks.count - 1)
        var builder: MessageSegmentBuilder
        var done = 0
        if let saved = LiveSegmentPrefix.shared.state(for: slot), saved.blocks.count <= stable,
           blocks[..<saved.blocks.count].elementsEqual(saved.blocks) {
            builder = saved.builder
            done = saved.blocks.count
        } else {
            builder = MessageSegmentBuilder(bodyFont: bodyFont, style: style,
                maximumCharacters: maximumCharacters, streaming: true)
        }
        for block in blocks[done..<stable] { builder.add(block) }
        LiveSegmentPrefix.shared.save(.init(blocks: Array(blocks[..<stable]), builder: builder), for: slot)
        for block in blocks[stable...] { builder.add(block) }
        return builder.finished()
    }

    private var shownSegments: [MessageSegment] {
        if isLive, let refreshed, refreshed.source == source {
            return refreshed.segments
        }
        return cachedSegments
    }

    var body: some View {
        let segments = shownSegments
        let ranges = segments.reduce(into: (end: 0, starts: [Int]())) { result, segment in
            result.starts.append(result.end)
            if case let .text(_, _, end, _, _) = segment { result.end = max(result.end, end) }
        }
        let arrivals = wordArrivals.update(source: source, count: ranges.end, now: ProcessInfo.processInfo.systemUptime, animate: smoothStreaming && !reduceStreamingMotion, identity: liveSlot)
        let activeWords = StreamingWordWindow(arrivals)
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(segments.enumerated()), id: \.offset) { index, segment in
                switch segment {
                case let .text(chain, hasLinks, wordEnd, continues, length):
                    let wordStart = ranges.starts[index]
                    let arriving = activeWords.words(in: wordStart..<wordEnd)
                    Group {
                        if selectable {
                            chain
                                .tint(Theme.accent)
                                .textSelection(.enabled)
                                .modifier(MarkdownLinkHover(enabled: hasLinks))
                                .fixedSize(horizontal: false, vertical: true)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        } else {
                            SettledAwareText(
                                text: chain, live: isLive, arrivals: arriving, wordStart: wordStart,
                                wordEnd: wordEnd, length: length, settled: isLive && index < segments.count - 1
                            )
                            .equatable()
                        }
                    }
                    #if os(macOS)
                    .modifier(MarkdownLineDrawing(enabled: style == .chat && !isLive && segments.count >= 4))
                    #endif
                    .padding(.top, index == 0 || continues ? 0 : Theme.Space.m)
                case let .block(block):
                    MarkdownBlockView(
                        block: block,
                        bodyFont: bodyFont,
                        codeFont: codeFont,
                        style: style,
                        selectable: selectable
                    )
                    .padding(.top, index == 0 ? 0 : Theme.Space.m)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .task(id: source) {
            guard isLive, needsRefresh else { return }
            let wait = MarkdownCache.live.remaining()
            if wait > 0 {
                try? await Task.sleep(for: .seconds(wait))
            }
            guard !Task.isCancelled else { return }
            var parser = MarkdownParser(source)
            let parsed = parser.blocks()
            let segments = Self.makeLiveSegments(blocks: parsed, slot: liveSlot, bodyFont: bodyFont,
                style: style, maximumCharacters: maximumCharacters)
            MarkdownCache.live.store(segments, text: source, slot: liveSlot)
            refreshed = (source, segments)
        }
    }

    fileprivate static func headingFont(style: MarkdownStyle, bodyFont: Font, level: Int) -> Font {
        style.headingFont(bodyFont: bodyFont, level: level)
    }
}

private struct MarkdownCodeBlock: View {
    let language: String?
    let source: String
    let key: String
    let widest: Int
    let font: Font
    var style: MarkdownStyle = .document
    var selectable: Bool = true

    @State private var coloured: (key: String, chunks: [AttributedString])?
    @State private var hovering = false
    @Environment(\.dynamicTypeSize) private var typeSize

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
    /// Extremely long lines wrap in bounded pieces as well: an enormous
    /// native text surface can turn the whole fence blank at large text sizes.
    ///
    /// An aside never gets one. The fixed size inside a scroller is what keeps
    /// a line's shape, and it is also what would propose an unbounded width to
    /// the transcript around it.
    private var needsScroller: Bool {
        style != .aside && widest > 54 && widest <= MarkdownTextChunks.maximumUnwrappedCodeLine
    }

    private var maximumCharacters: Int {
        typeSize.isAccessibilitySize ? 256 : typeSize > .large ? 1024 : 2048
    }

    private var renderedKey: String { MarkdownCache.appearanceKey + (needsScroller ? "s" : "w\(maximumCharacters)") + key }

    private func chunks(_ value: AttributedString) -> [AttributedString] {
        MarkdownTextChunks.splitCode(value, scrollsHorizontally: needsScroller, maximum: maximumCharacters)
    }

    private static func parsed(_ source: String) -> FileDiff {
        MarkdownCache.diffs.value(for: source) {
            FileDiff.fromEditPatch(path: "Change", patch: source)
        }
    }

    private var shown: [AttributedString] {
        if let coloured, coloured.key == renderedKey { return coloured.chunks }
        if let done = MarkdownCache.rendered.stored(for: "c" + renderedKey) { return done }
        return MarkdownCache.rendered.value(for: "p" + renderedKey) {
            chunks(AttributedString(source))
        }
    }

    private var codeText: some View {
        let chunks = shown
        return VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(chunks.enumerated()), id: \.offset) { index, chunk in
                let text = MarkdownTextChunks.codeText(chunk, isLast: index == chunks.count - 1)
                Text(text)
                    .font(font)
                    .modifier(MarkdownSelectable(selectable))
                    .fixedSize(horizontal: needsScroller, vertical: true)
            }
        }
    }

    var body: some View {
        Group {
            if language == "tokenstat-chart" || language == "tokenstat-chart-pending" {
                ChatChartView(source: source, pending: language == "tokenstat-chart-pending")
            } else if isDiff {
                #if os(iOS)
                WidthReader { width in
                    if width > 0 {
                        DiffBody(diff: Self.parsed(source), minWidth: width, lazy: false)
                            .padding(.vertical, Theme.Space.xs)
                    } else {
                        Color.clear.frame(height: 1)
                    }
                }
                #else
                MarkdownSideways {
                    DiffBody(diff: Self.parsed(source), lazy: false)
                        .padding(.vertical, Theme.Space.xs)
                }
                #endif
            } else {
                VStack(alignment: .leading, spacing: 0) {
                    if let language {
                        HStack(spacing: Theme.Space.s) {
                            Text(language.uppercased())
                                .font(Theme.mono(10, weight: .semibold))
                                .foregroundStyle(Theme.accent)
                            Spacer(minLength: 0)
                            #if os(macOS)
                            RowCopyButton(text: source, help: L10n.text("apple.markdowntext.copy_code.49a0053f"), visible: hovering)
                            #else
                            RowCopyButton(text: source, help: L10n.text("apple.markdowntext.copy_code.49a0053f"))
                            #endif
                        }
                        .padding(.horizontal, Theme.Space.m)
                        .padding(.vertical, Theme.Space.s)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(Theme.accentSoft)
                    }

                    if needsScroller {
                        ScrollView(.horizontal) {
                            codeText.padding(Theme.Space.m)
                        }
                    } else {
                        codeText
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
            if language == nil {
                RowCopyButton(text: source, help: L10n.text("apple.markdowntext.copy_code.49a0053f"), visible: hovering)
                    .padding(Theme.Space.xs)
            }
        }
        .onHover { hovering = $0 }
        #endif
        .contextMenu {
            Button(L10n.text("apple.markdowntext.copy_code.49a0053f")) { ChatClipboard.copy(source) }
        }
        .task(id: renderedKey) {
            // `ForEach` identifies blocks by their position in one message.
            // When a streaming message edits a fence in place SwiftUI keeps
            // this view's state, so the colour from the old fence must not win
            // over the new source while its own highlight is being fetched.
            coloured = nil
            if let done = MarkdownCache.rendered.stored(for: "c" + renderedKey) {
                coloured = (renderedKey, done)
                return
            }
            guard let path = highlightPath else { return }
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
            let text = spans.isEmpty
                ? MarkdownCache.rendered.value(for: "p" + renderedKey) {
                    chunks(AttributedString(source))
                }
                : chunks(Self.colouring(source, with: spans))
            MarkdownCache.rendered.store(text, for: "c" + renderedKey)
            coloured = (renderedKey, text)
        }
    }

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

private struct MarkdownSideways<Content: View>: View {
    @ViewBuilder let content: Content

    var body: some View {
        ScrollView(.horizontal) { content }
    }
}

private struct MarkdownSelectable: ViewModifier {
    var enabled: Bool
    init(_ enabled: Bool) { self.enabled = enabled }

    func body(content: Content) -> some View {
        if enabled {
            content.textSelection(.enabled)
        } else {
            content
        }
    }
}

private struct MarkdownTable: View {
    let header: [String]
    let rows: [[String]]
    var overflow: Int = 0
    let bodyFont: Font
    var selectable: Bool = true

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
                if overflow > 0 {
                    Text(L10n.text("apple.markdowntext.0_more_rows.cc46c841", "\(overflow)"))
                        .font(Theme.caption)
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, Theme.Space.m)
                        .padding(.vertical, Theme.Space.s)
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
                    font: header ? bodyFont.weight(.semibold) : bodyFont,
                    selectable: selectable
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
        var closed = false
        while index < lines.count {
            if closesFence(lines[index], opening: opening) {
                closed = true
                index += 1
                break
            }
            body.append(lines[index])
            index += 1
        }
        let language = opening.language == "tokenstat-chart" && !closed ? "tokenstat-chart-pending" : (opening.language.isEmpty ? nil : opening.language)
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

    /// A table past these bounds stops growing the view graph.
    ///
    /// A body can carry a table with any number of rows and columns, and each
    /// cell becomes its own `Text` with its own padding and overlay: a
    /// thousand-row, forty-column table is forty thousand views inside one
    /// row of a lazy stack. The reader cannot use a table that size anyway,
    /// so the parser keeps the first slice and counts the rest for a
    /// "+N more rows" row.
    private static let maxTableRows = 100
    private static let maxTableColumns = 32

    private mutating func readTable() -> MarkdownBlock? {
        guard index + 1 < lines.count,
              lines[index].utf8.contains(0x7c), lines[index + 1].utf8.contains(0x7c) else { return nil }
        var header = tableCells(lines[index])
        let separator = tableCells(lines[index + 1])
        guard header.count >= 2,
              separator.count == header.count,
              separator.allSatisfy(isTableSeparator) else { return nil }
        index += 2
        if header.count > Self.maxTableColumns {
            header = Array(header.prefix(Self.maxTableColumns))
        }
        var rows: [[String]] = []
        var overflow = 0
        while index < lines.count {
            let cells = tableCells(lines[index])
            guard cells.count >= 2, !lines[index].trimmingCharacters(in: .whitespaces).isEmpty else { break }
            if rows.count < Self.maxTableRows {
                rows.append(Array(cells.prefix(Self.maxTableColumns)))
            } else {
                overflow += 1
            }
            index += 1
        }
        return make(.table(header: header, rows: rows, overflow: overflow))
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
            let line = lines[index]
            index += 1
            return make(.paragraph(line))
        }
        return make(.paragraph(paragraph.joined(separator: "\n")))
    }

    private func startsBlock(at line: Int) -> Bool {
        guard line < lines.count else { return false }
        let value = lines[line]
        if let first = value.utf8.first,
           (65...90).contains(first) || (97...122).contains(first),
           !value.utf8.contains(0x7c) { return false }
        if fence(in: value) != nil || heading(value) || isRule(value)
            || quoteLine(value) != nil || listItem(value) != nil
        {
            return true
        }
        guard line + 1 < lines.count,
              value.utf8.contains(0x7c), lines[line + 1].utf8.contains(0x7c) else { return false }
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
        var marker: Character?
        var count = 0
        for character in line where !character.isWhitespace {
            if let marker {
                guard character == marker else { return false }
            } else {
                guard character == "-" || character == "*" || character == "_" else { return false }
                marker = character
            }
            count += 1
        }
        return count >= 3
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
        if text.first == "[", text.dropFirst(2).prefix(2) == "] " {
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
    var help: String = L10n.text("common.copy")
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
                .contentTransition(.symbolEffect(.replace))
                .frame(width: 22, height: 22, alignment: .center)
                .background {
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(copied ? Theme.accentSoft : Theme.controlSeat)
                        .opacity(hovering || copied ? 1 : 0)
                        .scaleEffect(hovering || copied ? 1 : 0.7)
                }
                .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .opacity(opacity)
        .scaleEffect(visible || copied ? 1 : 0.85)
        .animation(Motion.morph, value: opacity)
        .animation(Motion.morph, value: hovering)
        .animation(Motion.morph, value: copied)
        .allowsHitTesting(visible || copied)
        .accessibilityHidden(!(visible || copied))
        .help(copied ? L10n.text("apple.markdowntext.copied.8d525e5f") : help)
        #if os(macOS)
        .onHover { hovering = $0 }
        #endif
        .accessibilityLabel(help)
    }
}
