// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
//
// Source-available for review, NOT open source. See LICENSE: no rights to
// redistribute, publish, or ship a build are granted. Read it, study it, run
// your own build of it.
// "tokenstat" is a trademark of pueev OU. See TRADEMARK.md.

#if os(macOS)
import AppKit
import SwiftUI

/// The About window: app identity, version, who made it, and where to reach
/// them, over the licence line.
///
/// A window rather than AppKit's standard about panel. The standard panel can
/// show an icon, a version and a copyright string and nothing else, and the
/// three things a person actually wants from About here (what this is, who
/// stands behind it, how to reach them) are exactly what it has no room for.
struct AboutView: View {
    /// The author photo ships as a loose PNG resource next to the assets.
    private static let avatar = Bundle.main.image(forResource: "AuthorAvatar")

    var body: some View {
        VStack(spacing: Theme.Space.m) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .frame(width: 72, height: 72)
                .padding(.top, Theme.Space.xs)

            VStack(spacing: Theme.Space.xs) {
                Text("tokenstat")
                    .font(.title.bold())
                Text("Version \(AppInfo.versionString)")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            Text("Token usage and spend from every AI coding agent on this Mac, read locally.")
                .font(.callout)
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Divider()
                .padding(.vertical, 2)

            author

            links

            VStack(spacing: 2) {
                Text("Source-available licence")
                Text(AppInfo.copyright)
            }
            .font(.caption)
            .foregroundStyle(.tertiary)
            .multilineTextAlignment(.center)
        }
        .padding(28)
        .frame(width: 380)
        .tint(Theme.accent)
        .background(Theme.background)
    }

    /// Photo, credit line, name, and what the author does.
    private var author: some View {
        HStack(spacing: Theme.Space.m) {
            if let avatar = Self.avatar {
                Image(nsImage: avatar)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .frame(width: 56, height: 56)
                    .clipShape(Circle())
                    .overlay(Circle().strokeBorder(Theme.border, lineWidth: 1))
            }

            VStack(alignment: .leading, spacing: 1) {
                Text("Made by")
                    .font(.callout)
                Link(AppInfo.Author.name, destination: AppInfo.Author.site)
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(Theme.accent)
                Text(AppInfo.Author.role)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    /// Mail, the product site, and the source, separated by hairlines.
    private var links: some View {
        HStack(spacing: Theme.Space.s) {
            linkItem("Contact", symbol: "envelope", destination: AppInfo.Author.email)
            separator
            linkItem(AppInfo.websiteLabel, symbol: "globe", destination: AppInfo.website)
            separator
            linkItem(
                "Source",
                symbol: "chevron.left.forwardslash.chevron.right",
                destination: AppInfo.repository
            )
        }
        .font(.callout)
    }

    private var separator: some View {
        Text(verbatim: "|")
            .foregroundStyle(.quaternary)
    }

    private func linkItem(_ title: String, symbol: String, destination: URL) -> some View {
        // The brand accent rather than the system link blue. A window this
        // small is nearly all links, and three runs of system blue in it read
        // as a web page rather than as part of the app.
        Link(destination: destination) {
            Label(title, systemImage: symbol)
                .labelStyle(.titleAndIcon)
        }
        .foregroundStyle(Theme.accent)
    }
}
#endif
