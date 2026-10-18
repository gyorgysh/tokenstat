// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
import SwiftUI

/// The page's interactive field gathers into the brand mark. Its three
/// glass bars split that light while the first message prepares.
struct ChatStartSendingView: View {
    let startedAt: Double
    let active: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.accessibilityDimFlashingLights) private var dimFlashingLights
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    var body: some View {
        GeometryReader { pane in
            // The field shader uses this same focus. The light enters below
            // the logo's centre, where it passes through all three bars.
            let focus = CGPoint(x: pane.size.width * 0.5, y: pane.size.height * 0.46)
            TimelineView(.animation(minimumInterval: 1 / 45, paused: !active || reduceMotion || dimFlashingLights)) { frame in
                ChatStartPrism(elapsed: reduceMotion || dimFlashingLights ? 0.8
                    : max(0, frame.date.timeIntervalSinceReferenceDate - startedAt), opaque: reduceTransparency)
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

struct ChatStartPrism: View {
    let elapsed: Double
    var opaque = false
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        Canvas { context, size in
            let formed = 1 - exp(-max(0, elapsed) * 5)
            let arrival = min(1, max(0, elapsed) / 0.45)
            let dispersion = min(1, max(0, elapsed - 0.28) / 0.48)
            let scale = 1.86 + formed * 0.14
            let side = TokenstatLogoGeometry.inkSide * scale
            let focus = CGPoint(x: size.width * 0.5, y: size.height * 0.5)
            let origin = CGPoint(x: focus.x - side * 0.5, y: focus.y - side * 0.5 - 12)
            let dark = colorScheme == .dark
            let glint = dark ? Color.white : Theme.accent
            let outlet = CGPoint(x: origin.x + side, y: focus.y)
            let spectrum: [Color] = [Color(red: 0.53, green: 0.39, blue: 1),
                Color(red: 0.43, green: 0.56, blue: 1), Color(red: 0.35, green: 0.78, blue: 0.94),
                Color(red: 0.54, green: 0.84, blue: 0.79), Color(red: 0.96, green: 0.77, blue: 0.65),
                Color(red: 0.95, green: 0.52, blue: 0.72)]

            // The outgoing fan starts at the last bar; the incoming light is
            // the full-page field behind this view, rather than another beam.
            for (index, colour) in spectrum.enumerated() {
                let spread = Double(index) - 2.5
                let end = CGPoint(x: size.width - 12, y: focus.y + spread * (13 + formed * 6))
                let ray = Path { path in
                    path.move(to: outlet)
                    path.addQuadCurve(to: end, control: CGPoint(x: outlet.x + 64, y: outlet.y + spread * 5))
                }.trimmedPath(from: 0, to: dispersion)
                let ink = GraphicsContext.Shading.linearGradient(
                    Gradient(colors: [colour.opacity(dark ? 0.80 : 0.70), colour.opacity(0)]),
                    startPoint: outlet, endPoint: end)
                if !opaque {
                    var glow = context
                    glow.addFilter(.blur(radius: 4))
                    glow.stroke(ray, with: ink, lineWidth: 5)
                }
                context.stroke(ray, with: ink, lineWidth: opaque ? 1.8 : 1.2)
            }

            for (index, bar) in TokenstatLogoGeometry.bars.enumerated() {
                let rect = CGRect(x: origin.x + bar.rect.minX * scale, y: origin.y + bar.rect.minY * scale,
                                  width: bar.rect.width * scale, height: bar.rect.height * scale)
                let radius = TokenstatLogoGeometry.cornerRadius * scale
                let face = RoundedRectangle(cornerRadius: radius).path(in: rect)
                if !opaque {
                    var glow = context
                    glow.addFilter(.blur(radius: 12))
                    glow.fill(face, with: .color(bar.color.opacity(dark ? 0.22 : 0.10)))
                }
                context.fill(face, with: .linearGradient(
                    Gradient(colors: [bar.color.opacity(opaque ? 0.95 : 0.60), bar.color.opacity(opaque ? 0.85 : 0.22)]),
                    startPoint: CGPoint(x: rect.minX, y: rect.minY), endPoint: CGPoint(x: rect.maxX, y: rect.maxY)))
                context.stroke(face, with: .linearGradient(
                    Gradient(colors: [glint.opacity(dark ? 0.65 : 0.38), bar.color.opacity(0.75)]),
                    startPoint: CGPoint(x: rect.minX, y: rect.minY), endPoint: CGPoint(x: rect.maxX, y: rect.maxY)), lineWidth: 0.8)
                // A bevel catches and changes the light at each real bar.
                let crossing = Path { path in
                    path.move(to: CGPoint(x: rect.minX, y: focus.y))
                    path.addLine(to: CGPoint(x: rect.midX, y: focus.y - Double(index) * 1.8))
                    path.addLine(to: CGPoint(x: rect.maxX, y: focus.y))
                }.trimmedPath(from: 0, to: arrival)
                context.stroke(crossing, with: .linearGradient(
                    Gradient(colors: [glint.opacity(0.85), spectrum[index * 2].opacity(0.80)]),
                    startPoint: CGPoint(x: rect.minX, y: focus.y), endPoint: CGPoint(x: rect.maxX, y: focus.y)), lineWidth: 1.3)
                let bevel = Path { path in
                    path.move(to: CGPoint(x: rect.minX + 4, y: rect.minY + radius))
                    path.addLine(to: CGPoint(x: rect.minX + 4, y: rect.maxY - radius))
                }
                context.stroke(bevel, with: .color(glint.opacity(0.14)), lineWidth: 0.7)
            }
        }
    }
}
