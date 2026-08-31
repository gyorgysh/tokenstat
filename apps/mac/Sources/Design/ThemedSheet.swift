// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
//
// Source-available for review, NOT open source. See LICENSE: no rights to
// redistribute, publish, or ship a build are granted. Read it, study it, run
// your own build of it.
// "tokenstat" is a trademark of pueev OU. See TRADEMARK.md.

import SwiftUI

/// A sheet with the same deliberate surface and chrome as the rest of the app.
///
/// SwiftUI sheets otherwise start on a system material, then every caller has
/// to remember its own header rule, close mark, and action spacing. Keeping
/// those decisions here means an operation sheet feels like part of the
/// workspace it came from in both light and dark appearances.
struct ThemedSheet<Content: View, Actions: View>: View {
    let title: String
    let subtitle: String
    let icon: ActionIcon
    let onClose: () -> Void
    @ViewBuilder let content: () -> Content
    @ViewBuilder let actions: () -> Actions

    init(
        title: String,
        subtitle: String,
        icon: ActionIcon,
        onClose: @escaping () -> Void,
        @ViewBuilder content: @escaping () -> Content,
        @ViewBuilder actions: @escaping () -> Actions
    ) {
        self.title = title
        self.subtitle = subtitle
        self.icon = icon
        self.onClose = onClose
        self.content = content
        self.actions = actions
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: Theme.Space.m) {
                Image(systemName: icon.symbol)
                    .font(Theme.font(18, weight: .semibold))
                    .foregroundStyle(Theme.accent)
                    .frame(width: 30, height: 30)
                    .background(Theme.accentSoft, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(Theme.title3.weight(.semibold))
                    Text(subtitle)
                        .font(Theme.caption)
                        .foregroundStyle(Theme.controlGlyph)
                }
                Spacer(minLength: 0)
                InspectorCloseButton(
                    action: onClose,
                    help: "Close",
                    label: "Close \(title.lowercased())"
                )
            }
            .padding(.horizontal, Theme.Space.l)
            .chromeBarMetrics()
            .background(Theme.sidebar)

            ThemeRule()

            content()
                .padding(Theme.Space.l)
                // This is the flexible region. It takes the spare height so
                // the header stays against the rounded top and the action row
                // stays against the rounded bottom instead of the whole stack
                // floating in the vertical centre of the sheet window.
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)

            ThemeRule()

            HStack(spacing: Theme.Space.s) {
                actions()
            }
            .padding(.horizontal, Theme.Space.l)
            .padding(.vertical, Theme.Space.m)
            .frame(maxWidth: .infinity)
            .background(Theme.sidebar)
        }
        // The caller chooses the sheet's final size. Fill that proposal before
        // painting the surface so every pixel belongs to the app's palette.
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.background)
    }
}
