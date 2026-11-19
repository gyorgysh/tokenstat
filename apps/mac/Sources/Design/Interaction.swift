// SPDX-License-Identifier: LicenseRef-tokenstat-source-available

import SwiftUI

/// One motion vocabulary for every hover, press and reveal.
///
/// Before this, each control picked its own `easeOut` duration and most
/// state changes snapped. Springs carry velocity, so a seat that is still
/// growing when the pointer leaves shrinks from where it is instead of
/// jumping, which is most of what makes a control feel native.
enum Motion {
    /// A seat or tint fading in under the pointer.
    static let hover: Animation = .easeOut(duration: 0.16)
    /// A control giving under a click and springing back.
    static let press: Animation = .spring(response: 0.22, dampingFraction: 0.68)
    /// A shape changing size or a glyph moving: a seat growing, a chevron
    /// nudging forward, a button arriving in a row.
    static let morph: Animation = .spring(response: 0.32, dampingFraction: 0.8)

    /// Nil when Reduce Motion is on, so callers write one line.
    static func unless(_ reduce: Bool, _ animation: Animation) -> Animation? {
        reduce ? nil : animation
    }
}

private struct RowHoveredKey: EnvironmentKey {
    static let defaultValue = false
}

extension EnvironmentValues {
    /// True while the pointer is over the row a `RowFeedbackStyle` draws.
    /// Leaves inside the row (a chevron, a secondary label) read it to move
    /// with the row instead of each tracking hover on its own.
    var rowHovered: Bool {
        get { self[RowHoveredKey.self] }
        set { self[RowHoveredKey.self] = newValue }
    }
}

/// A list row inside a card: Continue, Devices, pinned work, settings lists.
///
/// The seat bleeds past the row's text edge so the label keeps its column
/// and the highlight still has air around it. A seat drawn flush with the
/// text made the row look clipped. It grows into place from slightly smaller
/// rather than fading as a flat slab, and the row gives a little under a
/// click.
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

/// The trailing "go" mark on a row. Quiet at rest, it brightens and steps
/// forward with the row under the pointer, which says the whole row opens
/// without a second visual target.
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

/// Hover and press for the capsule button family (accent, secondary,
/// destructive). The styles keep their own colours. This adds what they
/// lacked: a lift under the pointer, a firmer edge, and a spring on press.
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

/// How a button arrives in and leaves a row: it grows out of its own
/// centre instead of popping, and shrinks back the same way.
extension AnyTransition {
    static var controlMorph: AnyTransition {
        .scale(scale: 0.6).combined(with: .opacity)
    }
}

/// A whole card that opens something: an automation template, a saved
/// command, an SSH entry. The card draws its own fill and border. Under the
/// pointer this tints that border toward the accent and lifts the card a
/// hair, so it reads as one target rather than a panel with text in it.
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

/// The seat under a sidebar row: a hover wash that grows into place and a
/// selection tint whose accent bar stretches open from the row's middle.
///
/// Every sidebar row used to draw this by hand, and none of them animated,
/// so moving between chats was a hard cut. One seat means one motion: the
/// old row's bar folds away while the new one opens, which reads as the
/// selection moving rather than two rows repainting.
struct SidebarRowSeat: View {
    let isSelected: Bool
    let isHovering: Bool
    var selectedFill: Color = Theme.rowSelected
    var hoverOpacity: Double = 0.6
    var radius: CGFloat = 8
    /// Vertical inset of the accent bar. Nil draws no bar, which is how the
    /// nested rows inside a project tell themselves apart from the project.
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

/// A chip that opens a picker: the agent and model field, filter chips.
/// The chip draws its own panel and border. This adds the capsule family's
/// hover lift and press spring so a chip feels like the buttons beside it.
struct ChipButtonStyle: ButtonStyle {
    var radius: CGFloat = 8

    func makeBody(configuration: Configuration) -> some View {
        ChipFeedback(configuration: configuration, radius: radius)
    }

    /// Clearer than the capsule family's lift: a chip sits on a white panel
    /// with a grey edge, where a faint tint did not read as a response.
    private struct ChipFeedback: View {
        let configuration: Configuration
        let radius: CGFloat
        @Environment(\.isEnabled) private var isEnabled
        @Environment(\.accessibilityReduceMotion) private var reduceMotion
        @State private var hovering = false

        var body: some View {
            let lit = isEnabled && (hovering || configuration.isPressed)
            configuration.label
                // The chip paints its own panel, so the fill is drawn by the
                // chip itself (`ChipHoverFill`) between its text and panel.
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

/// The quiet hover seat for controls that cannot take a button style,
/// such as a borderless `Menu`. Grows out of the glyph like the toolbar
/// marks, so a menu and a button side by side answer the pointer alike.
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

/// One chevron that turns, rather than an up glyph swapped for a down one.
/// The turn is what tells the eye the section opened from here.
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

/// The hover fill inside a chip that draws its own panel. Placed in the
/// label before the panel, so it sits under the text and over the panel.
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

/// A text button that reads as a link: "Show more", "Clear", "View all".
/// It dims a little under the pointer and gives on press, and adds no seat,
/// because a fill hugging a word with no padding looks clipped.
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
