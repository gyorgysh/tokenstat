// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
//
// Source-available for review, NOT open source. See LICENSE: no rights to
// redistribute, publish, or ship a build are granted. Read it, study it, run
// your own build of it.
// "tokenstat" is a trademark of pueev OU. See TRADEMARK.md.

#if os(macOS)
import AppKit

/// The font a terminal draws with, and the grid that fits in a given area.
///
/// One definition, used both by the view that renders and by the pane that has
/// to work out rows and columns *before* a session exists so it can be spawned
/// at its final size.
///
/// SwiftTerm keeps its cell metrics internal, so this reproduces
/// `computeFontDimensions` exactly: the advancement of the `W` glyph, and
/// ascent plus descent plus leading rounded up. It has to be exact. An estimate
/// that is one column out means the first layout resizes the pty, the shell
/// gets SIGWINCH, and it reprints its prompt, which is the flash on launch this
/// exists to remove.
enum TerminalMetrics {
    static let font = AppFonts.terminal(size: 12)

    /// Width and height of one character cell. Computed once: it changes only
    /// if the font does.
    static let cell: CGSize = {
        let width = font.advancement(forGlyph: font.glyph(withName: "W")).width
        let height = ceil(
            CTFontGetAscent(font) + CTFontGetDescent(font) + CTFontGetLeading(font)
        )
        return CGSize(width: max(1, width), height: max(1, min(height, 8192)))
    }()

    /// The scroller SwiftTerm puts down the right edge, which is not available
    /// to text. Forgetting it costs a column or two and is enough on its own to
    /// trigger the resize this is meant to avoid.
    static let scrollerWidth = NSScroller.scrollerWidth(for: .regular, scrollerStyle: .legacy)

    /// The grid that fits in an area, the way SwiftTerm works it out.
    static func grid(fitting size: CGSize) -> (rows: Int, cols: Int) {
        let usable = size.width - scrollerWidth
        guard usable > cell.width, size.height > cell.height else { return (24, 80) }
        return (
            max(1, Int(size.height / cell.height)),
            max(1, Int(usable / cell.width))
        )
    }
}
#endif
