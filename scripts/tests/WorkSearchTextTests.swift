// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
// Compile with WorkSearchText.swift.
import Foundation

@main struct WorkSearchTextTests {
    static func main() throws {
        let query = try WorkSearchQuery("  CAFÉ\n café  ")
        assert(query.terms == ["café"])
        let original = "👩🏽‍💻 Cafe\u{301}, CAFÉ and Straße."
        let text = WorkSearchText(original)
        assert(text.contains(query.terms[0]))
        let excerpt = text.excerpt(for: query)
        assert(excerpt.text == original)
        assert(excerpt.highlights.map { (excerpt.text as NSString).substring(with: $0) } == ["Cafe\u{301}", "CAFÉ"])
        let expanded = text.excerpt(for: try WorkSearchQuery("STRASSE"))
        assert(expanded.highlights.map { (expanded.text as NSString).substring(with: $0) } == ["Straße"])
        let partialFold = WorkSearchText("ß").excerpt(for: try WorkSearchQuery("s ss"))
        assert(partialFold.highlights == [NSRange(location: 0, length: 1)])

        let literal = try WorkSearchQuery(".* [x] OR")
        assert(!WorkSearchText("anything").contains(literal.terms[0]))
        assert(WorkSearchText("literal .* [x] OR").contains(literal.terms[0]))
        let emoji = WorkSearchText("Before 👨‍👩‍👧‍👦 after").excerpt(for: try WorkSearchQuery("👨‍👩‍👧‍👦"))
        assert((emoji.text as NSString).substring(with: emoji.highlights[0]) == "👨‍👩‍👧‍👦")
        let long = String(repeating: "👩🏽‍💻", count: 300) + " needle " + String(repeating: "e\u{301}", count: 300)
        let bounded = WorkSearchText(long).excerpt(for: try WorkSearchQuery("needle"))
        assert(bounded.text.count == 240 && bounded.text.hasPrefix("…") && bounded.text.hasSuffix("…"))
        assert((bounded.text as NSString).substring(with: bounded.highlights[0]) == "needle")
        let sentence = "An introduction with some context. Preserve original accents and emoji in highlighted results. Make the layout comfortable at larger text sizes."
        let words = WorkSearchText(sentence).excerpt(for: try WorkSearchQuery("layout"))
        assert(!words.text.hasPrefix("…ents"))
        if words.text.hasPrefix("…") {
            let body = String(words.text.dropFirst())
            let location = sentence.range(of: body)!.lowerBound
            assert(location == sentence.startIndex || sentence[sentence.index(before: location)].isWhitespace)
        }
        let ending = WorkSearchText(String(repeating: "x", count: 300) + " needle").excerpt(for: try WorkSearchQuery("needle"))
        assert(ending.text.hasPrefix("…") && !ending.text.hasSuffix("…"))
        let empty = try WorkSearchQuery("")
        assert(WorkSearchText("").excerpt(for: empty).text.isEmpty)
        let maximum = try WorkSearchQuery(String(repeating: "a", count: 512))
        assert(maximum.terms.count == 1)
        let clipped = WorkSearchText(String(repeating: "a", count: 512)).excerpt(for: maximum)
        assert(clipped.text.count == 240)
        assert(clipped.highlights == [NSRange(location: 0, length: 239)])
        do {
            _ = try WorkSearchQuery(String(repeating: "a", count: 513))
            assertionFailure("Oversized query accepted")
        } catch WorkSearchQuery.Invalid.tooLong {}
        do {
            _ = try WorkSearchQuery("a" + String(repeating: "\u{301}", count: WorkSearchQuery.maximumUTF8Bytes))
            assertionFailure("Oversized combining sequence accepted")
        } catch WorkSearchQuery.Invalid.tooLong {}
        let oversizedExcerpt = WorkSearchText("a" + String(repeating: "\u{301}", count: 20_000)).excerpt(for: empty)
        assert(oversizedExcerpt.text == "…" && oversizedExcerpt.highlights.isEmpty)
        print("Work search text: literal terms, Unicode folding, original highlights and bounded excerpts passed")
    }
}
