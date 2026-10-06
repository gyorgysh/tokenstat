// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
import SwiftUI
import WidgetKit

/// The same 12-wide bars, 15-unit pitch and 18/30/42 heights as LogoMark.
/// A symbol asset also makes the mark available to system control labels.
struct TokenstatWidgetMark: View {
    var size: CGFloat = 18
    var decorative = true
    var fullColor = false
    var body: some View {
        Image(fullColor ? "tokenstat_brand_mark" : "tokenstat_logo")
            .renderingMode(fullColor ? .original : .template)
            .resizable().scaledToFit()
            .frame(width: size, height: size)
            .widgetAccentable(!fullColor)
            .accessibilityHidden(decorative)
    }
}
