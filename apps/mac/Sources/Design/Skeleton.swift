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
/// grey shapes where the numbers will be, and swap the shapes for the numbers
/// when they arrive. Never a spinner in the middle of an empty pane. A spinner
/// says "wait" and nothing else; a wireframe says how much is coming, where it
/// will be, and how long the screen will end up. The window also stops jumping,
/// because the space is already claimed.
///
/// Nothing here animates. A shimmer is a brand animation between a person and
/// their own data, and a launch is not an event worth celebrating.
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

/// Blurred and dimmed rather than replaced by something that spins.
///
/// The screen people are waiting for is already the best thing to show them: it
/// says how much is coming and where each piece will be, and it does not put a
/// brand animation between them and their own data. Nothing here moves, and
/// nothing here is tinted: a launch is not an event worth celebrating.
struct Warming: ViewModifier {
    let active: Bool

    func body(content: Content) -> some View {
        content
            .blur(radius: active ? 7 : 0)
            .opacity(active ? 0.45 : 1)
            .allowsHitTesting(!active)
            // Short, and only on the way out. Arriving data should look like
            // the screen coming into focus, not like a transition playing.
            .animation(.easeOut(duration: 0.22), value: active)
    }
}

extension View {
    /// Mark this subtree as a placeholder for data that has not arrived.
    func warming(_ active: Bool) -> some View {
        modifier(Warming(active: active))
    }
}
