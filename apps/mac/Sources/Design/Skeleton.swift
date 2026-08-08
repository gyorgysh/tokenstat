// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
//
// Source-available for review, NOT open source. See LICENSE: no rights to
// redistribute, publish, or ship a build are granted. Read it, study it, run
// your own build of it.
// "tokenstat" is a trademark of pueev OU. See TRADEMARK.md.

import SwiftUI

/// Placeholders shaped like the thing that is coming.
///
/// The rule for every screen in this app: draw the layout immediately, with
/// grey shapes where the numbers will be, and **replace** those shapes with
/// the real content when it arrives (short fade, see `smoothIn`). Never a
/// spinner in the middle of an empty pane, and never a blurred wireframe under
/// a brand mark: that made loading feel heavier than the wait.
///
/// Nothing here animates on its own. A shimmer is a brand animation between a
/// person and their own data, and a launch is not an event worth celebrating.
enum Skeleton {
    /// One grey bar standing in for a line of text or a number.
    ///
    /// `width` of nil fills the space, which is what a title or a row wants.
    struct Bar: View {
        var width: CGFloat?
        var height: CGFloat = 12

        var body: some View {
            RoundedRectangle(cornerRadius: 4)
                .fill(Theme.border)
                .frame(width: width, height: height)
                .frame(maxWidth: width == nil ? .infinity : nil, alignment: .leading)
        }
    }

    /// A stack of rows, each a label bar and a value bar, like a list.
    ///
    /// Widths vary down the stack so it reads as text rather than as a bar
    /// chart. Deterministic, not random: a placeholder that reshuffles on every
    /// redraw is a distraction of its own.
    struct Rows: View {
        var count: Int = 5
        var showsValue = true

        var body: some View {
            VStack(spacing: Theme.Space.s) {
                ForEach(0..<count, id: \.self) { index in
                    HStack(spacing: Theme.Space.s) {
                        Bar(width: Self.labelWidths[index % Self.labelWidths.count])
                        Spacer(minLength: Theme.Space.s)
                        if showsValue {
                            Bar(width: 52)
                        }
                    }
                }
            }
        }

        private static let labelWidths: [CGFloat] = [128, 96, 152, 84, 116, 104]
    }

    /// A card-shaped placeholder: heading, subheading, and some rows.
    struct CardPlaceholder: View {
        var rows: Int = 3

        var body: some View {
            VStack(alignment: .leading, spacing: Theme.Space.m) {
                VStack(alignment: .leading, spacing: 4) {
                    Bar(width: 116, height: 11)
                    Bar(width: 168, height: 9)
                }
                Rows(count: rows)
            }
            .padding(Theme.cardPadding)
            .frame(maxWidth: .infinity, alignment: .topLeading)
            .background(Theme.panel, in: RoundedRectangle(cornerRadius: Theme.cardRadius))
            .overlay(
                RoundedRectangle(cornerRadius: Theme.cardRadius)
                    .strokeBorder(Theme.border, lineWidth: 1)
            )
        }
    }
}

/// Marks a placeholder subtree as non-interactive while data is loading.
///
/// Wireframes stay **sharp** at full opacity. Blur was retired: stacking blur
/// on a skeleton under a logo made the first paint feel like a glass door
/// rather than a layout that is about to fill in. Real content replaces the
/// placeholder with `.smoothIn`.
struct Warming: ViewModifier {
    let active: Bool

    func body(content: Content) -> some View {
        content.allowsHitTesting(!active)
    }
}

extension View {
    /// Mark this subtree as a placeholder for data that has not arrived.
    ///
    /// Does not blur or dim. Kept so existing call sites stay readable; the
    /// visual rule is "sharp wireframe, then fade real content in".
    func warming(_ active: Bool) -> some View {
        modifier(Warming(active: active))
    }
}

extension AnyTransition {
    /// The arrival of loaded content: a short fade with a small rise, the
    /// difference between "appeared" and "arrived". Cheap on purpose — one
    /// easeOut on a view that is replacing a placeholder. Collapses to a
    /// plain fade when Reduce Motion is on.
    static func smoothIn(reduceMotion: Bool) -> AnyTransition {
        reduceMotion ? .opacity : .opacity.combined(with: .offset(y: 4))
    }
}
