// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
//
// Source-available: source sharing and own builds are permitted.
// Store and commercial distribution of builds is reserved. See LICENSE.
// "tokenstat" is a trademark of pueev OÜ. See TRADEMARK.md.

import CoreText
import SwiftUI
#if os(macOS)
import AppKit
#else
import UIKit
#endif

enum AppFonts {
    static let interface = "Manrope"
    static let mono = "JetBrains Mono"

    private(set) nonisolated(unsafe) static var registered = false

    static func register() {
        struct Once { nonisolated(unsafe) static var done = false }
        guard !Once.done else { return }
        Once.done = true

        let files = ["Manrope-Variable", "JetBrainsMono-Variable"]
        var registeredAll = true
        for name in files {
            guard let url = Bundle.main.url(forResource: name, withExtension: "ttf") else {
                registeredAll = false
                continue
            }
            var error: Unmanaged<CFError>?
            if !CTFontManagerRegisterFontsForURL(url as CFURL, .process, &error) {
                var alreadyThere = false
                if let failure = error?.takeRetainedValue() {
                    alreadyThere = CFErrorGetCode(failure)
                        == CTFontManagerError.alreadyRegistered.rawValue
                }
                if !alreadyThere { registeredAll = false }
            }
        }
        registered = registeredAll
    }

    /// A platform font for the terminal, which takes an `NSFont`/`UIFont` and
    /// not a SwiftUI `Font`.
    ///
    /// Falls back to the system monospaced face by the same rule as everything
    /// else: a terminal in a proportional fallback face is unusable, so it is
    /// better to be the wrong monospace than the wrong shape.
    ///
    /// Takes no weight on purpose: `NSFont(name:size:)` picks the Regular
    /// instance of the variable face and has nothing to name a weight with,
    /// so an argument here would be honoured on the fallback path and
    /// silently dropped on the real one. If a weighted terminal face is ever
    /// wanted, select it through the font's `wght` variation axis.
    #if os(macOS)
    static func terminal(size: CGFloat) -> NSFont {
        guard registered, let font = NSFont(name: mono, size: size) else {
            return .monospacedSystemFont(ofSize: size, weight: .regular)
        }
        return font
    }
    #else
    static func terminal(size: CGFloat) -> UIFont {
        guard registered, let font = UIFont(name: mono, size: size) else {
            return .monospacedSystemFont(ofSize: size, weight: .regular)
        }
        return font
    }
    #endif
}
