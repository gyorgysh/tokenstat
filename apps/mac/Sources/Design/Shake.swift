// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
//
// Source-available: source sharing and own builds are permitted.
// Store and commercial distribution of builds is reserved. See LICENSE.
// "tokenstat" is a trademark of pueev OU. See TRADEMARK.md.

import SwiftUI

private struct Shake: GeometryEffect {
    var amount: CGFloat

    var animatableData: CGFloat {
        get { amount }
        set { amount = newValue }
    }

    func effectValue(size: CGSize) -> ProjectionTransform {
        let progress = amount - amount.rounded(.down)
        let travel = sin(progress * .pi * 6)
        let decay = 1 - progress
        return ProjectionTransform(CGAffineTransform(translationX: travel * 7 * decay, y: 0))
    }
}

extension View {
    func shake(on trigger: some Equatable) -> some View {
        modifier(ShakeOnChange(trigger: AnyHashableEquatable(trigger)))
    }
}

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
