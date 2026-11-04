// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
// Compile with MarkdownSanitizer.swift.
import Foundation

@main struct MarkdownSanitizerTests {
    static func main() {
        let nested = "- Parent\n  - Child\n    - Grandchild\n\t- Tab child"
        assert(MarkdownSanitizer.blocks(nested) == nested, "Preserve nested list indentation")
        let mixed = "<h2>Heading</h2>\n\n" + nested
        assert(MarkdownSanitizer.blocks(mixed) == "## Heading\n" + nested,
               "HTML conversion must also preserve Markdown list depth")
        assert(MarkdownSanitizer.blocks("<ul>\n  <li>One</li>\n  <li>Two</li>\n</ul>") == "- One\n- Two")
        let fenced = "```html\n  <strong>Literal</strong>\n```"
        assert(MarkdownSanitizer.blocks(fenced) == fenced)
        assert(MarkdownSanitizer.blocks("`<strong>literal</strong>`") == "`<strong>literal</strong>`")
        assert(MarkdownSanitizer.blocks("<a href=\"javascript:alert(1)\">Unsafe</a>") == "Unsafe")
        assert(MarkdownSanitizer.blocks("<a href=\"https://example.com\">Safe</a>") == "[Safe](https://example.com)")

        let rows = (0..<1500).map { "<p><strong>Row \($0)</strong> café <em>東京</em></p>" }
        let expected = (0..<1500).map { "**Row \($0)** café *東京*" }.joined(separator: "\n\n")
        assert(MarkdownSanitizer.blocks(rows.joined(separator: "\n")) == expected,
               "Many replacements preserve source order and Unicode boundaries")
        let spans = "`<strong>first</strong>` <strong>bold</strong> `<em>second</em>` <em>last</em>"
        assert(MarkdownSanitizer.blocks(spans) == "`<strong>first</strong>` **bold** `<em>second</em>` *last*",
               "Numbered code-span placeholders restore their original content")
        assert(MarkdownSanitizer.inline("👩🏽‍💻 [one](/tmp/one.png) café [two](sandbox:/tmp/two.png)") == "👩🏽‍💻 one café two")
        assert(MarkdownSanitizer.inline("![日本語](https://example.com/a.png) ![](https://example.com/b.png)")
               == "[Image: 日本語](https://example.com/a.png) [Image](https://example.com/b.png)")
        assert(MarkdownSanitizer.blocks("  café \t\n\n\n- one\n\n- two  ") == "  café\n- one\n- two  ",
               "Whitespace replacement and trimming retain their existing behavior")
        print("Markdown sanitization: nested lists, mixed HTML, fenced literals and safe links passed")
    }
}
