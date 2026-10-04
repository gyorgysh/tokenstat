// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
// Compile with MarkdownLinks.swift using swiftc -parse-as-library.
import SwiftUI

@main
struct MarkdownLinksTests {
    static func main() throws {
        let source = "Plain [**web**](https://example.com/a?q=b#part) [mail](mailto:hello@example.com) [local](file:///tmp/private) [app](x-man-page:ls) [script](javascript:alert)"
        var parsed = try AttributedString(markdown: source, options: .init(interpretedSyntax: .inlineOnly))
        // Native Markdown versions differ in how they carry emphasis inside
        // link labels. Exercise an existing format attribute explicitly.
        parsed[parsed.range(of: "web")!].inlinePresentationIntent = .stronglyEmphasized
        let styled = MarkdownLinks.styled(parsed, color: .purple)
        precondition(String(styled.characters) == String(parsed.characters), "Styling must preserve all labels")
        let linked = styled.runs.filter { $0.link != nil }
        precondition(linked.count == 2, "Only supported schemes remain clickable")
        for run in linked {
            precondition(run.foregroundColor == .purple && run.underlineStyle != nil,
                         "Each clickable link must have a visible affordance")
        }
        precondition(linked.first?.link?.absoluteString == "https://example.com/a?q=b#part",
                     "The destination must keep its full path, query and fragment")
        precondition(linked.first?.inlinePresentationIntent?.contains(.stronglyEmphasized) == true,
                     "Link styling must preserve emphasis")
        for run in styled.runs where run.link == nil {
            precondition(run.underlineStyle == nil, "Plain and rejected links must not appear clickable")
        }
        print("MarkdownLinksTests passed")
    }
}
