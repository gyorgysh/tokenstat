// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
import SwiftUI

/// Share spare room between tabs without compressing translated or enlarged labels.
struct ChatSectionTabs<Content: View>: View {
    @ViewBuilder var content: () -> Content
    @Environment(\.layoutDirection) private var direction

    var body: some View {
        WidthReader { width in
            ScrollView(.horizontal) {
                ChatSectionTabLayout(minimumWidth: width, direction: direction) { content() }
            }
            .scrollIndicators(.hidden)
        }
    }
}

private struct ChatSectionTabLayout: Layout {
    let minimumWidth: CGFloat
    let direction: LayoutDirection
    private let spacing: CGFloat = 4

    private func widths(_ subviews: Subviews) -> [CGFloat] {
        let natural = subviews.map { $0.sizeThatFits(.unspecified).width }
        let gaps = spacing * CGFloat(max(0, natural.count - 1))
        let extra = max(0, minimumWidth - natural.reduce(0, +) - gaps) / CGFloat(max(1, natural.count))
        return natural.map { $0 + extra }
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let widths = widths(subviews)
        let height = zip(subviews, widths).map { view, width in
            view.sizeThatFits(.init(width: width, height: nil)).height
        }.max() ?? 0
        return CGSize(width: widths.reduce(0, +) + spacing * CGFloat(max(0, widths.count - 1)), height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = direction == .rightToLeft ? bounds.maxX : bounds.minX
        for (view, width) in zip(subviews, widths(subviews)) {
            if direction == .rightToLeft { x -= width }
            view.place(at: CGPoint(x: x, y: bounds.minY), anchor: .topLeading,
                       proposal: .init(width: width, height: bounds.height))
            x += direction == .rightToLeft ? -spacing : width + spacing
        }
    }
}
