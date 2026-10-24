// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
import SwiftUI

/// What the new chat page shows before there is any repository to talk
/// about.
///
/// It used to show the whole composer with a picker that had nothing in it
/// and a line of caption under the card, so the one action that unblocks the
/// page was a menu item inside a menu. Here the three things a first
/// conversation needs are laid out in order, with the first one as the only
/// button on the page. The card wears the composer's chrome, so the page
/// keeps its shape when the repository arrives and the composer takes over.
struct ChatStartOnboarding: View {
    let onAdd: () -> Void
    /// The page takes a dropped folder as a new repository.
    var acceptsFolderDrops = false
    var dropTargeted = false

    private struct Step: Identifiable {
        let id: Int
        let title: String
        let message: String
    }

    private var steps: [Step] {
        [
            Step(id: 1, title: L10n.text("common.new_chat.step_repository_title"),
                 message: L10n.text("common.new_chat.step_repository_message")),
            Step(id: 2, title: L10n.text("common.new_chat.step_agent_title"),
                 message: L10n.text("common.new_chat.step_agent_message")),
            Step(id: 3, title: L10n.text("common.new_chat.step_send_title"),
                 message: L10n.text("common.new_chat.step_send_message")),
        ]
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(steps) { step in
                row(step, last: step.id == steps.count)
            }
            if acceptsFolderDrops {
                Text(L10n.text("common.new_chat.drop_folder"))
                    .font(Theme.caption)
                    .foregroundStyle(dropTargeted ? Theme.accent : Color.secondary)
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding(.top, 14)
                    .padding(.bottom, 2)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 10)
    }

    private func row(_ step: Step, last: Bool) -> some View {
        let current = step.id == 1
        return HStack(alignment: .top, spacing: 14) {
            VStack(spacing: 0) {
                badge(step.id, current: current)
                if !last {
                    // The thread between the steps: lit where it leaves the
                    // step in hand, fading towards the ones still ahead.
                    Rectangle()
                        .fill(LinearGradient(colors: [current ? Theme.accent.opacity(0.45) : Theme.border, Theme.border.opacity(0.4)],
                                             startPoint: .top, endPoint: .bottom))
                        .frame(width: 1)
                        .frame(minHeight: 18)
                }
            }
            VStack(alignment: .leading, spacing: 4) {
                Text(step.title)
                    .font(Theme.font(14, weight: .semibold))
                    .foregroundStyle(current ? Color.primary : Color.secondary)
                Text(step.message)
                    .font(Theme.font(12))
                    .foregroundStyle(current ? Color.secondary : Color.secondary.opacity(0.8))
                    .fixedSize(horizontal: false, vertical: true)
                if current {
                    Button(L10n.text("common.new_chat.add_repository"), .create, action: onAdd)
                        .buttonStyle(AccentButtonStyle(small: true))
                        .padding(.top, 8)
                }
            }
            .padding(.bottom, last ? 0 : 16)
            Spacer(minLength: 0)
        }
        .accessibilityElement(children: .contain)
    }

    private func badge(_ number: Int, current: Bool) -> some View {
        Text("\(number)")
            .font(Theme.fixed(11, weight: .semibold))
            .monospacedDigit()
            .foregroundStyle(current ? Theme.accent : Color.secondary)
            .frame(width: 24, height: 24)
            .background(Circle().fill(current ? Theme.accentSoft : Color.clear))
            .overlay(Circle().strokeBorder(current ? Theme.accent.opacity(0.55) : Theme.border, lineWidth: 1))
            .accessibilityHidden(true)
    }
}

/// A few ways to begin, under an empty composer. A first-time reader learns
/// what kind of thing to ask; anyone else ignores three quiet chips that go
/// away the moment they start writing.
struct ChatStartStarters: View {
    let onPick: (String) -> Void
    var revealed = true
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        FlowRow(spacing: 8) {
            starter(0, Button(L10n.text("common.new_chat.starter_tour"), .docs) { onPick(L10n.text("common.new_chat.starter_tour")) })
            starter(1, Button(L10n.text("common.new_chat.starter_tests"), .run) { onPick(L10n.text("common.new_chat.starter_tests")) })
            starter(2, Button(L10n.text("common.new_chat.starter_review"), .compare) { onPick(L10n.text("common.new_chat.starter_review")) })
        }
        .frame(maxWidth: .infinity)
    }

    private func starter(_ index: Int, _ button: some View) -> some View {
        button
            .buttonStyle(ChatStartStarterStyle())
            .opacity(revealed ? 1 : 0)
            .offset(y: revealed ? 0 : 6)
            .animation(reduceMotion ? nil : .easeOut(duration: 0.4).delay(0.08 * Double(index)), value: revealed)
    }
}

