// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
//
// Source-available for review, NOT open source. See LICENSE: no rights to
// redistribute, publish, or ship a build are granted. Read it, study it, run
// your own build of it.
// "tokenstat" is a trademark of pueev OU. See TRADEMARK.md.

/// Which folder chats the sidebar draws, and where arrow keys land.
///
/// Five rows fit without pushing the sections below off screen; ten is the
/// warm set the list grows to. Past ten the inline list stops: the full chat
/// window owns search, so it owns the archive too. Arrow keys loop instead
/// of stopping at either end, so holding one cycles the warm set and every
/// landing is already on screen.
enum ChatHistoryWindow {
    /// Rows drawn without asking. Fits under the sections below.
    static let collapsedLimit = 5
    /// Rows drawn when expanded. The warm set: small enough to stay built,
    /// large enough that looping feels instant.
    static let inlineLimit = 10

    /// The slice of `0..<count` to draw for `selected` (nil when nothing in
    /// this folder is selected) and the manual `expanded` state.
    ///
    /// A selection at or past the collapsed few opens a window of at most
    /// ten around it, so the lit row is always drawn. Otherwise expanded
    /// draws the first ten and collapsed the first five.
    static func visible(count: Int, selected: Int?, expanded: Bool) -> Range<Int> {
        guard count > 0 else { return 0..<0 }
        if let s = selected, s >= 0, s < count, expanded || s >= collapsedLimit {
            if count <= inlineLimit { return 0..<count }
            // Inside the first ten the window stays put: sliding it for
            // selections 5 through 9 would shift the list under every step.
            if s < inlineLimit { return 0..<inlineLimit }
            let start = min(s - 4, count - inlineLimit)
            return start..<(start + inlineLimit)
        }
        if expanded { return 0..<min(count, inlineLimit) }
        return 0..<min(count, collapsedLimit)
    }

    /// The index one step from `current`, looping inside the warm ten.
    /// Nil when there is nothing to land on. The loop never walks the
    /// archive: those ten stay built, so holding the arrow feels instant,
    /// and older chats live behind See-all. A selection outside the loop
    /// (from search or the overview) re-enters it at the end stepped from.
    static func looped(count: Int, current: Int?, step: Int) -> Int? {
        let bound = min(count, inlineLimit)
        guard bound > 0, step == -1 || step == 1 else { return nil }
        guard let current, current >= 0, current < bound else {
            return step > 0 ? 0 : bound - 1
        }
        return (current + step + bound) % bound
    }
}
