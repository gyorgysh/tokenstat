// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
//
// Source-available for review, NOT open source. See LICENSE: no rights to
// redistribute, publish, or ship a build are granted. Read it, study it, run
// your own build of it.
// "tokenstat" is a trademark of pueev OU. See TRADEMARK.md.

import SwiftUI

/// A short sideways shake, for a control that was pressed before it could work.
///
/// The alternative this replaces is a disabled button, which answers "why is
/// nothing happening" with nothing at all. A person who has filled one of two
/// password fields and pressed the button has asked a question, and a greyed
/// control does not answer it: it cannot be pressed, so it cannot say why.
///
/// Motion only. The sentence saying what is missing is the real answer and is
/// the caller's job; this is what makes somebody look at it.
private struct Shake: GeometryEffect {
    /// Whole shakes performed. Animating this from n to n+1 runs one.
    var amount: CGFloat

    var animatableData: CGFloat {
        get { amount }
        set { amount = newValue }
    }

    func effectValue(size: CGSize) -> ProjectionTransform {
        // Three there-and-back passes over the animation, decaying so it
        // settles rather than stopping dead.
        let travel = sin(amount * .pi * 6)
        let decay = max(0, 1 - amount)
        return ProjectionTransform(CGAffineTransform(translationX: travel * 7 * decay, y: 0))
    }
}

extension View {
    /// Shake whenever `trigger` changes.
    ///
    /// Respects Reduce Motion: somebody who has asked for less movement gets
    /// none, and the message beside the field is what tells them. A shake is
    /// an emphasis on an answer, never the answer itself.
    func shake(on trigger: some Equatable) -> some View {
        modifier(ShakeOnChange(trigger: AnyHashableEquatable(trigger)))
    }
}

/// Erases the trigger so the modifier is one type rather than one per caller.
private struct AnyHashableEquatable: Equatable {
    let value: String

    init(_ wrapped: some Equatable) {
        self.value = String(describing: wrapped)
    }
}

private struct ShakeOnChange: ViewModifier {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let trigger: AnyHashableEquatable

    @State private var shakes: CGFloat = 0

    func body(content: Content) -> some View {
        content
            .modifier(Shake(amount: shakes))
            .onChange(of: trigger) { _, _ in
                guard !reduceMotion else { return }
                withAnimation(.linear(duration: 0.35)) { shakes += 1 }
            }
    }
}
