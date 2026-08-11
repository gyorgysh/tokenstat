// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
//
// Source-available for review, NOT open source. See LICENSE: no rights to
// redistribute, publish, or ship a build are granted. Read it, study it, run
// your own build of it.
// "tokenstat" is a trademark of pueev OU. See TRADEMARK.md.

import SwiftUI

// The client is iOS and iPadOS only.
#if !os(macOS)

/// Surfaces the client shares, in one file so the rule is visible in one place.
///
/// **Glass is chrome, content is opaque.** The tab bar, the top bar and sheets
/// float on glass, which the system draws. A card holding numbers sits on a
/// solid panel colour with a hairline. `Theme` already argues this for the Mac,
/// and it is more true at 402 points wide: vibrancy pulls whatever scrolls
/// behind a card into the digits on it.
///
/// So there is deliberately almost no custom glass here. Two glass surfaces
/// overlapping is a bug, and the fastest way to get one is to add glass the
/// system was already going to provide.
extension View {
    /// A content card: opaque panel, hairline, card radius.
    func cardSurface() -> some View {
        background(Theme.panel, in: .rect(cornerRadius: Theme.cardRadius))
            .overlay {
                RoundedRectangle(cornerRadius: Theme.cardRadius)
                    .strokeBorder(Theme.border, lineWidth: 1)
            }
    }
}

#endif
