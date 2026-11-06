// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
// Compile with MarkdownLinks.swift, SimulatorDevice.swift, DesktopOpenRequest.swift and DesktopWorkbenchState.swift using swiftc -parse-as-library.
import SwiftUI

// The standalone helper test does not link the application's full palette.
enum Theme { static let secondary = Color.pink }

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
        for source in ["", "short text", "é👩🏽‍💻", String(repeating: "long streamed word ", count: 2000),
                       String(repeating: "é👩🏽‍💻", count: 5000)] {
            var value = AttributedString(source)
            value.link = URL(string: "https://example.com/full-path")
            value.inlinePresentationIntent = [.stronglyEmphasized, .code]
            for maximum in source.count < 32 ? [1, 8000] : [8000] {
                let chunks = MarkdownTextChunks.split(value, maximum: maximum)
                precondition(chunks.allSatisfy { !$0.characters.isEmpty && $0.characters.count <= maximum },
                             "Every rendered chunk must stay bounded, even without line breaks or spaces")
                var restored = AttributedString()
                for chunk in chunks { restored.append(chunk) }
                precondition(restored == value, "Splitting must preserve graphemes, whitespace, links and inline formatting")
            }
        }
        #if os(macOS)
        let action = try AttributedString(markdown: "[Review](tokenstat://workbench/open?workspace=project-a&tool=changes) [Reject](tokenstat://workbench/open?workspace=project-a&tool=terminal&command=echo)")
        let actions = MarkdownLinks.styled(action, color: .purple).runs.compactMap(\.link)
        precondition(actions.count == 1 && actions[0].host == "workbench")
        let map = MarkdownLinkHitMap()
        let first = URL(string: "https://example.com/one")!
        let second = URL(string: "https://example.com/two")!
        map.replace([.init(url: first, rect: CGRect(x: 40, y: 0, width: 90, height: 18)),
                     .init(url: first, rect: CGRect(x: 0, y: 20, width: 45, height: 18)),
                     .init(url: second, rect: CGRect(x: 75, y: 20, width: 50, height: 18))])
        precondition(map.url(at: CGPoint(x: 50, y: 8)) == first)
        precondition(map.url(at: CGPoint(x: 15, y: 25)) == first, "Wrapped pieces retain their destination")
        precondition(map.url(at: CGPoint(x: 85, y: 25)) == second)
        precondition(map.url(at: CGPoint(x: 60, y: 25)) == nil, "Plain text and spaces between links do not hover")
        precondition(map.url(at: CGPoint(x: 140, y: 25)) == nil)
        map.replace([])
        precondition(map.url(at: CGPoint(x: 50, y: 8)) == nil, "A changed layout cannot leave stale targets")
        #endif
        print("MarkdownLinksTests passed")
    }
}
