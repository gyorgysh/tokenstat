// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
import SwiftUI
import WidgetKit

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
