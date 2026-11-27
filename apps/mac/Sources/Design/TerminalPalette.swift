// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
//
// Source-available: source sharing and own builds are permitted.
// Store and commercial distribution of builds is reserved. See LICENSE.
// "tokenstat" is a trademark of pueev OU. See TRADEMARK.md.

import SwiftTerm
import SwiftUI

#if os(macOS)
import AppKit
#else
import UIKit
#endif

enum TerminalPalette {
    static func background(dark: Bool) -> UInt32 { dark ? 0x0A0A0B : 0xF7F7F8 }
    static func foreground(dark: Bool) -> UInt32 { dark ? 0xDCDC_E0 : 0x1C1C_1F }

    /// The same background as a SwiftUI colour, for the pane a terminal sits
    /// in rather than the cells themselves.
    ///
    /// A terminal view does not fill its container: a split gutter, the strip
    /// of a pane wider than the columns fit, and the moment before the first
    /// frame are all drawn by whatever is behind it. That was `Color.black`,
    /// which is invisible in dark mode and a hole in the window in light mode.
    /// Taking both shades from the same numbers the cells use means the seam
    /// cannot be seen at all.
    static let surface = SwiftUI.Color.adaptive(
        light: swiftUI(background(dark: false)),
        dark: swiftUI(background(dark: true))
    )

    /// The SwiftUI colour for one of the hexes above. Spelled out, because
    /// SwiftTerm brings a `Color` of its own into this file.
    static func swiftUI(_ hex: UInt32) -> SwiftUI.Color {
        SwiftUI.Color(
            .sRGB,
            red: Double((hex >> 16) & 0xFF) / 255,
            green: Double((hex >> 8) & 0xFF) / 255,
            blue: Double(hex & 0xFF) / 255,
            opacity: 1
        )
    }

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

    static var systemIsDark: Bool {
        #if os(macOS)
        let appearance = NSApp?.effectiveAppearance ?? NSAppearance.currentDrawing()
        return appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
        #else
        return UITraitCollection.current.userInterfaceStyle == .dark
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
