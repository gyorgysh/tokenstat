// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
import SwiftUI

/// A product-owned vector mark for a feature surface.
struct FeatureMark: View {
    var name: String
    var tint: Color = Theme.accent
    var size: CGFloat = 18

    var body: some View {
        Image(name)
            .renderingMode(.template)
            .resizable().scaledToFit()
            .frame(width: size * 0.62, height: size * 0.62)
            .foregroundStyle(tint)
            .frame(width: size, height: size)
            .background(tint.opacity(0.12), in: RoundedRectangle(cornerRadius: size * 0.28))
    }
}
