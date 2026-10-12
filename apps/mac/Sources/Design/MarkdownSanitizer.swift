// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
import Foundation

enum MarkdownSanitizer {
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

    /// The most text HTML conversion will read.
    ///
    /// GitHub caps a body at 64 KB, so any document past this is not a
    /// conversation that grew long: it is input built to be expensive. What
    /// is beyond the cap is left exactly as it arrived and only the prefix is
    /// converted, so an oversized body still renders as plain text.
    private static let htmlCap = 128 * 1024

    private static func convertHTMLBlocks(_ source: String) -> String {
        var safe = source
        var codeSpans: [String] = []

        if source.count > htmlCap,
           let split = source.index(source.startIndex, offsetBy: htmlCap, limitedBy: source.endIndex)
        {
            return convertHTMLBlocks(String(source[..<split])) + String(source[split...])
        }

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
        safe = replacingAnchors(in: safe)

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

        safe = strippingComments(in: safe)
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

        // Keep Markdown indentation: nested list depth belongs to the parser.
        // Generated HTML markers already start at column zero. Collapse blank
        // lines without flattening original Markdown inside or beside HTML.
        safe = replace(pattern: #"[ \t]+\n"#, in: safe) { _, _ in "\n" }
        safe = replace(pattern: #"\n{3,}"#, in: safe) { _, _ in "\n\n" }
        // Consecutive HTML `<li>` rows should be one Markdown list, not 81
        // one-row lists separated by card-sized paragraph spacing.
        safe = replace(pattern: #"\n{2,}(?=- )"#, in: safe) { _, _ in "\n" }
        for (slot, code) in codeSpans.enumerated() {
            safe = safe.replacingOccurrences(of: "\u{E000}\(slot)\u{E001}", with: code)
        }
        return safe.trimmingCharacters(in: .newlines)
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
        guard let expression = expression(pattern) else { return source }
        let string = source as NSString
        let matches = expression.matches(in: source, range: NSRange(location: 0, length: string.length))
        let result = NSMutableString(string: source)
        for match in matches.reversed() {
            result.replaceCharacters(in: match.range, with: transform(match, string))
        }
        return result as String
    }

    /// Compiled patterns, so one document does not compile the same shape
    /// twenty times and every scroll afterward does not compile it again.
    /// `NSCache` is thread safe: `warm` runs
    /// through here on a detached task while a row may be parsing on the
    /// main one.
    private static let expressions: NSCache<NSString, NSRegularExpression> = {
        let cache = NSCache<NSString, NSRegularExpression>()
        cache.countLimit = 64
        return cache
    }()

    private static func expression(_ pattern: String) -> NSRegularExpression? {
        if let cached = expressions.object(forKey: pattern as NSString) { return cached }
        guard let compiled = try? NSRegularExpression(pattern: pattern) else { return nil }
        expressions.setObject(compiled, forKey: pattern as NSString)
        return compiled
    }

    /// Convert `<a href="…">label</a>` to Markdown in one pass.
    ///
    /// The regular expression this replaced searched for a close tag with
    /// `[\s\S]*?` from every open one, and its open-tag shape scanned to the
    /// end of the document for every `<a` with no `>`, so input full of
    /// half-written anchors was quadratic. Open and close tags are each found
    /// in one forward scan here, then paired by position, so no part of the
    /// text is ever rescanned.
    private static func replacingAnchors(in source: String) -> String {
        guard source.range(of: "<a", options: [.caseInsensitive]) != nil else { return source }
        let string = source as NSString
        let opens = anchorTags(in: string, closing: false)
        let closes = anchorTags(in: string, closing: true)
        guard !opens.isEmpty || !closes.isEmpty else { return source }
        let output = NSMutableString()
        var cursor = 0
        var openIndex = 0
        var closeIndex = 0
        var open: (href: String, tagEnd: Int)?

        while true {
            if let current = open {
                guard closeIndex < closes.count else {
                    // No close: the text stays as it is, exactly as it did
                    // when the regular expression declined to match and the
                    // generic tag stripper removed the lone open tag.
                    break
                }
                let close = closes[closeIndex]
                closeIndex += 1
                guard close.location >= current.tagEnd else { continue }
                let label = string.substring(
                    with: NSRange(location: current.tagEnd, length: close.location - current.tagEnd)
                )
                output.append(anchorMarkdown(href: current.href, label: label))
                cursor = close.location + close.length
                open = nil
                continue
            }

            while openIndex < opens.count, opens[openIndex].location < cursor { openIndex += 1 }
            while closeIndex < closes.count, closes[closeIndex].location < cursor { closeIndex += 1 }
            let nextOpen = openIndex < opens.count ? opens[openIndex] : nil
            let nextClose = closeIndex < closes.count ? closes[closeIndex] : nil
            guard nextOpen != nil || nextClose != nil else { break }
            if let close = nextClose, nextOpen == nil || close.location < nextOpen!.location {
                // A stray close tag. Keep it for the generic stripper, which
                // is what removed it before.
                output.append(string.substring(with: NSRange(location: cursor, length: close.location + close.length - cursor)))
                cursor = close.location + close.length
                closeIndex += 1
                continue
            }
            let tag = nextOpen!
            output.append(string.substring(with: NSRange(location: cursor, length: tag.location - cursor)))
            cursor = tag.location + tag.length
            openIndex += 1
            let text = string.substring(with: tag)
            if let href = hrefValue(in: text) {
                open = (href, cursor)
            } else {
                output.append(text)
            }
        }

        if cursor < string.length {
            output.append(string.substring(from: cursor))
        }
        return output as String
    }

    /// Every `<a …>` or `</a>` in the text, in one forward scan.
    ///
    /// `<a` only counts when a letter cannot continue it, so `<abbr>` is not
    /// an anchor, and a tag with no `>` ends the scan instead of being
    /// searched for again: that is what keeps this linear where the regular
    /// expression was not.
    private static func anchorTags(in string: NSString, closing: Bool) -> [NSRange] {
        let literal = closing ? "</a" : "<a"
        var tags: [NSRange] = []
        var search = 0
        while search < string.length {
            let found = string.range(
                of: literal,
                options: [.caseInsensitive],
                range: NSRange(location: search, length: string.length - search)
            )
            guard found.location != NSNotFound else { break }
            var index = found.location + found.length
            guard index < string.length, isAnchorBoundary(string.character(at: index)) else {
                search = found.location + 1
                continue
            }
            if closing {
                while index < string.length, isHTMLWhitespace(string.character(at: index)) { index += 1 }
                guard index < string.length, string.character(at: index) == 62 else {
                    search = found.location + 1
                    continue
                }
                tags.append(NSRange(location: found.location, length: index + 1 - found.location))
                search = index + 1
            } else {
                let end = string.range(
                    of: ">",
                    options: [],
                    range: NSRange(location: index, length: string.length - index)
                )
                guard end.location != NSNotFound else { break }
                tags.append(NSRange(location: found.location, length: end.location + 1 - found.location))
                search = end.location + 1
            }
        }
        return tags
    }

    /// The `href` attribute of one already-bounded tag, or nil.
    private static func hrefValue(in tag: String) -> String? {
        guard let expression = expression(#"(?i)href\s*=\s*["']([^"']+)["']"#) else { return nil }
        let string = tag as NSString
        let match = expression.firstMatch(in: tag, range: NSRange(location: 0, length: string.length))
        guard let match, match.range(at: 1).location != NSNotFound else { return nil }
        return string.substring(with: match.range(at: 1))
    }

    /// The label and destination as Markdown, or the label alone when the
    /// destination is not one the app will open.
    ///
    /// A body is untrusted text. Only http, https and mailto reach the URL
    /// handler; anything else is shown as its label, so a `javascript:` or
    /// `file:` href can no more become a live link than it could when the tag
    /// was dropped outright. A destination with whitespace or a bracket in it
    /// could otherwise break out of the `[label](url)` shape and inject
    /// Markdown, so those are refused too, and the label's own brackets are
    /// escaped so it cannot close the link early.
    private static func anchorMarkdown(href: String, label rawLabel: String) -> String {
        var label = strippingTags(in: rawLabel)
        label = label.trimmingCharacters(in: .whitespacesAndNewlines)
        if label.isEmpty { label = href }
        guard let scheme = URL(string: href)?.scheme?.lowercased(),
              ["http", "https", "mailto"].contains(scheme),
              !href.contains(where: { $0.isWhitespace || "()<>`\"'".contains($0) })
        else {
            return label
        }
        label = label
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "[", with: "\\[")
            .replacingOccurrences(of: "]", with: "\\]")
        return "[\(label)](\(href))"
    }

    /// Drop `<!-- … -->` in one forward pass.
    ///
    /// The lazy `[\s\S]*?-->` this replaced rescanned a document's whole
    /// remainder from every `<!--` when no `-->` followed, which is quadratic
    /// on text built exactly that way. An unterminated comment is left alone,
    /// as before.
    private static func strippingComments(in source: String) -> String {
        guard source.range(of: "<!--") != nil else { return source }
        let string = source as NSString
        let output = NSMutableString()
        var cursor = 0
        while cursor < string.length {
            let open = string.range(
                of: "<!--",
                options: [],
                range: NSRange(location: cursor, length: string.length - cursor)
            )
            guard open.location != NSNotFound else { break }
            output.append(string.substring(with: NSRange(location: cursor, length: open.location - cursor)))
            let afterOpen = open.location + open.length
            let close = string.range(
                of: "-->",
                options: [],
                range: NSRange(location: afterOpen, length: string.length - afterOpen)
            )
            guard close.location != NSNotFound else {
                output.append(string.substring(from: open.location))
                return output as String
            }
            cursor = close.location + close.length
        }
        if cursor < string.length {
            output.append(string.substring(from: cursor))
        }
        return output as String
    }

    /// Remove `<…>` tag spans from a label, in one forward pass.
    ///
    /// `[^>]+` between literal brackets scans to the end of the string from
    /// every `<` when no `>` follows, so a label built from `<` characters
    /// was quadratic. This never looks past the next `<` or `>`, and leaves
    /// an unterminated tag in place as the regular expression did.
    private static func strippingTags(in source: String) -> String {
        guard source.contains("<") else { return source }
        let string = source as NSString
        let output = NSMutableString()
        var cursor = 0
        while cursor < string.length {
            let open = string.range(
                of: "<",
                options: [],
                range: NSRange(location: cursor, length: string.length - cursor)
            )
            guard open.location != NSNotFound else { break }
            output.append(string.substring(with: NSRange(location: cursor, length: open.location - cursor)))
            let afterOpen = open.location + open.length
            let close = string.range(
                of: ">",
                options: [],
                range: NSRange(location: afterOpen, length: string.length - afterOpen)
            )
            guard close.location != NSNotFound else {
                output.append(string.substring(from: open.location))
                return output as String
            }
            cursor = close.location + close.length
        }
        if cursor < string.length {
            output.append(string.substring(from: cursor))
        }
        return output as String
    }

    /// A tag boundary: whitespace or the `>` that ends an attribute list.
    private static func isAnchorBoundary(_ character: unichar) -> Bool {
        character == 62 || isHTMLWhitespace(character)
    }

    private static func isHTMLWhitespace(_ character: unichar) -> Bool {
        character == 32 || character == 9 || character == 10 || character == 13
    }

    private static func substring(_ range: NSRange, in string: NSString) -> String {
        guard range.location != NSNotFound else { return "" }
        return string.substring(with: range)
    }
}
