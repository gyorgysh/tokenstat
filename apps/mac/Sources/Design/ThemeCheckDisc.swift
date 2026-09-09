// SPDX-License-Identifier: LicenseRef-tokenstat-source-available

import SwiftUI

/// A check that wears the theme, not the platform default.
///
/// A `Toggle` left untinted draws the system blue, and a blue control in this
/// app reads as a control from another app. This disc is accent-filled with a
/// white check when on, and a quiet ring when off. The whole row is the tap
/// target; the disc itself never handles the touch.
struct ThemeCheckDisc: View {
    var on: Bool

    var body: some View {
        ZStack {
            Circle()
                .fill(on ? Theme.accent : Color.clear)
                .frame(width: 26, height: 26)
                .overlay(
                    Circle()
                        .strokeBorder(on ? Theme.accent : Color.secondary.opacity(0.4), lineWidth: 1.5)
                )
            if on {
                Image(systemName: "checkmark")
                    .font(Theme.font(12, weight: .bold))
                    .foregroundStyle(.white)
            }
        }
        .accessibilityHidden(true)
    }
}
