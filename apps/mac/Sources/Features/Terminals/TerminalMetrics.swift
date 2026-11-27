// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
//
// Source-available: source sharing and own builds are permitted.
// Store and commercial distribution of builds is reserved. See LICENSE.
// "tokenstat" is a trademark of pueev OU. See TRADEMARK.md.

#if os(macOS)
import AppKit

enum TerminalMetrics {
    static let font = AppFonts.terminal(size: 12)

    static let cell: CGSize = {
        let width = font.advancement(forGlyph: font.glyph(withName: "W")).width
        let height = ceil(
            CTFontGetAscent(font) + CTFontGetDescent(font) + CTFontGetLeading(font)
        )
        return CGSize(width: max(1, width), height: max(1, min(height, 8192)))
    }()

    static let scrollerWidth = NSScroller.scrollerWidth(for: .regular, scrollerStyle: .legacy)

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
