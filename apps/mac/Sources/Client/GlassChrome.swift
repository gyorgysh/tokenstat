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
///
/// Glass button styles and the floating tab bar exist from iOS 26. Below
/// that, chrome falls back to the same Theme capsules the Mac already
/// uses: content stays opaque, accent stays one colour.
extension View {
    /// A content card: opaque panel, hairline, card radius.
    func cardSurface() -> some View {
        background(Theme.panel, in: .rect(cornerRadius: Theme.cardRadius))
            .overlay {
                RoundedRectangle(cornerRadius: Theme.cardRadius)
                    .strokeBorder(Theme.border, lineWidth: 1)
            }
    }

    /// Primary action. Liquid glass on iOS 26, brand capsule below.
    @ViewBuilder
    func clientProminentStyle() -> some View {
        if #available(iOS 26, *) {
            buttonStyle(.glassProminent)
        } else {
            buttonStyle(ClientProminentButtonStyle())
        }
    }

    /// Secondary chrome action. Liquid glass on iOS 26, quiet capsule below.
    @ViewBuilder
    func clientGlassStyle() -> some View {
        if #available(iOS 26, *) {
            buttonStyle(.glass)
        } else {
            buttonStyle(ClientQuietButtonStyle())
        }
    }

    /// Size the first-run intro when it is presented as a sheet.
    ///
    /// `.form` is the platform's own card: readable width, centred, and it
    /// tracks whatever the system decides that is on a given iPad rather than
    /// a number written down here. iOS 17 has no such modifier and gets the
    /// default sheet, which on an iPad is already a centred card.
    @ViewBuilder
    func clientIntroSheetSizing() -> some View {
        if #available(iOS 18, *) {
            presentationSizing(.form)
        } else {
            self
        }
    }

    /// Hide the iOS 26 scroll-edge fade. Older systems never drew it.
    ///
    /// Pass the edges that already have something drawing them. A scroll view
    /// that ends against a bar of our own gets two treatments stacked at that
    /// edge, and only that edge is worth hiding: the one that runs under the
    /// navigation bar is the system doing the job we would otherwise fake.
    @ViewBuilder
    func clientHideScrollEdgeEffect(for edges: Edge.Set = .all) -> some View {
        if #available(iOS 26, *) {
            scrollEdgeEffectHidden(true, for: edges)
        } else {
            self
        }
    }

    /// A navigation bar that reads as a bar on systems without Liquid Glass.
    ///
    /// iOS 26 draws the bar itself and Apple asks for no custom background
    /// there, because a custom one replaces the glass with a flat blur and
    /// takes the scroll-edge behaviour with it. Below 26 nothing is drawn at
    /// all, and content scrolling under a bare bar is unreadable, so those
    /// systems keep the material they always had.
    @ViewBuilder
    func clientNavigationBarBackground() -> some View {
        if #available(iOS 26, *) {
            self
        } else {
            toolbarBackground(.ultraThinMaterial, for: .navigationBar)
                .toolbarBackground(.visible, for: .navigationBar)
        }
    }

    /// A bar that floats over opaque content. Glass on iOS 26, a panel
    /// with a hairline below that. The transcript stays solid.
    @ViewBuilder
    func clientFloatingBar(cornerRadius: CGFloat = 22) -> some View {
        if #available(iOS 26, *) {
            glassEffect(
                .regular,
                in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
            )
        } else {
            background(Theme.panel)
                .overlay(alignment: .top) {
                    Rectangle().fill(Theme.border).frame(height: 1)
                }
        }
    }
}

/// Section title with the same FeatureMark cards use on the Mac.
struct ClientSectionTitle: View {
    let title: String
    let mark: String
    var tint: Color = Theme.accent

    var body: some View {
        HStack(spacing: Theme.Space.s) {
            FeatureMark(name: mark, tint: tint, size: 22)
            Text(title)
                .font(ClientType.sectionTitle)
        }
    }
}

/// Full-width primary button for phones that do not have glass chrome.
private struct ClientProminentButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(ClientType.label.weight(.semibold))
            .foregroundStyle(.white)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 14)
            .background(
                Theme.accent.opacity(configuration.isPressed ? 0.78 : 1),
                in: RoundedRectangle(cornerRadius: 14, style: .continuous)
            )
            .opacity(configuration.isPressed ? 0.92 : 1)
    }
}

/// Quiet capsule for secondary actions on older iOS.
private struct ClientQuietButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(ClientType.label.weight(.semibold))
            .foregroundStyle(Theme.accent)
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .background(
                Theme.accentSoft.opacity(configuration.isPressed ? 0.7 : 1),
                in: RoundedRectangle(cornerRadius: 12, style: .continuous)
            )
    }
}

#endif
