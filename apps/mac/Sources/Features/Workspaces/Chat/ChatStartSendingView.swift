// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
import SwiftUI

/// While the first message prepares, the grid's light runs into the brand
/// mark and its three bars fill and settle in turn, like a level meter
/// counting what arrives.
struct ChatStartSendingView: View {
    let startedAt: Double
    let active: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.accessibilityDimFlashingLights) private var dimFlashingLights
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    var body: some View {
        GeometryReader { pane in
            // The field shader uses this same focus, so the waves arrive here.
            let focus = CGPoint(x: pane.size.width * 0.5, y: pane.size.height * 0.46)
            TimelineView(.animation(minimumInterval: 1 / 45, paused: !active || reduceMotion || dimFlashingLights)) { frame in
                ChatStartMeter(elapsed: max(0, frame.date.timeIntervalSinceReferenceDate - startedAt),
                               still: reduceMotion || dimFlashingLights, opaque: reduceTransparency)
            }
            .frame(width: min(600, pane.size.width), height: 180)
            .position(focus)
            .accessibilityHidden(true)
            Text(L10n.text("common.new_chat.preparing"))
                .font(Theme.font(14, weight: .medium))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(width: max(1, pane.size.width - 48))
                .position(x: focus.x, y: focus.y + 76)
        }
        .accessibilityElement(children: .combine)
        .allowsHitTesting(false)
    }
}

/// The logo as three glass bars with a fill rising and falling in each, one
/// after the other. Still, it shows the mark full, which is the brand.
struct ChatStartMeter: View {
    let elapsed: Double
    /// Reduce Motion: the mark is shown full and does not move.
    var still = false
    var opaque = false
    @Environment(\.colorScheme) private var colorScheme

    /// Seconds for one rise and fall, and how far behind each bar runs.
    private static let period = 1.5
    private static let stagger = 0.16

    var body: some View {
        Canvas { context, size in
            let t = max(0, elapsed)
            let arrival = still ? 1 : 1 - exp(-t * 6)
            let scale = 1.7 + arrival * 0.15
            let side = TokenstatLogoGeometry.inkSide * scale
            let origin = CGPoint(x: size.width * 0.5 - side * 0.5, y: size.height * 0.5 - side * 0.5 - 12)
            let dark = colorScheme == .dark
            let radius = TokenstatLogoGeometry.cornerRadius * scale

            // One soft pool of light under the mark, not a glow per bar.
            if !opaque {
                var pool = context
                pool.addFilter(.blur(radius: 26))
                let floor = CGRect(x: origin.x - 6, y: origin.y + side * 0.55, width: side + 12, height: side * 0.5)
                pool.fill(Ellipse().path(in: floor), with: .color(Theme.accent.opacity((dark ? 0.30 : 0.16) * arrival)))
            }

            for (index, bar) in TokenstatLogoGeometry.bars.enumerated() {
                let rect = CGRect(x: origin.x + bar.rect.minX * scale, y: origin.y + bar.rect.minY * scale,
                                  width: bar.rect.width * scale, height: bar.rect.height * scale)
                let face = RoundedRectangle(cornerRadius: radius, style: .continuous).path(in: rect)

                // The empty glass.
                context.fill(face, with: .color(bar.color.opacity(dark ? 0.10 : 0.14)))
                context.stroke(face, with: .color(bar.color.opacity(dark ? 0.45 : 0.55)), lineWidth: 0.8)

                // The level, eased so it lingers at the top and the bottom.
                let phase = (t / Self.period - Double(index) * Self.stagger) * 2 * .pi
                let wave = 0.5 - 0.5 * cos(phase)
                let level = still ? 1 : 0.28 + 0.72 * wave
                let height = rect.height * level * arrival
                let fill = CGRect(x: rect.minX, y: rect.maxY - height, width: rect.width, height: height)
                var clipped = context
                clipped.clip(to: face)
                clipped.fill(Path(fill), with: .linearGradient(
                    Gradient(colors: [bar.color.opacity(0.95), bar.color.opacity(0.70)]),
                    startPoint: CGPoint(x: fill.midX, y: fill.minY), endPoint: CGPoint(x: fill.midX, y: fill.maxY)))
                // A fine bright meniscus on top of the level.
                if height > 1 {
                    clipped.fill(Path(CGRect(x: fill.minX, y: fill.minY, width: fill.width, height: 1)),
                                 with: .color(.white.opacity(dark ? 0.55 : 0.70)))
                }
            }
        }
    }
}
