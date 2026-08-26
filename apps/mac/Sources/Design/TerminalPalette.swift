// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
//
// Source-available for review, NOT open source. See LICENSE: no rights to
// redistribute, publish, or ship a build are granted. Read it, study it, run
// your own build of it.
// "tokenstat" is a trademark of pueev OU. See TRADEMARK.md.

import SwiftTerm
import SwiftUI

#if os(macOS)
import AppKit
#else
import UIKit
#endif

/// The two surfaces every terminal in this app draws on.
///
/// One place, because there were three copies and the third one forgot.
/// `TerminalSession` painted its view, `ClientTerminalSession` painted its
/// view, and `SSHLiveTerminal` set a font and a delegate and no colours at
/// all.
///
/// **A terminal with no `nativeBackgroundColor` does not erase.** The colour is
/// not decoration: it is what the emulator fills a cell with before it draws
/// the glyph that belongs there. Without one, every repaint composited on top
/// of whatever was already in the cell, so old output never went away, new
/// output landed on top of it, and `clear` painted the same absent colour over
/// the same pixels and changed nothing. It looked like the screen was stacking
/// because it was.
///
/// Setting it also sets the emulator's own background, which is what a running
/// program's OSC 11 query is answered from. That is the only channel a TUI has
/// for asking what it is drawing on, so it has to be right before the process
/// draws anything.
enum TerminalPalette {
    /// Behind the text. A shade off the app's own background, because a
    /// terminal is content rather than chrome and should not read as a hole.
    static func background(dark: Bool) -> UInt32 { dark ? 0x0A0A0B : 0xF7F7F8 }
    /// The text, where the program has not asked for a colour of its own.
    static func foreground(dark: Bool) -> UInt32 { dark ? 0xDCDC_E0 : 0x1C1C_1F }

    /// Paint a view, and ask it to redraw with what it now knows.
    static func paint(dark: Bool, to view: TerminalView) {
        view.nativeBackgroundColor = native(background(dark: dark))
        view.nativeForegroundColor = native(foreground(dark: dark))
        view.caretColor = native(accent: Theme.accent)
        #if os(macOS)
        view.setNeedsDisplay(view.bounds)
        #else
        view.setNeedsDisplay()
        #endif
    }

    /// Whether the system is in dark mode right now, asked the way each
    /// platform answers it.
    static var systemIsDark: Bool {
        #if os(macOS)
        NSApp?.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
        #else
        UITraitCollection.current.userInterfaceStyle == .dark
        #endif
    }

    #if os(macOS)
    static func native(_ hex: UInt32) -> NSColor {
        NSColor(
            srgbRed: CGFloat((hex >> 16) & 0xFF) / 255,
            green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255,
            alpha: 1
        )
    }

    static func native(accent: SwiftUI.Color) -> NSColor { NSColor(accent) }
    #else
    static func native(_ hex: UInt32) -> UIColor {
        UIColor(
            red: CGFloat((hex >> 16) & 0xFF) / 255,
            green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255,
            alpha: 1
        )
    }

    static func native(accent: SwiftUI.Color) -> UIColor { UIColor(accent) }
    #endif
}
