// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
//
// Source-available for review, NOT open source. See LICENSE: no rights to
// redistribute, publish, or ship a build are granted. Read it, study it, run
// your own build of it.
// "tokenstat" is a trademark of pueev OU. See TRADEMARK.md.

import SwiftUI

/// Shared anatomy of an app-owned task sheet: header, body, optional footer.
///
/// SwiftUI owns the window radius, shadow, focus, Escape key and
/// accessibility. tokenstat owns every pixel inside that radius. The header
/// is not in-window chrome, so it does not use `chromeBarMetrics()`.
struct ThemedSheet<Content: View, Actions: View>: View {
    let title: String
    let subtitle: String
    let icon: ActionIcon?
    let scrolls: Bool
    let onClose: () -> Void
    @ViewBuilder let content: () -> Content
    @ViewBuilder let actions: () -> Actions

    init(
        title: String,
        subtitle: String,
        icon: ActionIcon? = nil,
        scrolls: Bool = false,
        onClose: @escaping () -> Void,
        @ViewBuilder content: @escaping () -> Content,
        @ViewBuilder actions: @escaping () -> Actions
    ) {
        self.title = title
        self.subtitle = subtitle
        self.icon = icon
        self.scrolls = scrolls
        self.onClose = onClose
        self.content = content
        self.actions = actions
    }

    var body: some View {
        VStack(spacing: 0) {
            ModalHeader(
                title: title,
                subtitle: subtitle,
                icon: icon,
                onClose: onClose
            )
            ThemeRule()
            bodyContent
            if showsFooter {
                ThemeRule()
                ModalFooter(actions: actions)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.background)
    }

    @ViewBuilder
    private var bodyContent: some View {
        if scrolls {
            ScrollView {
                content()
                    .padding(Theme.Space.l)
                    .frame(maxWidth: .infinity, alignment: .topLeading)
            }
        } else {
            content()
                .padding(Theme.Space.l)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
    }

    private var showsFooter: Bool {
        Actions.self != EmptyView.self
    }
}

extension ThemedSheet where Actions == EmptyView {
    init(
        title: String,
        subtitle: String,
        icon: ActionIcon? = nil,
        scrolls: Bool = false,
        onClose: @escaping () -> Void,
        @ViewBuilder content: @escaping () -> Content
    ) {
        self.init(
            title: title,
            subtitle: subtitle,
            icon: icon,
            scrolls: scrolls,
            onClose: onClose,
            content: content,
            actions: { EmptyView() }
        )
    }
}

/// Title, optional mark, and a close control that sits in the header rather
/// than against the window curve.
///
/// Large sheets that cannot use `ThemedSheet`'s generic body still share this
/// header so the top of every task window is the same object.
struct ModalHeader: View {
    let title: String
    let subtitle: String
    var icon: ActionIcon? = nil
    let onClose: () -> Void

    var body: some View {
        HStack(alignment: .center, spacing: Theme.Space.m) {
            if let icon {
                ActionSeat(icon: icon, size: Theme.Modal.iconSeat)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(Theme.title3.weight(.semibold))
                    .foregroundStyle(.primary)
                    .lineLimit(2)
                Text(subtitle)
                    .font(Theme.caption)
                    .foregroundStyle(Theme.controlGlyph)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            InspectorCloseButton(
                action: onClose,
                help: "Close",
                label: "Close \(title)"
            )
        }
        .padding(.horizontal, Theme.Space.l)
        .padding(.vertical, Theme.Space.m)
        .frame(minHeight: Theme.Modal.headerMinHeight)
        .frame(maxWidth: .infinity)
        .background {
            Theme.sidebar.ignoresSafeArea(edges: .top)
        }
        .accessibilityAddTraits(.isHeader)
    }
}

/// One row of actions, Cancel-shaped on the left and the primary action on
/// the right, on the same sidebar surface as the header.
struct ModalFooter<Actions: View>: View {
    @ViewBuilder var actions: () -> Actions

    var body: some View {
        HStack(spacing: Theme.Space.s) {
            actions()
        }
        .padding(.horizontal, Theme.Space.l)
        .frame(maxWidth: .infinity)
        .frame(height: Theme.Modal.footerHeight)
        .background {
            Theme.sidebar.ignoresSafeArea(edges: .bottom)
        }
    }
}

/// A short fact in a sheet body. A themed mark, not a numbered disc, so two
/// notes cannot be mistaken for a three-step wizard.
struct ModalInfoRow: View {
    let icon: ActionIcon
    let title: String
    let text: String

    var body: some View {
        HStack(alignment: .top, spacing: Theme.Space.m) {
            ActionSeat(icon: icon, size: 28)
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(Theme.callout.weight(.semibold))
                    .foregroundStyle(.primary)
                Text(text)
                    .font(Theme.caption)
                    .foregroundStyle(Theme.controlGlyph)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .accessibilityElement(children: .combine)
    }
}

extension View {
    /// Size a Mac task sheet and paint the window, including the rounded
    /// corners SwiftUI owns. iOS sheets keep their native detents.
    @ViewBuilder
    func modalFrame(width: CGFloat, height: CGFloat) -> some View {
        #if os(macOS)
        self
            .frame(width: width, height: height)
            .background(Theme.background)
            .presentationBackground(Theme.background)
        #else
        self
        #endif
    }
}
