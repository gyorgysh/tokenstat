// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
//
// Source-available for review, NOT open source. See LICENSE: no rights to
// redistribute, publish, or ship a build are granted. Read it, study it, run
// your own build of it.
// "tokenstat" is a trademark of pueev OU. See TRADEMARK.md.

import Foundation
import SwiftUI

/// Small, read-only Markdown for pull-request conversations and chat.
///
/// This is deliberately a renderer rather than a web view. GitHub bodies are
/// untrusted text: HTML is shown literally and remote images become links, so
/// opening a conversation never contacts a host the person did not choose.
/// The block parser owns the handful of shapes these conversations need while
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
    /// Syntax spans, which cost a round trip to the host rather than a parse.
    static let highlights = ParsedTextCache<[SyntaxSpan]>(limit: 800)
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
        case code(language: String?, text: String)
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
        case let .code(language, text):
            MarkdownCodeBlock(language: language, source: text, font: codeFont, style: style)
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

private struct InlineMarkdown: View {
    private let attributed: AttributedString
    private let font: Font

    init(_ source: String, font: Font) {
        self.font = font
        attributed = MarkdownCache.inline.value(for: source) {
            let safe = MarkdownSanitizer.inline(source)
            let options = AttributedString.MarkdownParsingOptions(
                interpretedSyntax: .inlineOnlyPreservingWhitespace,
                failurePolicy: .returnPartiallyParsedIfPossible
            )
            return (try? AttributedString(markdown: safe, options: options)) ?? AttributedString(source)
        }
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

private struct MarkdownCodeBlock: View {
    let language: String?
    let source: String
    let font: Font
    var style: MarkdownStyle = .document

    @State private var spans: [SyntaxSpan] = []

    private var isDiff: Bool {
        ["diff", "patch"].contains(language?.lowercased())
    }

    var body: some View {
        Group {
            if isDiff {
                MarkdownSideways {
                    DiffBody(diff: FileDiff.fromEditPatch(path: "Change", patch: source))
                        .padding(.vertical, Theme.Space.xs)
                }
            } else {
                VStack(alignment: .leading, spacing: 0) {
                    if let language {
                        Text(language.uppercased())
                            .font(Theme.mono(10, weight: .semibold))
                            .foregroundStyle(Theme.accent)
                            .padding(.horizontal, Theme.Space.m)
                            .padding(.vertical, Theme.Space.s)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(Theme.accentSoft)
                    }

                    // An aside wraps its code instead of scrolling it. The
                    // fixed size below is what makes the line keep its shape
                    // inside a scroller, and it is also what would propose an
                    // unbounded width to the transcript around it.
                    if style == .aside {
                        highlightedText
                            .font(font)
                            .textSelection(.enabled)
                            .padding(Theme.Space.m)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    } else {
                        ScrollView(.horizontal) {
                            highlightedText
                                .font(font)
                                .textSelection(.enabled)
                                .fixedSize(horizontal: true, vertical: false)
                                .padding(Theme.Space.m)
                        }
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
        .task(id: highlightKey) {
            guard let path = highlightPath else {
                spans = []
                return
            }
            if let cached = MarkdownCache.highlights.stored(for: highlightKey) {
                spans = cached
                return
            }
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
            guard !Task.isCancelled else { return }
            spans = result?.spans ?? []
            MarkdownCache.highlights.store(spans, for: highlightKey)
        }
    }

    private var highlightKey: String {
        "\(language ?? "plain"):\(source)"
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

    private var highlightedText: Text {
        let string = source as NSString
        let length = string.length
        var cursor = 0
        var result = Text("")

        for span in spans.sorted(by: { $0.start < $1.start }) {
            guard span.start >= cursor,
                  span.len > 0,
                  span.start + span.len <= length else { continue }
            if span.start > cursor {
                result = result + Text(string.substring(with: NSRange(location: cursor, length: span.start - cursor)))
            }
            let token = string.substring(with: span.range)
            result = result + Text(token).foregroundColor(Theme.syntax(span.kind))
            cursor = span.start + span.len
        }
        if cursor < length {
            result = result + Text(string.substring(from: cursor))
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
        safe = replacingHTML(in: safe)
        return safe
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

    /// `AttributedString(markdown:)` may interpret supported inline HTML. It
    /// is content here, so escape whole tags and comments before parsing.
    private static func replacingHTML(in source: String) -> String {
        replace(pattern: #"<!--[\s\S]*?-->|<[^>]+>"#, in: source) { match, string in
            substring(match.range, in: string)
                .replacingOccurrences(of: "&", with: "&amp;")
                .replacingOccurrences(of: "<", with: "&lt;")
                .replacingOccurrences(of: ">", with: "&gt;")
        }
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
        lines = markdown.replacingOccurrences(of: "\r\n", with: "\n")
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
        return make(.code(language: language, text: body.joined(separator: "\n")))
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
