// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
import SwiftUI

/// The first action needed before a conversation can start.
struct ChatStartOnboarding: View {
    let onAdd: () -> Void
    var acceptsFolderDrops = false
    var dropTargeted = false

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.m) {
            HStack(alignment: .top, spacing: Theme.Space.m) {
                Image(systemName: "folder")
                    .font(Theme.font(16, weight: .medium))
                    .foregroundStyle(Theme.accent)
                    .frame(width: 32, height: 32)
                    .background(Theme.accentSoft, in: RoundedRectangle(cornerRadius: 9))
                VStack(alignment: .leading, spacing: 4) {
                    Text(L10n.text("common.new_chat.add_repository"))
                        .font(Theme.font(14, weight: .semibold))
                    Text(L10n.text("common.new_chat.step_repository_message"))
                        .font(Theme.font(12))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            HStack(spacing: Theme.Space.m) {
                Button(L10n.text("common.new_chat.add_repository"), .create, action: onAdd)
                    .buttonStyle(AccentButtonStyle(small: true))
                if acceptsFolderDrops {
                    Text(L10n.text("common.new_chat.drop_folder"))
                        .font(Theme.caption)
                        .foregroundStyle(dropTargeted ? Theme.accent : Color.secondary)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(Theme.Space.s)
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

/// A quiet surface shared by the composer and the first-repository action.
extension View {
    func chatStartCard(highlighted: Bool = false) -> some View {
        let shape = RoundedRectangle(cornerRadius: 16)
        return self.padding(12)
            .background(Theme.panel, in: shape)
            .overlay(shape.strokeBorder(highlighted ? Theme.accent.opacity(0.6) : Theme.border))
    }
}
