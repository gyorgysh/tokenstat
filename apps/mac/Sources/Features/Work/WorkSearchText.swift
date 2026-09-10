// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
import Foundation

/// Literal search terms, never regular expressions or database syntax.
struct WorkSearchQuery: Equatable, Sendable {
    static let maximumCharacters = 512
    static let maximumUTF8Bytes = 16 * 1024
    let terms: [String]

    enum Invalid: Error { case tooLong }

    init(_ text: String) throws {
        guard text.utf8.count <= Self.maximumUTF8Bytes,
              text.count <= Self.maximumCharacters else { throw Invalid.tooLong }
        var seen = Set<String>()
        terms = text.split(whereSeparator: \.isWhitespace).map {
            WorkSearchText.normalize(String($0))
        }.filter { !$0.isEmpty && seen.insert($0).inserted }
    }
}

/// Disposable memory only. Character boundaries map folded matches back to
/// the original words so accents and multi-scalar emoji remain intact.
struct WorkSearchText: Sendable {
    struct Excerpt: Equatable, Sendable {
        let text: String
        /// UTF-16 ranges in text, suitable for native attributed strings.
        let highlights: [NSRange]
    }

    static let maximumExcerptCharacters = 240
    let original: String
    private let folded: String

    init(_ text: String) {
        original = text
        folded = Self.normalize(text)
    }

    static func normalize(_ text: String) -> String {
        text.folding(options: .caseInsensitive, locale: Locale(identifier: "en_US_POSIX"))
            .precomposedStringWithCanonicalMapping
    }

    func contains(_ term: String) -> Bool {
        folded.range(of: term, options: .literal) != nil
    }

    func excerpt(for query: WorkSearchQuery) -> Excerpt {
        // Mapping costs more memory than the text. Build it only for visible
        // result excerpts, not for every indexed message.
        let rawMatches = query.terms.compactMap { term in
            folded.range(of: term, options: .literal).map { NSRange($0, in: folded) }
        }.sorted { $0.location < $1.location }
        let firstOffset = rawMatches.first?.location ?? 0
        let characters = Array(original)
        var foldedOffsets = [0]
        var offset = 0
        var contextRemaining = Self.maximumExcerptCharacters
        for character in characters {
            offset += Self.normalize(String(character)).utf16.count
            foldedOffsets.append(offset)
            if offset >= firstOffset {
                contextRemaining -= 1
                if contextRemaining == 0 { break }
            }
        }
        func boundary(at offset: Int, roundingUp: Bool) -> Int {
            var low = 0
            var high = foldedOffsets.count
            while low < high {
                let middle = (low + high) / 2
                if foldedOffsets[middle] < offset { low = middle + 1 } else { high = middle }
            }
            if low < foldedOffsets.count, foldedOffsets[low] == offset { return low }
            return roundingUp ? min(low, foldedOffsets.count - 1) : max(0, low - 1)
        }

        let matches = rawMatches.compactMap { utf16 -> Range<Int>? in
            guard utf16.location < offset else { return nil }
            // A fold can expand one character (ß to ss). Highlight the
            // whole original character, including a match within an expansion.
            return boundary(at: utf16.location, roundingUp: false)..<boundary(at: NSMaxRange(utf16), roundingUp: true)
        }

        let budget = Self.maximumExcerptCharacters
        let first = matches.first?.lowerBound ?? 0
        var start = max(0, first - 48)
        let earliest = max(0, start - 24)
        while start > earliest, !characters[start - 1].isWhitespace { start -= 1 }
        // A long unbroken token has no useful word boundary. Keep the
        // original context budget rather than chasing its beginning.
        if start == earliest, start > 0, !characters[start - 1].isWhitespace { start = max(0, first - 48) }
        let prefix = start > 0 ? 1 : 0
        var end = min(characters.count, start + budget - prefix)
        if end < characters.count { end -= 1 }
        var bytes = prefix * "…".utf8.count
        for index in start..<end {
            let length = String(characters[index]).utf8.count
            if bytes + length + "…".utf8.count > 16 * 1024 { end = index; break }
            bytes += length
        }
        let suffix = end < characters.count
        let body = String(characters[start..<end])
        let text = (prefix == 1 ? "…" : "") + body + (suffix ? "…" : "")
        var visibleMatches = matches.compactMap { match -> Range<Int>? in
            let lower = max(start, match.lowerBound)
            let upper = min(end, match.upperBound)
            return lower < upper ? lower..<upper : nil
        }
        let searchEnd = String.Index(utf16Offset: foldedOffsets[end], in: folded)
        for term in query.terms {
            var searchStart = String.Index(utf16Offset: foldedOffsets[start], in: folded)
            while searchStart < searchEnd,
                  let range = folded.range(of: term, options: .literal, range: searchStart..<searchEnd) {
                let utf16 = NSRange(range, in: folded)
                visibleMatches.append(boundary(at: utf16.location, roundingUp: false)..<boundary(at: NSMaxRange(utf16), roundingUp: true))
                searchStart = range.upperBound
            }
        }
        var ranges: [Range<Int>] = []
        for clipped in visibleMatches.sorted(by: { $0.lowerBound < $1.lowerBound }) {
            if let previous = ranges.last, previous.upperBound >= clipped.lowerBound {
                ranges[ranges.count - 1] = previous.lowerBound..<max(previous.upperBound, clipped.upperBound)
            } else {
                ranges.append(clipped)
            }
        }
        let highlights = ranges.map { range in
            NSRange(location: prefix + String(characters[start..<range.lowerBound]).utf16.count,
                    length: String(characters[range]).utf16.count)
        }
        return Excerpt(text: text, highlights: highlights)
    }

}
