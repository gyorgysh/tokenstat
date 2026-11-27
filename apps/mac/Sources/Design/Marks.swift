// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
//
// Source-available: source sharing and own builds are permitted.
// Store and commercial distribution of builds is reserved. See LICENSE.
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
    func renderable(size: CGFloat) -> some View {
        self
            .renderingMode(.template)
            .resizable()
            .scaledToFit()
            .frame(width: size, height: size)
    }
}

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


struct LogoMark: View {
    var size: CGFloat = 18
    private static let monochromeOpacity: [Double] = [0.4, 0.68, 1]
    var animated: Bool = false
    var loops: Bool = true

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @State private var raised = false
    @State private var pulse = false

    var body: some View {
        if animated, loops, !reduceMotion {
            TimelineView(.animation) { clock in
                mark { Self.loopScale(bar: $0, at: clock.date) }
            }
        } else {
            mark { _ in animated && !raised && !reduceMotion ? 0.35 : 1 }
        }
    }

    private static func loopScale(bar: Int, at date: Date) -> CGFloat {
        let time = date.timeIntervalSinceReferenceDate - Double(bar) * 0.14
        let cycle = (time / 0.62).truncatingRemainder(dividingBy: 2)
        return 0.35 + 0.65 * (0.5 - 0.5 * cos(cycle * .pi))
    }

    private func mark(scale: @escaping (Int) -> CGFloat) -> some View {
        let unit = size / TokenstatLogoGeometry.inkSide

        return ZStack(alignment: .topLeading) {
            Color.clear
                .frame(width: size, height: size)
                .allowsHitTesting(false)
            ForEach(Array(TokenstatLogoGeometry.bars.enumerated()), id: \.offset) { index, bar in
                RoundedRectangle(cornerRadius: TokenstatLogoGeometry.cornerRadius * unit)
                    .fill(Theme.showsBrandColours
                          ? AnyShapeStyle(bar.color)
                          : AnyShapeStyle(Color.primary.opacity(Self.monochromeOpacity[index])))
                    .frame(width: bar.rect.width * unit, height: bar.rect.height * unit)
                    .animation(
                        animated && !loops && !reduceMotion
                            ? .easeInOut(duration: 1.2).delay(Double(index) * 0.15) : nil
                    ) { $0.scaleEffect(y: scale(index), anchor: .bottom) }
                    .scaleEffect(y: !reduceMotion && pulse ? 0.35 : 1, anchor: .bottom)
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
    static let clientRefreshing = Notification.Name("ai.tokenstat.client.refreshing")
}

struct Wordmark: View {
    var size: CGFloat = 17
    var fills = true
    var showsMark = true

    var body: some View {
        HStack(alignment: .center, spacing: size * 0.75) {
            if showsMark {
                LogoMark(size: size)
            }
            HStack(spacing: 0) {
                Text(L10n.text("apple.marks.token.3c469e9d"))
                    .foregroundStyle(.primary)
                Text(L10n.text("apple.marks.stat.40460da8"))
                    .foregroundStyle(Theme.showsBrandColours ? AnyShapeStyle(Theme.brandAccent)
                                                             : AnyShapeStyle(.secondary))
            }
            .font(Theme.fixed(size * 0.88, weight: .bold))
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
                        colors: [Theme.accent, Theme.secondary],
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

struct BadgeShape: Shape {
    enum Kind {
        case crown
        case star
        case badge
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
