// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
//
// Source-available for review, NOT open source. See LICENSE: no rights to
// redistribute, publish, or ship a build are granted. Read it, study it, run
// your own build of it.
// "tokenstat" is a trademark of pueev OU. See TRADEMARK.md.

import Foundation
import Observation

/// Find and replace for one open file.
///
/// The Mac gets the system find bar from AppKit. UIKit has none, so this is
/// the shared model behind the iOS find bar: literal, case-insensitive
/// matches over the buffer, wrapping in both directions like the Mac bar.
///
/// Matching is pure text math on UTF-16 ranges, the same units `UITextView`
/// uses, and stays testable without a view. Replacements run through the
/// text view itself (see `IOSCodeTextView`), so undo, typing attributes and
/// input-method composition keep working. Deliberately not `@MainActor`:
/// the coordinator drives it on the main thread, and the standalone tests
/// exercise it without an actor hop.
@Observable
final class EditorFindSession {
    /// Bounded so a pathological query cannot mint unbounded ranges.
    static let matchLimit = 2000

    /// Showing and hiding repaints the match backgrounds: hiding must clear
    /// them rather than leave stale tint behind.
    var showing = false { didSet { revision &+= 1 } }
    /// Setting the query searches immediately. The bar binds its field to
    /// this and owns no buffer, so waiting for the caller to re-run the
    /// search by hand meant every keystroke in the field showed "No
    /// results" until the document itself changed.
    var query = "" { didSet { refresh(text: lastText) } }
    var replaceText = ""
    var replacing = false
    /// The text view is inside a live composition. Replacements wait.
    var composing = false
    /// The buffer as `refresh` last saw it: what a query keystroke searches.
    private var lastText = ""

    private(set) var matches: [NSRange] = []
    private(set) var currentIndex = 0
    private(set) var truncated = false
    /// Bumped on every match or index change. The text view repaints its
    /// match backgrounds only when this moves.
    private(set) var revision = 0

    enum Action {
        case next
        case previous
        case replaceCurrent
        case replaceAll
    }
    /// Set by the text view. The bar calls the `go`/`replace` methods below,
    /// which update this model first and then ask the view to act.
    var handler: ((Action) -> Void)?

    var hasQuery: Bool { !query.isEmpty }

    var current: NSRange? {
        guard hasQuery, !matches.isEmpty else { return nil }
        return matches[currentIndex % matches.count]
    }

    var countLabel: String? {
        guard hasQuery else { return nil }
        if matches.isEmpty { return "No results" }
        let position = (currentIndex % matches.count) + 1
        if truncated { return "\(position) of \(matches.count)+" }
        return "\(position) of \(matches.count)"
    }

    var canNavigate: Bool { hasQuery && matches.count > 1 }
    var canReplace: Bool { hasQuery && !matches.isEmpty && !composing }

    /// Recompute matches against the buffer. Keeps the current position
    /// when the same match is still there, otherwise clamps. Remembers the
    /// buffer, so the next query keystroke has something to search.
    func refresh(text: String) {
        lastText = text
        let found = Self.search(query: query, in: text)
        let previous = current
        matches = found.matches
        truncated = found.truncated
        if let previous, let index = matches.firstIndex(of: previous) {
            currentIndex = index
        } else {
            currentIndex = 0
        }
        revision &+= 1
    }

    func clear() {
        matches = []
        currentIndex = 0
        truncated = false
        revision &+= 1
    }

    func goNext() {
        guard canNavigate else { return }
        currentIndex = (currentIndex + 1) % matches.count
        revision &+= 1
        handler?(.next)
    }

    func goPrevious() {
        guard canNavigate else { return }
        currentIndex = (currentIndex + matches.count - 1) % matches.count
        revision &+= 1
        handler?(.previous)
    }

    func replaceCurrent() {
        guard canReplace else { return }
        handler?(.replaceCurrent)
    }

    func replaceAll() {
        guard canReplace else { return }
        handler?(.replaceAll)
    }

    private static func search(query: String, in text: String) -> (matches: [NSRange], truncated: Bool) {
        guard !query.isEmpty, !text.isEmpty else { return ([], false) }
        let haystack = text as NSString
        var out: [NSRange] = []
        var truncated = false
        var searchRange = NSRange(location: 0, length: haystack.length)
        while searchRange.length > 0 {
            let found = haystack.range(
                of: query,
                options: [.caseInsensitive],
                range: searchRange
            )
            guard found.location != NSNotFound else { break }
            out.append(found)
            if out.count >= matchLimit {
                truncated = true
                break
            }
            let next = found.location + max(found.length, 1)
            if next >= haystack.length { break }
            searchRange = NSRange(location: next, length: haystack.length - next)
        }
        return (out, truncated)
    }
}
