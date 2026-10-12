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
        print("Markdown sanitization: nested lists, mixed HTML, fenced literals and safe links passed")
    }
}
