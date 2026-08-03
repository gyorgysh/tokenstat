// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
//
// Source-available for review, NOT open source. See LICENSE: no rights to
// redistribute, publish, or ship a build are granted. Read it, study it, run
// your own build of it.
// "tokenstat" and the tokenstat marks are trademarks of pueev OU and are not
// licensed with the code. See TRADEMARK.md.

import SwiftUI

/// Shared visual constants.
///
/// The brand colours are the same two the CLI uses (`ui.rs` `ACCENT_RGB` and
/// `SECONDARY_RGB`). One product, one palette: a user running both should not
/// see two different purples. Change them in both places or in neither.
enum Theme {
    static let accent = Color(red: 0xB2 / 255, green: 0x64 / 255, blue: 0xEB / 255)
    static let secondary = Color(red: 0x67 / 255, green: 0xE8 / 255, blue: 0xF9 / 255)

    /// Spacing scale. Four points, so layouts stay on a rhythm instead of
    /// accumulating one-off paddings.
    enum Space {
        static let xs: CGFloat = 4
        static let s: CGFloat = 8
        static let m: CGFloat = 12
        static let l: CGFloat = 20
        static let xl: CGFloat = 32
    }

    static let cardRadius: CGFloat = 10

    /// Numbers that sit in columns must not jitter as they update, so anything
    /// numeric uses tabular figures with a monospaced digit face.
    static func numeric(_ size: CGFloat, weight: Font.Weight = .regular) -> Font {
        .system(size: size, weight: weight, design: .rounded).monospacedDigit()
    }
}

/// A titled panel. Used for every block in the content column so they share one
/// corner radius and one border treatment.
struct Card<Content: View>: View {
    var title: String
    var subtitle: String?
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.m) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.headline)
                if let subtitle {
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            content
        }
        .padding(Theme.Space.l)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: Theme.cardRadius))
    }
}

/// One headline number with its label.
struct Stat: View {
    var label: String
    var value: String
    /// Shown next to the value in a dimmer colour, for units or qualifiers.
    var note: String?
    var tint: Color = .primary

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.xs) {
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
            HStack(alignment: .firstTextBaseline, spacing: Theme.Space.xs) {
                Text(value)
                    .font(Theme.numeric(24, weight: .medium))
                    .foregroundStyle(tint)
                    // A wrapped headline figure is unreadable, and a `+` or `~`
                    // qualifier landing alone on the next line looks like a
                    // rendering fault rather than a caveat.
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)
                if let note {
                    Text(note)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// Explains a surface that is planned but not built, without pretending to be
/// one. Showing invented workspaces here would make the app a demo rather than
/// a tool, and would be impossible to tell apart from a bug once real data
/// exists.
struct NotBuiltYet: View {
    var title: String
    var symbol: String
    var summary: String
    var milestone: String

    var body: some View {
        VStack(spacing: Theme.Space.m) {
            Image(systemName: symbol)
                .font(.system(size: 34, weight: .light))
                .foregroundStyle(Theme.accent.opacity(0.65))
            Text(title)
                .font(.title3.weight(.medium))
            Text(summary)
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 380)
            Text(milestone)
                .font(.caption)
                .foregroundStyle(.tertiary)
                .padding(.top, Theme.Space.xs)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(Theme.Space.xl)
    }
}
