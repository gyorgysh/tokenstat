// SPDX-License-Identifier: LicenseRef-tokenstat-source-available

import SwiftUI

enum Motion {
    static let hover: Animation = .easeOut(duration: 0.16)
    static let press: Animation = .spring(response: 0.22, dampingFraction: 0.68)
    static let morph: Animation = .spring(response: 0.32, dampingFraction: 0.8)

    static func unless(_ reduce: Bool, _ animation: Animation) -> Animation? {
        reduce ? nil : animation
    }
}

private struct RowHoveredKey: EnvironmentKey {
    static let defaultValue = false
}

extension EnvironmentValues {
    var rowHovered: Bool {
        get { self[RowHoveredKey.self] }
        set { self[RowHoveredKey.self] = newValue }
    }
}

struct RowFeedbackStyle: ButtonStyle {
    var bleed: CGFloat = Theme.Space.s
    var radius: CGFloat = 10

    func makeBody(configuration: Configuration) -> some View {
        RowFeedback(configuration: configuration, bleed: bleed, radius: radius)
    }

    private struct RowFeedback: View {
        let configuration: Configuration
        let bleed: CGFloat
        let radius: CGFloat
        @Environment(\.isEnabled) private var isEnabled
        @Environment(\.accessibilityReduceMotion) private var reduceMotion
        @State private var hovering = false

        private var active: Bool { isEnabled && (hovering || configuration.isPressed) }

        var body: some View {
            configuration.label
                .environment(\.rowHovered, isEnabled && hovering)
                .padding(.horizontal, bleed)
                .background {
                    RoundedRectangle(cornerRadius: radius, style: .continuous)
                        .fill(Theme.rowHighlight)
                        .opacity(active ? 1 : 0)
                        .scaleEffect(active ? 1 : 0.96)
                        .animation(Motion.unless(reduceMotion, Motion.morph), value: active)
                }
                .contentShape(RoundedRectangle(cornerRadius: radius, style: .continuous))
                .padding(.horizontal, -bleed)
                .scaleEffect(isEnabled && configuration.isPressed && !reduceMotion ? 0.985 : 1)
                .animation(Motion.unless(reduceMotion, Motion.press), value: configuration.isPressed)
                .opacity(isEnabled ? 1 : 0.55)
                .onHover { hovering = $0 }
        }
    }
}

struct RowChevron: View {
    var symbol: String = ActionIcon.next.symbol
    @Environment(\.rowHovered) private var hovered
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Image(systemName: symbol)
            .foregroundStyle(Theme.accent)
            .opacity(hovered ? 1 : 0.5)
            .offset(x: hovered && !reduceMotion ? 3 : 0)
            .animation(Motion.unless(reduceMotion, Motion.morph), value: hovered)
            .accessibilityHidden(true)
    }
}

struct CapsuleFeedback: ViewModifier {
    let isPressed: Bool
    let radius: CGFloat
    let tint: Color
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var hovering = false

    func body(content: Content) -> some View {
        let lit = isEnabled && hovering
        content
            .overlay {
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .fill(tint.opacity(lit ? (isPressed ? 0.1 : 0.06) : 0))
                    .allowsHitTesting(false)
            }
            .overlay {
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .strokeBorder(tint.opacity(lit ? 0.32 : 0), lineWidth: 1)
                    .allowsHitTesting(false)
            }
            .scaleEffect(isEnabled && isPressed && !reduceMotion ? 0.96 : 1)
            .animation(Motion.unless(reduceMotion, Motion.hover), value: lit)
            .animation(Motion.unless(reduceMotion, Motion.press), value: isPressed)
            .onHover { hovering = $0 }
    }
}

extension AnyTransition {
    static var controlMorph: AnyTransition {
        .scale(scale: 0.6).combined(with: .opacity)
    }
}

struct CardButtonStyle: ButtonStyle {
    var radius: CGFloat = Theme.cardRadius

    func makeBody(configuration: Configuration) -> some View {
        CardFeedback(configuration: configuration, radius: radius)
    }

    private struct CardFeedback: View {
        let configuration: Configuration
        let radius: CGFloat
        @Environment(\.isEnabled) private var isEnabled
        @Environment(\.accessibilityReduceMotion) private var reduceMotion
        @State private var hovering = false

        var body: some View {
            let lit = isEnabled && hovering
            configuration.label
                .environment(\.rowHovered, lit)
                .overlay {
                    RoundedRectangle(cornerRadius: radius, style: .continuous)
                        .strokeBorder(Theme.accent.opacity(lit ? 0.45 : 0), lineWidth: 1)
                        .allowsHitTesting(false)
                }
                .shadow(color: .black.opacity(lit && !configuration.isPressed ? 0.12 : 0),
                        radius: lit ? 10 : 0, y: lit ? 3 : 0)
                .scaleEffect(isEnabled && configuration.isPressed && !reduceMotion ? 0.985 : 1)
                .animation(Motion.unless(reduceMotion, Motion.hover), value: lit)
                .animation(Motion.unless(reduceMotion, Motion.press), value: configuration.isPressed)
                .onHover { hovering = $0 }
        }
    }
}

