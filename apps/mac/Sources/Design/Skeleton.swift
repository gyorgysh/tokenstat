// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
//
// Source-available for review, NOT open source. See LICENSE: no rights to
// redistribute, publish, or ship a build are granted. Read it, study it, run
// your own build of it.
// "tokenstat" is a trademark of pueev OU. See TRADEMARK.md.

import SwiftUI

/// Placeholders shaped like the thing that is coming.
///
/// Flow for a cold launch:
/// 1. App splash (logo) while the host starts — see `LaunchState`.
/// 2. **These** wireframes, with a light pulse so the wait does not feel frozen.
/// 3. Real content replaces each skeleton with `.smoothIn`.
///
/// Never a spinner in an empty pane, and never a blurred wireframe under a
/// brand mark on the same layer.
enum Skeleton {
    /// One grey bar standing in for a line of text or a number.
    ///
    /// `width` of nil fills the space, which is what a title or a row wants.
    /// A soft opacity pulse (when motion is allowed) keeps the layout alive
    /// without a shimmer that steals attention from the data about to land.
    struct Bar: View {
        var width: CGFloat?
        var height: CGFloat = 12
        /// Phase offset so neighbouring bars do not pulse in lockstep.
        var phase: Double = 0

        @Environment(\.accessibilityReduceMotion) private var reduceMotion
        @State private var bright = false

        var body: some View {
            RoundedRectangle(cornerRadius: 4)
                .fill(Theme.border)
                .frame(width: width, height: height)
                .frame(maxWidth: width == nil ? .infinity : nil, alignment: .leading)
                .opacity(reduceMotion ? 1 : (bright ? 1 : 0.52))
                .animation(
                    reduceMotion
                        ? nil
                        : .easeInOut(duration: 0.95)
                            .repeatForever(autoreverses: true)
                            .delay(phase),
                    value: bright
                )
                .onAppear {
                    guard !reduceMotion else { return }
                    bright = true
                }
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
                        Bar(
                            width: Self.labelWidths[index % Self.labelWidths.count],
                            phase: Double(index) * 0.08
                        )
                        Spacer(minLength: Theme.Space.s)
                        if showsValue {
                            Bar(width: 52, phase: Double(index) * 0.08 + 0.04)
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
                    Bar(width: 116, height: 11, phase: 0)
                    Bar(width: 168, height: 9, phase: 0.06)
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
/// Wireframes stay sharp (pulse lives on `Skeleton.Bar`). Real content replaces
/// them with `.smoothIn`.
struct Warming: ViewModifier {
    let active: Bool

    func body(content: Content) -> some View {
        content.allowsHitTesting(!active)
    }
}

extension View {
    /// Mark this subtree as a placeholder for data that has not arrived.
    func warming(_ active: Bool) -> some View {
        modifier(Warming(active: active))
    }
}

extension AnyTransition {
    /// The arrival of loaded content: a short fade with a small rise.
    /// Collapses to a plain fade when Reduce Motion is on.
    static func smoothIn(reduceMotion: Bool) -> AnyTransition {
        reduceMotion ? .opacity : .opacity.combined(with: .offset(y: 4))
    }
}
