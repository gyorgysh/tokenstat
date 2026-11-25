// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
import SwiftUI

/// The top of the profile window: the person and the address, over the grid
/// the product draws days on. The grid lights when the page is public.
struct ProfilePlate: View {
    let avatar: String?
    let name: String
    let handle: String?
    /// The address as it stands, or as it is being typed.
    let address: String
    /// Nothing has been chosen yet, so the address is an example.
    let isExample: Bool
    let isPublic: Bool
    /// Nil while the address is only a draft: a link to nowhere is not worth
    /// copying.
    let copy: (() -> Void)?
    let copied: Bool

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(spacing: Theme.Space.m) {
            Avatar(url: avatar, name: name, handle: handle, size: 84)
                .overlay(Circle().strokeBorder(Theme.background, lineWidth: 3))
                .shadow(color: .black.opacity(0.12), radius: 10, y: 4)
                .accessibilityHidden(true)
            VStack(spacing: Theme.Space.s) {
                Text(name)
                    .font(Theme.font(22, weight: .semibold, relativeTo: .title2))
                    .lineLimit(1)
                    .truncationMode(.tail)
                addressPill
            }
        }
        .padding(.top, 44)
        .padding(.bottom, Theme.Space.l)
        .padding(.horizontal, Theme.Space.l)
        .frame(maxWidth: .infinity)
        .background(alignment: .top) { grid }
        .animation(Motion.unless(reduceMotion, Motion.morph), value: isPublic)
    }

    @ViewBuilder
    private var addressPill: some View {
        if let copy {
            Button(action: copy) {
                HStack(spacing: 8) {
                    addressText
                    Image(systemName: (copied ? ActionIcon.done : ActionIcon.copy).symbol)
                        .font(Theme.font(11, weight: .medium))
                        .foregroundStyle(copied ? Theme.diffAdded : Theme.controlGlyph)
                        .contentTransition(.symbolEffect(.replace))
                }
                .modifier(PillSurface())
            }
            .buttonStyle(PlateButtonStyle())
            .help(L10n.text("common.copy"))
            .accessibilityLabel(L10n.text("common.profile.copy_address", address))
        } else {
            addressText.modifier(PillSurface())
        }
    }

    private var addressText: some View {
        Text(address)
            .font(Theme.monoText(13, relativeTo: .footnote))
            .foregroundStyle(isExample ? AnyShapeStyle(.tertiary) : AnyShapeStyle(.primary))
            .lineLimit(1)
            .truncationMode(.middle)
    }

    /// The day grid, as texture. Every cell is the same colour and only fades
    /// with distance, so it never reads as somebody's activity.
    private var grid: some View {
        ZStack {
            LinearGradient(colors: [Theme.accentSoft, Theme.accentSoft.opacity(0)],
                           startPoint: .top, endPoint: .bottom)
            cells(Theme.controlGlyph.opacity(0.22)).opacity(isPublic ? 0 : 1)
            cells(Theme.accent.opacity(0.4)).opacity(isPublic ? 1 : 0)
        }
        .accessibilityHidden(true)
    }

    private func cells(_ color: Color) -> some View {
        Canvas { context, size in
            let step: CGFloat = 15, side: CGFloat = 11
            let center = CGPoint(x: size.width / 2, y: size.height * 0.36)
            let reach = max(size.width * 0.62, 1)
            let columns = Int(size.width / step) + 1, rows = Int(size.height / step) + 1
            let inset = (size.width - CGFloat(columns) * step + (step - side)) / 2
            for column in 0..<columns {
                for row in 0..<rows {
                    let x = inset + CGFloat(column) * step, y = CGFloat(row) * step
                    // Below the picture it fades faster, so the name and the
                    // address sit on a plain ground.
                    let drop = y - center.y
                    let distance = hypot(x - center.x, drop * (drop > 0 ? 2.6 : 1.3))
                    let fade = pow(max(0, 1 - distance / reach), 1.5)
                    guard fade > 0.02 else { continue }
                    context.opacity = fade
                    context.fill(Path(roundedRect: CGRect(x: x, y: y, width: side, height: side), cornerRadius: 3),
                                 with: .color(color))
                }
            }
        }
    }
}

private struct PillSurface: ViewModifier {
    func body(content: Content) -> some View {
        content
            .padding(.horizontal, 12)
            .frame(minHeight: 30)
            .background(Theme.panel, in: Capsule())
            .overlay(Capsule().strokeBorder(Theme.border, lineWidth: 1))
            .contentShape(Capsule())
    }
}

private struct PlateButtonStyle: ButtonStyle {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed && !reduceMotion ? 0.97 : 1)
            .opacity(configuration.isPressed ? 0.8 : 1)
            .animation(Motion.unless(reduceMotion, Motion.press), value: configuration.isPressed)
    }
}
