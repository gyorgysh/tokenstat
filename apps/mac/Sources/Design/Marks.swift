// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
//
// Source-available for review, NOT open source. See LICENSE: no rights to
// redistribute, publish, or ship a build are granted. Read it, study it, run
// your own build of it.
// "tokenstat" is a trademark of pueev OU. See TRADEMARK.md.

import SwiftUI

/// A harness's brand mark on a tinted tile.
///
/// Rendered as a template so one monochrome SVG works in both appearances.
/// Vendor marks are not ours: see TRADEMARK.md. A tool with no bundled mark
/// gets a letter tile rather than another tool's logo, because a wrong logo is
/// worse than no logo.
struct HarnessMark: View {
    var id: String
    var size: CGFloat = 22

    private var radius: CGFloat { size * 0.28 }

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: radius)
                .fill(Theme.accent.opacity(0.12))
            if let asset = harnessBrandAsset(id) {
                Image(asset)
                    .renderable(size: size * 0.58)
                    .foregroundStyle(Theme.accent)
            } else {
                Text(initial)
                    .font(.system(size: size * 0.46, weight: .semibold))
                    .foregroundStyle(Theme.accent)
            }
        }
        .frame(width: size, height: size)
    }

    private var initial: String {
        let name = harnessName(id)
        return name.first.map { String($0).uppercased() } ?? "?"
    }
}

private extension Image {
    /// Template-rendered and scaled to fit, which is what a monochrome mark
    /// needs to sit on a tinted tile.
    func renderable(size: CGFloat) -> some View {
        self
            .renderingMode(.template)
            .resizable()
            .scaledToFit()
            .frame(width: size, height: size)
    }
}

/// The account's profile picture, or a letter tile until it loads.
///
/// `AsyncImage` rather than a cache of our own: this is one small image per
/// launch, and the placeholder is the same letter tile shown when an account
/// has no picture at all, so nothing jumps when it arrives.
struct Avatar: View {
    var url: String?
    var handle: String?
    var size: CGFloat = 22

    var body: some View {
        ZStack {
            Circle().fill(Theme.accent.opacity(0.18))
            if let url, let parsed = URL(string: url) {
                AsyncImage(url: parsed) { phase in
                    switch phase {
                    case let .success(image):
                        image.resizable().scaledToFill()
                    default:
                        letter
                    }
                }
            } else {
                letter
            }
        }
        .frame(width: size, height: size)
        .clipShape(.circle)
    }

    private var letter: some View {
        Group {
            if let initial = handle?.first {
                Text(String(initial).uppercased())
                    .font(.system(size: size * 0.5, weight: .semibold))
                    .foregroundStyle(Theme.accent)
            } else {
                Image(systemName: "person.fill")
                    .font(.system(size: size * 0.45))
                    .foregroundStyle(.secondary)
            }
        }
    }
}

/// The tokenstat mark: three ascending bars on a shared baseline.
///
/// Drawn rather than shipped as an image. It is three rounded rectangles, so an
/// asset catalogue would be a resource to keep in step with the website's SVG
/// for no benefit, and a drawn mark is sharp at any size on any display.
///
/// The geometry is the website's, from `brand-assets/tokenstat/logo`: bars 12
/// wide on a 15 pitch, sharing a baseline, in a 64 unit square. **They share a
/// baseline on purpose**, which is what makes them read as a chart instead of
/// three floating shapes. The colours are the dark-context ramp the favicon
/// badge uses, since this sits on the app's own dark chrome. Change these with
/// the website, not on their own.
struct LogoMark: View {
    var size: CGFloat = 18

    private static let bars: [(y: CGFloat, height: CGFloat, color: Color)] = [
        (34, 18, Color(red: 0xC3 / 255, green: 0xB0 / 255, blue: 0xFF / 255)),
        (22, 30, Color(red: 0x8B / 255, green: 0x5C / 255, blue: 0xF6 / 255)),
        (10, 42, Color(red: 0xE8 / 255, green: 0x79 / 255, blue: 0xF9 / 255)),
    ]

    var body: some View {
        // One scale factor from the 64 unit artboard, so every number below is
        // the website's own and none of them are re-derived by hand.
        let unit = size / 64

        ZStack(alignment: .topLeading) {
            ForEach(Array(Self.bars.enumerated()), id: \.offset) { index, bar in
                RoundedRectangle(cornerRadius: 3.5 * unit)
                    .fill(bar.color)
                    .frame(width: 12 * unit, height: bar.height * unit)
                    .offset(x: (11 + CGFloat(index) * 15) * unit, y: bar.y * unit)
            }
        }
        .frame(width: size, height: size)
        .accessibilityLabel("tokenstat")
    }
}

/// The mark and the name, for the top of the sidebar.
struct Wordmark: View {
    var body: some View {
        HStack(spacing: Theme.Space.s) {
            LogoMark(size: 20)
            Text("tokenstat")
                .font(.system(size: 15, weight: .semibold))
                // Lowercase, always. It is the command you type.
                .textCase(.lowercase)
            Spacer()
        }
    }
}

/// The tier, as the glyph the website puts beside a name.
///
/// A crown for Patron, a star for Supporter, matching `TIER_BADGES` on the
/// site. Free has no mark at all: a badge that everyone has is decoration, and
/// the profile page shows nothing there either.
///
/// Used where the name is large enough to carry a glyph beside it. The sidebar
/// footer keeps the written pill, because a crown alone in the corner of a
/// window is a puzzle rather than a badge.
struct TierMark: View {
    var tier: String
    var size: CGFloat = 15

    private var symbol: String? {
        switch tier.lowercased() {
        case "patron": return "crown.fill"
        case "supporter": return "star.fill"
        case "free", "": return nil
        // An unknown tier still gets a mark rather than disappearing: a new
        // tier on the server should not make an account look downgraded.
        default: return "seal.fill"
        }
    }

    var body: some View {
        if let symbol {
            Image(systemName: symbol)
                .font(.system(size: size))
                .foregroundStyle(Theme.accent)
                .help("\(tier.capitalized) tier")
                .accessibilityLabel("\(tier.capitalized) tier")
        }
    }
}
