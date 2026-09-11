// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
import SwiftUI

/// A distribution's own mark on a tinted tile, or a neutral server glyph.
///
/// Never an invented initial: see TRADEMARK.md. Each bundled mark is a
/// Simple Icons rendition (CC0) of the distribution's own logo, used only to
/// identify the OS the host itself reported. Anything without a bundled mark
/// gets the system server glyph, because a wrong logo is worse than no logo.
struct SSHHostPlatformMark: View {
    let label: String?
    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 9).fill(Theme.accentSoft)
            if let asset = distroBrandAsset(label) {
                Image(asset)
                    .renderingMode(.template)
                    .resizable()
                    .scaledToFit()
                    .frame(width: 19, height: 19)
            } else {
                Image(systemName: "server.rack").font(Theme.font(16))
            }
        }
        .foregroundStyle(Theme.accent)
        .frame(width: 34, height: 34)
        .accessibilityLabel(label ?? "Server; platform not checked")
        .help(label ?? "Platform appears after a server check")
    }
}