/// Lighter than a secondary button: these are suggestions, not actions the
/// page is asking for.
private struct ChatStartStarterStyle: ButtonStyle {
    @State private var hovering = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .labelStyle(ActionLabelStyle(small: true))
            .font(Theme.font(12, weight: .medium))
            .foregroundStyle(hovering ? Color.primary : Color.secondary)
            .padding(.horizontal, 12)
            .frame(height: Theme.Control.heightSmall)
            #if !os(macOS)
            .frame(minHeight: 44)
            #endif
            .background(Capsule().fill(Theme.panel.opacity(hovering || configuration.isPressed ? 0.95 : 0.55)))
            .overlay(Capsule().strokeBorder(hovering ? Theme.accent.opacity(0.40) : Theme.border.opacity(0.8), lineWidth: 1))
            .contentShape(Capsule())
            .opacity(configuration.isPressed ? 0.8 : 1)
            .onHover { hovering = $0 }
            .animation(.easeOut(duration: 0.15), value: hovering)
    }
}

/// Wraps its children onto as many centred lines as the width needs.
private struct FlowRow: Layout {
    var spacing: CGFloat = 8

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let lines = arrange(width: proposal.width ?? .infinity, subviews: subviews)
        let height = lines.reduce(0) { $0 + $1.height } + spacing * CGFloat(max(0, lines.count - 1))
        let width = lines.map(\.width).max() ?? 0
        return CGSize(width: proposal.width ?? width, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var y = bounds.minY
        for line in arrange(width: bounds.width, subviews: subviews) {
            var x = bounds.minX + (bounds.width - line.width) / 2
            for index in line.indices {
                let size = subviews[index].sizeThatFits(.unspecified)
                subviews[index].place(at: CGPoint(x: x, y: y + (line.height - size.height) / 2), proposal: .unspecified)
                x += size.width + spacing
            }
            y += line.height + spacing
        }
    }

    private struct Line { var indices: [Int] = []; var width: CGFloat = 0; var height: CGFloat = 0 }

    private func arrange(width: CGFloat, subviews: Subviews) -> [Line] {
        var lines: [Line] = []
        var line = Line()
        for index in subviews.indices {
            let size = subviews[index].sizeThatFits(.unspecified)
            let needed = line.indices.isEmpty ? size.width : line.width + spacing + size.width
            if needed > width, !line.indices.isEmpty {
                lines.append(line)
                line = Line()
            }
            line.width = line.indices.isEmpty ? size.width : line.width + spacing + size.width
            line.height = max(line.height, size.height)
            line.indices.append(index)
        }
        if !line.indices.isEmpty { lines.append(line) }
        return lines
    }
}

/// The composer card and the onboarding card share one piece of glass: the
/// panel, a hairline, a bevel that catches the light along the top edge, and
/// a glow under it. It also reports its frame, which is where the surface
/// draws the spectrum the card throws.
/// Where the page wants the card's frame, in the page's own coordinates.
/// A preference anchor is resolved once and does not follow a scroll, so the
/// spectrum stayed behind as a loose frame when the content moved under it.
/// A geometry observer reports every change, scrolling included.
struct ChatStartCardFrameKey: EnvironmentKey {
    static let defaultValue: (@MainActor (CGRect) -> Void)? = nil
}
extension EnvironmentValues {
    var chatStartCardFrame: (@MainActor (CGRect) -> Void)? {
        get { self[ChatStartCardFrameKey.self] }
        set { self[ChatStartCardFrameKey.self] = newValue }
    }
}
/// The named space the card's frame is measured in: the start page's pane.
enum ChatStartPaneSpace { static let name = "chatStartPane" }
private struct ChatStartCardReporter: ViewModifier {
    @Environment(\.chatStartCardFrame) private var report
    func body(content: Content) -> some View {
        content.onGeometryChange(for: CGRect.self) { $0.frame(in: .named(ChatStartPaneSpace.name)) } action: { frame in
            report?(frame)
        }
    }
}

extension View {
    func chatStartCard(highlighted: Bool = false) -> some View {
        let shape = RoundedRectangle(cornerRadius: 22)
        return self
            .padding(12)
            .background(Theme.panel, in: shape)
            .overlay(shape.strokeBorder(highlighted ? Theme.accent.opacity(0.6) : Theme.border))
            .overlay {
                shape.strokeBorder(LinearGradient(stops: [.init(color: .white.opacity(0.13), location: 0),
                                                          .init(color: .white.opacity(0.03), location: 0.18),
                                                          .init(color: .clear, location: 0.5)],
                                                  startPoint: .top, endPoint: .bottom), lineWidth: 1)
                    .allowsHitTesting(false)
            }
            .shadow(color: Theme.accent.opacity(highlighted ? 0.16 : 0.06), radius: 35, y: 12)
            .modifier(ChatStartCardReporter())
    }
}