struct SidebarRowSeat: View {
    let isSelected: Bool
    let isHovering: Bool
    var selectedFill: Color = Theme.rowSelected
    var hoverOpacity: Double = 0.6
    var radius: CGFloat = 8
    var barInset: CGFloat? = 5
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let hovered = isHovering && !isSelected
        ZStack(alignment: .leading) {
            RoundedRectangle(cornerRadius: radius, style: .continuous)
                .fill(Theme.rowHighlight.opacity(hoverOpacity))
                .opacity(hovered ? 1 : 0)
                .scaleEffect(hovered ? 1 : 0.97)
            RoundedRectangle(cornerRadius: radius, style: .continuous)
                .fill(selectedFill)
                .opacity(isSelected ? 1 : 0)
            if let barInset {
                RoundedRectangle(cornerRadius: 1.5)
                    .fill(Theme.accent)
                    .frame(width: 3)
                    .padding(.vertical, barInset)
                    .scaleEffect(x: 1, y: isSelected ? 1 : 0.2, anchor: .center)
                    .opacity(isSelected ? 1 : 0)
            }
        }
        .animation(Motion.unless(reduceMotion, Motion.hover), value: hovered)
        .animation(Motion.unless(reduceMotion, Motion.morph), value: isSelected)
    }
}

struct ChipButtonStyle: ButtonStyle {
    var radius: CGFloat = 8

    func makeBody(configuration: Configuration) -> some View {
        ChipFeedback(configuration: configuration, radius: radius)
    }

    private struct ChipFeedback: View {
        let configuration: Configuration
        let radius: CGFloat
        @Environment(\.isEnabled) private var isEnabled
        @Environment(\.accessibilityReduceMotion) private var reduceMotion
        @State private var hovering = false

        var body: some View {
            let lit = isEnabled && (hovering || configuration.isPressed)
            configuration.label
                .environment(\.rowHovered, lit)
                .overlay {
                    RoundedRectangle(cornerRadius: radius, style: .continuous)
                        .strokeBorder(Theme.accent.opacity(lit ? 0.5 : 0), lineWidth: 1)
                        .allowsHitTesting(false)
                }
                .scaleEffect(isEnabled && configuration.isPressed && !reduceMotion ? 0.97 : 1)
                .animation(Motion.unless(reduceMotion, Motion.hover), value: lit)
                .animation(Motion.unless(reduceMotion, Motion.press), value: configuration.isPressed)
                .onHover { hovering = $0 }
        }
    }
}

struct HoverSeat: ViewModifier {
    var radius: CGFloat = 8
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var hovering = false

    func body(content: Content) -> some View {
        let on = hovering && isEnabled
        content
            .background {
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .fill(Theme.controlSeat)
                    .opacity(on ? 1 : 0)
                    .scaleEffect(on ? 1 : 0.8)
                    .animation(Motion.unless(reduceMotion, Motion.morph), value: on)
            }
            .onHover { hovering = $0 }
    }
}

extension View {
    func hoverSeat(radius: CGFloat = 8) -> some View {
        modifier(HoverSeat(radius: radius))
    }
}

struct DisclosureChevron: View {
    let expanded: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Image(systemName: "chevron.down")
            .font(Theme.caption)
            .foregroundStyle(.secondary)
            .rotationEffect(.degrees(expanded ? 180 : 0))
            .animation(Motion.unless(reduceMotion, Motion.morph), value: expanded)
            .accessibilityHidden(true)
    }
}

struct ChipHoverFill: View {
    var radius: CGFloat = 8
    @Environment(\.rowHovered) private var hovered
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        RoundedRectangle(cornerRadius: radius, style: .continuous)
            .fill(Theme.rowHighlight)
            .opacity(hovered ? 1 : 0)
            .animation(Motion.unless(reduceMotion, Motion.hover), value: hovered)
    }
}

struct QuietLinkStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        QuietLink(configuration: configuration)
    }

    private struct QuietLink: View {
        let configuration: Configuration
        @Environment(\.isEnabled) private var isEnabled
        @Environment(\.accessibilityReduceMotion) private var reduceMotion
        @State private var hovering = false

        var body: some View {
            configuration.label
                .opacity(isEnabled ? (configuration.isPressed ? 0.55 : (hovering ? 0.72 : 1)) : 0.42)
                .scaleEffect(isEnabled && configuration.isPressed && !reduceMotion ? 0.97 : 1)
                .animation(Motion.unless(reduceMotion, Motion.hover), value: hovering)
                .animation(Motion.unless(reduceMotion, Motion.press), value: configuration.isPressed)
                .contentShape(.rect)
                .onHover { hovering = $0 }
        }
    }
}
