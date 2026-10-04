// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
// Compile with RetainedPaneLayout.swift.
import SwiftUI

@main
struct RetainedPaneLayoutTests {
    static func main() {
        var cache = RetainedPaneLayout.Cache()
        var measurements = 0
        func measure(_ offer: ProposedViewSize) -> CGSize {
            precondition(offer.width?.isFinite ?? true)
            precondition(offer.height?.isFinite ?? true)
            measurements += 1
            return CGSize(width: 420, height: 240)
        }
        // Startup's maximum-size probe must neither return nor cache infinity.
        let maximum = cache.resolve(proposal: .infinity, isActive: true, measure: measure)
        precondition(maximum == CGSize(width: 420, height: 240))
        precondition(cache.size == nil && measurements == 1)

        let concrete = cache.resolve(proposal: ProposedViewSize(width: 900, height: 700),
                                     isActive: true, measure: measure)
        precondition(concrete == CGSize(width: 900, height: 700) && measurements == 1)
        cache.size = concrete // The size recorded by placeSubviews.

        let probe = cache.resolve(proposal: .zero, isActive: true, measure: measure)
        precondition(probe == .zero && cache.size == concrete && measurements == 1)

        // A background pane answers probes from its cache without relayout.
        let hidden = cache.resolve(proposal: ProposedViewSize(width: .infinity, height: 500),
                                   isActive: false, measure: measure)
        precondition(hidden == CGSize(width: 900, height: 500))
        precondition(cache.size == concrete && measurements == 1)

        let visible = cache.resolve(proposal: ProposedViewSize(width: 600, height: nil),
                                    isActive: true, measure: measure)
        precondition(visible == CGSize(width: 600, height: 240) && measurements == 2)

        let invalid = cache.resolve(proposal: ProposedViewSize(width: .nan, height: -.infinity),
                                    isActive: true) { _ in CGSize(width: CGFloat.infinity, height: CGFloat.nan) }
        precondition(invalid == concrete && cache.size == concrete)

        let empty = RetainedPaneLayout.Cache()
        let minimum = empty.resolve(proposal: .zero, isActive: false, measure: measure)
        precondition(minimum == .zero && empty.size == nil && measurements == 2)
        print("Retained pane layout tests passed")
    }
}
