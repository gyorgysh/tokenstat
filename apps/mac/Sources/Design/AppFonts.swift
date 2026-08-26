// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
//
// Source-available for review, NOT open source. See LICENSE: no rights to
// redistribute, publish, or ship a build are granted. Read it, study it, run
// your own build of it.
// "tokenstat" is a trademark of pueev OÜ. See TRADEMARK.md.

import CoreText
import SwiftUI
#if os(macOS)
import AppKit
#else
import UIKit
#endif

/// The two typefaces the app is drawn in, and the one place that knows their
/// names.
///
/// # Why bundled rather than the system font
///
/// tokenstat is one product across a Mac app, an iPhone, an Android phone and
/// a website, and the system font is a different typeface on each of them. The
/// same screen cannot be the same screen if the words in it change shape
/// depending on which of your devices you are holding.
///
/// Manrope for everything a person reads as language: navigation, controls,
/// body text, headings, labels. JetBrains Mono for everything read character by
/// character, where a lowercase l and a digit 1 have to be different pictures:
/// terminals, commands, model identifiers, and numbers in a column.
///
/// # Why registered in code
///
/// `UIAppFonts` and `ATSApplicationFontsPath` are two different keys, spelled
/// differently, doing the same job on the two platforms, and both of them
/// depend on where in the bundle the resource phase happened to put the file.
/// One call that asks the bundle for the file by name is the same code on both
/// and cannot be broken by moving a folder.
///
/// # Why both are variable files
///
/// One file per family instead of seven. A variable font carries every weight
/// between 200 and 800 in one outline set, so the bundle pays 165 KB for
/// Manrope rather than seven static faces, and a weight that is not one of the
/// named instances is interpolated rather than faked by smearing.
enum AppFonts {
    /// Manrope. Language.
    static let interface = "Manrope"
    /// JetBrains Mono. Anything read character by character.
    static let mono = "JetBrains Mono"

    /// Whether the bundled faces actually registered.
    ///
    /// Read before every font is made, and false is not a theoretical state: a
    /// resource that failed to copy, or a file this version of CoreText will
    /// not parse, would otherwise render the entire app in whatever the system
    /// falls back to, which is a worse outcome than the system font chosen on
    /// purpose. See `Theme.font`.
    private(set) nonisolated(unsafe) static var registered = false

    /// Register the bundled faces with this process.
    ///
    /// Idempotent, and called before the first view is built. Registering into
    /// the process rather than the user's font book: these are the app's
    /// copies, and installing typefaces on somebody's Mac because they opened
    /// an app is not a thing an app should do.
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
                // Already registered is a success, not a failure: the same
                // file can be registered by a preview host before the app
                // itself gets to it.
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
