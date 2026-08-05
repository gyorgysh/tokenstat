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

/// A product-owned vector mark for a feature surface.
struct FeatureMark: View {
    var name: String
    var tint: Color = Theme.accent
    var size: CGFloat = 18

    var body: some View {
        Image(name)
            .renderable(size: size * 0.62)
            .foregroundStyle(tint)
            .frame(width: size, height: size)
            .background(tint.opacity(0.12), in: RoundedRectangle(cornerRadius: size * 0.28))
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
/// wide on a 15 pitch, sharing a baseline, drawn in a 64 unit artboard. **They
/// share a baseline on purpose**, which is what makes them read as a chart
/// instead of three floating shapes. The colours are the dark-context ramp the
/// favicon badge uses, since this sits on the app's own dark chrome. Change
/// these with the website, not on their own.
///
/// The view's frame is the *ink*, not the artboard. The artwork occupies
/// x 11...53 and y 10...52 of that 64 unit square, so using the artboard as the
/// frame padded the mark with a fifth of its own height in empty space and left
/// it sitting visibly high next to any text beside it.
struct LogoMark: View {
    var size: CGFloat = 18
    /// Draw the bars rising in turn, for a screen that is waiting on something.
    ///
    /// The mark's own bars and the mark's own colours, moving the only way a
    /// bar chart can move. Anything else on a launch screen is a second logo
    /// nobody chose.
    var animated: Bool = false

    @State private var raised = false

    /// Ink bounds inside the 64 unit artboard.
    private static let inkOrigin = CGPoint(x: 11, y: 10)
    private static let inkSide: CGFloat = 42

    private static let bars: [(y: CGFloat, height: CGFloat, color: Color)] = [
        (34, 18, Color(red: 0xC3 / 255, green: 0xB0 / 255, blue: 0xFF / 255)),
        (22, 30, Color(red: 0x8B / 255, green: 0x5C / 255, blue: 0xF6 / 255)),
        (10, 42, Color(red: 0xE8 / 255, green: 0x79 / 255, blue: 0xF9 / 255)),
    ]

    var body: some View {
        // One scale factor from the artboard, so every number above is the
        // website's own and none of them are re-derived by hand.
        let unit = size / Self.inkSide

        ZStack(alignment: .topLeading) {
            ForEach(Array(Self.bars.enumerated()), id: \.offset) { index, bar in
                RoundedRectangle(cornerRadius: 3.5 * unit)
                    .fill(bar.color)
                    .frame(width: 12 * unit, height: bar.height * unit)
                    // Anchored at the foot, so a bar grows out of the baseline
                    // it shares with the other two rather than shrinking in
                    // place. Each starts a beat after the one before it.
                    .scaleEffect(y: animated && !raised ? 0.35 : 1, anchor: .bottom)
                    .animation(
                        animated
                            ? .easeInOut(duration: 0.62)
                                .repeatForever(autoreverses: true)
                                .delay(Double(index) * 0.14)
                            : nil,
                        value: raised
                    )
                    .offset(
                        x: (11 + CGFloat(index) * 15 - Self.inkOrigin.x) * unit,
                        y: (bar.y - Self.inkOrigin.y) * unit
                    )
            }
        }
        .frame(width: size, height: size)
        .accessibilityLabel("tokenstat")
        .onAppear { if animated { raised = true } }
    }
}

/// The mark and the name, for the top of the sidebar.
struct Wordmark: View {
    var body: some View {
        // `.firstTextBaseline` would sit the mark on the text's baseline, which
        // drops a square glyph below the descender line. Centring on the text's
        // cap height is what actually looks aligned, and that is what a centred
        // stack gives once the mark's frame is its ink.
        HStack(alignment: .center, spacing: Theme.Space.s) {
            LogoMark(size: 17)
            Text("tokenstat")
                .font(.system(size: 15, weight: .semibold))
                // Lowercase, always. It is the command you type.
                .textCase(.lowercase)
            Spacer()
        }
    }
}

/// The tier, as the silhouette the website puts beside a name.
///
/// The paths are the site's own (`BADGE_PATH` in `Profile.jsx`): a crown for
/// Patron, a star for Supporter. SF Symbols was the first attempt and it is the
/// wrong call for a badge. `crown.fill` is Apple's crown, not this brand's, and
/// a mark that is nearly the website's is worse than one that is obviously
/// different, because it reads as the same badge rendered badly.
///
/// Free has no mark at all. A badge everyone holds is decoration, and the
/// profile page shows nothing there either.
///
/// Used where the name is large enough to carry a glyph beside it. The sidebar
/// footer keeps the written pill, because a crown alone in the corner of a
/// window is a puzzle rather than a badge.
struct TierMark: View {
    var tier: String
    var size: CGFloat = 15

    var body: some View {
        if let shape = BadgeShape(tier: tier) {
            shape
                .fill(
                    LinearGradient(
                        // The logo's own two strongest bars, so a badge beside
                        // a name belongs to the same brand as the mark in the
                        // corner.
                        colors: [
                            Color(red: 0x8B / 255, green: 0x5C / 255, blue: 0xF6 / 255),
                            Color(red: 0xC0 / 255, green: 0x26 / 255, blue: 0xD3 / 255),
                        ],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                )
                .frame(width: size, height: size)
                .help("\(tier.capitalized) tier")
                .accessibilityLabel("\(tier.capitalized) tier")
        }
    }
}

/// The badge silhouettes, in the website's 24 unit square.
///
/// Transcribed from the SVG rather than approximated, so the two stay the same
/// shape. Points are absolute here; the source mixes absolute and relative
/// commands and the conversion is done once, here, instead of at every reader.
struct BadgeShape: Shape {
    enum Kind {
        case crown
        case star
        /// A tier this build does not know. A new tier on the server must not
        /// make an account look downgraded, so it still gets a mark.
        case seal
    }

    let kind: Kind

    init?(tier: String) {
        switch tier.lowercased() {
        case "patron": kind = .crown
        case "supporter": kind = .star
        case "free", "": return nil
        default: kind = .seal
        }
    }

    init(kind: Kind) {
        self.kind = kind
    }

    func path(in rect: CGRect) -> Path {
        let unit = min(rect.width, rect.height) / 24
        func point(_ x: CGFloat, _ y: CGFloat) -> CGPoint {
            CGPoint(x: rect.minX + x * unit, y: rect.minY + y * unit)
        }

        var path = Path()
        switch kind {
        case .crown:
            // The band, and the bar under it, as two closed subpaths.
            path.move(to: point(3, 7.4))
            path.addLine(to: point(7.6, 10.6))
            path.addLine(to: point(12, 3.4))
            path.addLine(to: point(16.4, 10.6))
            path.addLine(to: point(21, 7.4))
            path.addLine(to: point(19.3, 18.6))
            path.addLine(to: point(4.7, 18.6))
            path.closeSubpath()

            path.addRect(
                CGRect(
                    origin: point(4.7, 20.1),
                    size: CGSize(width: 14.6 * unit, height: 1.9 * unit)
                )
            )
        case .star:
            path.move(to: point(12, 2.6))
            path.addLine(to: point(14.7, 8.5))
            path.addLine(to: point(21, 9.2))
            path.addLine(to: point(16.3, 13.5))
            path.addLine(to: point(17.6, 19.8))
            path.addLine(to: point(12, 16.7))
            path.addLine(to: point(6.4, 19.8))
            path.addLine(to: point(7.7, 13.5))
            path.addLine(to: point(3, 9.2))
            path.addLine(to: point(9.3, 8.5))
            path.closeSubpath()
        case .seal:
            path.addEllipse(
                in: CGRect(
                    origin: point(4, 4),
                    size: CGSize(width: 16 * unit, height: 16 * unit)
                )
            )
        }
        return path
    }
}

/// An opaque identifier, readable at the start and blurred after it.
///
/// A machine id is 18 characters of hex that nobody reads and everybody has to
/// look past. Truncating it would move the layout on hover; blurring the tail
/// keeps the row exactly as wide as it was and still says "there is more here".
///
/// The full value stays selectable, so copying it does not depend on hovering
/// first.
struct MaskedID: View {
    let value: String
    /// Characters left legible. Enough to tell two ids apart at a glance.
    var visible: Int = 8
    var size: CGFloat = 11

    @State private var isRevealed = false

    private var head: String { String(value.prefix(visible)) }
    private var tail: String { String(value.dropFirst(visible)) }

    var body: some View {
        HStack(spacing: 0) {
            Text(head)
            Text(tail)
                .blur(radius: isRevealed ? 0 : 3)
                .opacity(isRevealed ? 1 : 0.6)
        }
        .font(Theme.mono(size))
        .textSelection(.enabled)
        .animation(.easeOut(duration: 0.12), value: isRevealed)
        .onHover { isRevealed = $0 }
        .help(value)
    }
}
