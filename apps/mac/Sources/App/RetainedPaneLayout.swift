// SPDX-License-Identifier: LicenseRef-tokenstat-source-available

#if os(macOS)
import SwiftUI

/// Keeps hidden screens at their last size without measuring their trees again.
struct RetainedPaneLayout: Layout {
    var isActive: Bool

    struct Cache {
        var size: CGSize?

        func resolve(proposal: ProposedViewSize, isActive: Bool,
                     measure: (ProposedViewSize) -> CGSize) -> CGSize {
            // Infinity asks about flexibility; it is not a drawable frame.
            // Returning that probe as the pane's size let native controls
            // receive infinite bounds and abort with an invalid view origin.
            let finite = ProposedViewSize(
                width: proposal.width.flatMap { $0.isFinite ? max(0, $0) : nil },
                height: proposal.height.flatMap { $0.isFinite ? max(0, $0) : nil }
            )
            // Preserve the fast path for the concrete window offer.
            if let width = finite.width, let height = finite.height {
                return CGSize(width: width, height: height)
            }
            if isActive || size == nil {
                let measured = measure(finite)
                let ideal = CGSize(
                    width: measured.width.isFinite ? max(0, measured.width) : (size?.width ?? 0),
                    height: measured.height.isFinite ? max(0, measured.height) : (size?.height ?? 0)
                )
                return finite.replacingUnspecifiedDimensions(by: ideal)
            }
            return finite.replacingUnspecifiedDimensions(by: size ?? .zero)
        }
    }

    func makeCache(subviews: Subviews) -> Cache { Cache() }

    func updateCache(_ cache: inout Cache, subviews: Subviews) {
        // Hidden panes keep their last size across parent updates.
        if subviews.isEmpty { cache.size = nil }
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout Cache) -> CGSize {
        guard let pane = subviews.first else { return .zero }
        return cache.resolve(proposal: proposal, isActive: isActive) { pane.sizeThatFits($0) }
    }

    // A screen aligns by its frame. Asking its guides measures it again.
    func explicitAlignment(of guide: HorizontalAlignment, in bounds: CGRect, proposal: ProposedViewSize,
                           subviews: Subviews, cache: inout Cache) -> CGFloat? { nil }

    func explicitAlignment(of guide: VerticalAlignment, in bounds: CGRect, proposal: ProposedViewSize,
                           subviews: Subviews, cache: inout Cache) -> CGFloat? { nil }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout Cache) {
        guard let pane = subviews.first else { return }
        let size = isActive ? bounds.size : (cache.size ?? bounds.size)
        guard size.width.isFinite, size.height.isFinite, size.width > 0, size.height > 0 else { return }
        // Only a placed frame is a remembered screen size. Minimum and
        // maximum probes can run later in the same pass; caching them made
        // the next hidden frame zero-sized or infinite.
        if isActive || cache.size == nil { cache.size = size }
        pane.place(at: bounds.origin, anchor: .topLeading, proposal: ProposedViewSize(size))
    }
}
#endif
