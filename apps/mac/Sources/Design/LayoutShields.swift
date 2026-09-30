// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
//
// Source-available for review, NOT open source. See LICENSE: no rights to
// redistribute, publish, or ship a build are granted. Read it, study it, run
// your own build of it.
// "tokenstat" is a trademark of pueev OU. See TRADEMARK.md.

import SwiftUI

/// Answers a size question it has already answered, without asking again.
///
/// `ViewThatFits` builds and measures its candidates inside layout, and a
/// stack asks each flexible child several times per pass. Every relayout of
/// the bar above the tab strip therefore built and measured four whole tab
/// strips three times over, a third of the main thread on a chat switch.
/// The answers depend only on the offer and on `key`, which the caller
/// derives from everything the child draws, so a new key forgets them.
struct MemoizedSizeLayout: Layout {
    var key: Int

    struct Cache {
        var key: Int?
        var sizes: [Offer: CGSize] = [:]
    }

    struct Offer: Hashable {
        var width: CGFloat?
        var height: CGFloat?
    }

    func makeCache(subviews: Subviews) -> Cache { Cache() }

    // Kept across updates on purpose. `key` is what says the answers expired.
    func updateCache(_ cache: inout Cache, subviews: Subviews) {}

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout Cache) -> CGSize {
        guard let child = subviews.first else { return .zero }
        if cache.key != key { cache = Cache(key: key) }
        let offer = Offer(width: proposal.width, height: proposal.height)
        if let size = cache.sizes[offer] { return size }
        let size = child.sizeThatFits(proposal)
        if cache.sizes.count >= 32 { cache.sizes.removeAll(keepingCapacity: true) }
        cache.sizes[offer] = size
        return size
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout Cache) {
        subviews.first?.place(at: bounds.origin, anchor: .topLeading, proposal: ProposedViewSize(bounds.size))
    }

    // See `AlignmentShieldLayout`: a stack asking for a guide made
    // `ViewThatFits` measure every candidate again.
    func explicitAlignment(of guide: HorizontalAlignment, in bounds: CGRect, proposal: ProposedViewSize,
                           subviews: Subviews, cache: inout Cache) -> CGFloat? { nil }

    func explicitAlignment(of guide: VerticalAlignment, in bounds: CGRect, proposal: ProposedViewSize,
                           subviews: Subviews, cache: inout Cache) -> CGFloat? { nil }
}

/// Stops a stack's alignment questions at this view.
///
/// A stack asks each child where its alignment guide is. `ViewThatFits`
/// answers by building and measuring every candidate, on every layout pass,
/// even when nothing about it changed: most of a chat switch was the tab
/// strip and the composer's control row answering that question. Their
/// candidates set no guides of their own, so the default placement this
/// returns is the one the stack used anyway.
struct AlignmentShieldLayout: Layout {
    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        subviews.first?.sizeThatFits(proposal) ?? .zero
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        subviews.first?.place(at: bounds.origin, anchor: .topLeading, proposal: ProposedViewSize(bounds.size))
    }

    func explicitAlignment(of guide: HorizontalAlignment, in bounds: CGRect, proposal: ProposedViewSize,
                           subviews: Subviews, cache: inout ()) -> CGFloat? { nil }

    func explicitAlignment(of guide: VerticalAlignment, in bounds: CGRect, proposal: ProposedViewSize,
                           subviews: Subviews, cache: inout ()) -> CGFloat? { nil }
}
