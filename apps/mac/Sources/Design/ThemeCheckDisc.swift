// SPDX-License-Identifier: LicenseRef-tokenstat-source-available

import SwiftUI

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
