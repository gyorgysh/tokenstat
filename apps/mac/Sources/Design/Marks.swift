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
                    .font(Theme.fixed(size * 0.46, weight: .semibold))
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

/// Identity card shown while the pointer is on an author mark.
///
/// A row-level `.help` steals the tooltip from the mark inside it, so History
/// (and any other list of people) needs its own overlay. The picture is the
/// one the row already resolved, including a teammate's public forge picture.
/// Someone with no picture stays a letter. The card does not fetch.
struct AuthorHoverCard: View {
    var url: String?
    var name: String
    var email: String?
    var mine: Bool = false
    var tint: Color = Theme.accent

    var body: some View {
        HStack(alignment: .center, spacing: Theme.Space.s) {
            Avatar(url: url, name: name, handle: name, size: 36, tint: tint)
            VStack(alignment: .leading, spacing: 2) {
                Text(name)
                    .font(Theme.font(13, weight: .semibold))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                if let email, !email.isEmpty {
                    Text(email)
                        .font(Theme.mono(11))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                if mine {
                    Text(L10n.text("apple.marks.you.08b04193"))
                        .font(Theme.font(11, weight: .medium))
                        .foregroundStyle(Theme.accent)
                }
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(Theme.panel, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(Theme.border)
        )
        .shadow(color: .black.opacity(0.18), radius: 10, y: 4)
        .fixedSize()
        .accessibilityHidden(true)
    }
}

/// Shows `AuthorHoverCard` after a short dwell on `content`.
///
/// The delay is so scrolling a commit list does not flash a card on every row
/// the pointer crosses. The popover is what escapes a `ScrollView` clip.
private struct AuthorHover: ViewModifier {
    var url: String?
    var name: String
    var email: String?
    var mine: Bool
    var tint: Color

    @State private var hovering = false
    @State private var visible = false
    @State private var generation = 0

    func body(content: Content) -> some View {
        content
            .onHover { on in
                hovering = on
                generation += 1
                let token = generation
                if on {
                    Task { @MainActor in
                        try? await Task.sleep(for: .milliseconds(350))
                        guard token == generation, hovering else { return }
                        visible = true
                    }
                } else {
                    visible = false
                }
            }
            .popover(isPresented: $visible, arrowEdge: .top) {
                AuthorHoverCard(
                    url: url,
                    name: name,
                    email: email,
                    mine: mine,
                    tint: tint
                )
                .padding(4)
            }
    }
}

extension View {
    /// Dwell-hover identity card for a commit author mark.
    func authorHoverCard(
        url: String?,
        name: String,
        email: String?,
        mine: Bool,
        tint: Color
    ) -> some View {
        modifier(AuthorHover(url: url, name: name, email: email, mine: mine, tint: tint))
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
    /// A repeating pulse for a screen that stays while it waits (the launch
    /// splash), or one rise that lands and holds (an intro page).
    var loops: Bool = true

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @State private var raised = false
    /// One run of the same rise, for a refresh somebody pulled. Not the
    /// repeating launch animation: a spinner already says "working", and the
    /// mark's job here is only to acknowledge the pull.
    @State private var pulse = false

    var body: some View {
        // One scale factor from the artboard, so every number above is the
        // website's own and none of them are re-derived by hand.
        let unit = size / TokenstatLogoGeometry.inkSide

        ZStack(alignment: .topLeading) {
            // Offsets do not participate in layout, so without this the ZStack
            // sizes to a single bar (12 units wide) and `.frame(width:size)`
            // centres that box, sliding every bar 15 units to the right of the
            // frame's centre. A full-size clear child sets the layout box to
            // the whole frame so the offsets below land on the real origin.
            Color.clear
                .frame(width: size, height: size)
                .allowsHitTesting(false)
            ForEach(Array(TokenstatLogoGeometry.bars.enumerated()), id: \.offset) { index, bar in
                RoundedRectangle(cornerRadius: TokenstatLogoGeometry.cornerRadius * unit)
                    .fill(bar.color)
                    .frame(width: bar.rect.width * unit, height: bar.rect.height * unit)
                    // Anchored at the foot, so a bar grows out of the baseline
                    // it shares with the other two rather than shrinking in
                    // place. Each starts a beat after the one before it.
                    .scaleEffect(
                        y: !reduceMotion && ((animated && !raised) || pulse) ? 0.35 : 1,
                        anchor: .bottom
                    )
                    .animation(
                        animated && !reduceMotion
                            ? (loops
                                ? .easeInOut(duration: 0.62)
                                    .repeatForever(autoreverses: true)
                                    .delay(Double(index) * 0.14)
                                : .easeInOut(duration: 1.2)
                                    .delay(Double(index) * 0.15))
                            : nil,
                        value: raised
                    )
                    .animation(
                        reduceMotion ? nil : .easeInOut(duration: 0.26).delay(Double(index) * 0.07),
                        value: pulse
                    )
                    .offset(
                        x: bar.rect.minX * unit,
                        y: bar.rect.minY * unit
                    )
            }
        }
        .frame(width: size, height: size)
        .accessibilityLabel(L10n.text("apple.marks.tokenstat.63d30539"))
        .onAppear { if animated { raised = true } }
        // A refresh somebody asked for dips the bars and lets them back up,
        // once. The mark sits in the sidebar on the Mac and in the top bar
        // on the phone, so it is the one place both apps can acknowledge
        // the same gesture.
        .onReceive(NotificationCenter.default.publisher(for: .clientRefreshing)) { _ in
            guard !reduceMotion, !animated, !pulse else { return }
            pulse = true
            Task {
                try? await Task.sleep(for: .milliseconds(300))
                pulse = false
            }
        }
    }
}

/// Posts the pulse the wordmark listens for. iOS pull-to-refresh and Mac
/// toolbar refresh / scan / sync all go through here so the bars move the
/// same way on both platforms.
enum LogoRefresh {
    static func began() {
        NotificationCenter.default.post(name: .clientRefreshing, object: nil)
    }
}

extension Notification.Name {
    /// A screen started a refresh the wordmark should acknowledge.
    static let clientRefreshing = Notification.Name("ai.tokenstat.client.refreshing")
}

/// The mark and the name, for the top of the sidebar.
struct Wordmark: View {
    /// Mark height. The text scales with it, so one number sizes the lockup.
    ///
    /// 17 on the Mac, where this sits at the top of a sidebar full of rows and
    /// must not shout over them. The phone passes something larger: it has one
    /// bar, one brand in it, and room to spend, and at sidebar size the mark
    /// read as a caption rather than as the name of the app.
    var size: CGFloat = 17
    /// Take the leading edge and push everything else right, which is what a
    /// sidebar header wants and a centred toolbar item does not.
    var fills = true
    /// Draw the bars as well as the name. A lockup that already placed the
    /// mark above the letters wants the word only, or the bars appear twice.
    var showsMark = true

    var body: some View {
        // `.firstTextBaseline` would sit the mark on the text's baseline, which
        // drops a square glyph below the descender line. Centring on the text's
        // cap height is what actually looks aligned, and that is what a centred
        // stack gives once the mark's frame is its ink.
        // The website leaves a deliberate breath between the bars and the
        // wordmark. A half-mark gap made the phone lockup look compressed.
        HStack(alignment: .center, spacing: size * 0.75) {
            if showsMark {
                LogoMark(size: size)
            }
            HStack(spacing: 0) {
                Text(L10n.text("apple.marks.token.3c469e9d"))
                    .foregroundStyle(.primary)
                Text(L10n.text("apple.marks.stat.40460da8"))
                    .foregroundStyle(Theme.accent)
            }
            .font(Theme.fixed(size * 0.88, weight: .bold))
            // Lowercase, always. It is the command you type.
            .textCase(.lowercase)
            if fills {
                Spacer()
            }
        }
    }
}

/// The tier, as the silhouette the website puts beside a name.
///
/// The paths are the site's own (`BADGE_PATH` in `Profile.jsx`): a crest shield
/// for Patron, a star for Supporter, a crown for Legend. SF Symbols was the
/// first attempt and it is the wrong call for a badge. `crown.fill` is Apple's crown,
/// not this brand's, and a mark that is nearly the website's is worse than one
/// that is obviously different, because it reads as the same badge rendered badly.
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
                .help(L10n.text("apple.marks.0_tier.c75a2e12", "\(PlanName.title(tier))"))
                .accessibilityLabel(L10n.text("apple.marks.0_tier.c75a2e12", "\(PlanName.title(tier))"))
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
        case badge
        /// A tier this build does not know. A new tier on the server must not
        /// make an account look downgraded, so it still gets a mark.
        case seal
    }

    let kind: Kind

    init?(tier: String) {
        switch tier.lowercased() {
        case "legend": kind = .crown
        case "patron": kind = .badge
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
        case .badge:
            // Crest shield with a chevron cut out of it, same path as
            // Profile.jsx BADGE_PATH.patron. The cut is wound against the
            // shield, so it stays open under either fill rule, and at 12px it
            // closes up and leaves a plain shield rather than mush.
            path.move(to: point(12, 2.1))
            path.addLine(to: point(20.4, 4.9))
            path.addLine(to: point(20.4, 11))
            path.addCurve(to: point(12, 21.9), control1: point(20.4, 16.1), control2: point(16.8, 20.2))
            path.addCurve(to: point(3.6, 11), control1: point(7.2, 20.2), control2: point(3.6, 16.1))
            path.addLine(to: point(3.6, 4.9))
            path.closeSubpath()

            path.move(to: point(7.9, 9.2))
            path.addLine(to: point(7.9, 11.9))
            path.addLine(to: point(12, 16))
            path.addLine(to: point(16.1, 11.9))
            path.addLine(to: point(16.1, 9.2))
            path.addLine(to: point(12, 13.3))
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
