// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
//
// Source-available for review, NOT open source. See LICENSE: no rights to
// redistribute, publish, or ship a build are granted. Read it, study it, run
// your own build of it.
// "tokenstat" is a trademark of pueev OU. See TRADEMARK.md.

import SwiftUI

/// The one thing an update asks of a person: restart when you are ready.
///
/// It sits above the account row rather than arriving as a sheet, because a
/// sheet interrupts and this does not need to. The new version is already on
/// disk by the time this appears, so the card is not a request to go and get
/// something, it is a switch that has been left within reach.
///
/// Nothing here appears while the update is being found or fetched. Somebody
/// who never restarts should never learn that any of that happened.
struct UpdateCard: View {
    var update: AppUpdateModel

    @Environment(\.openURL) private var openURL

    var body: some View {
        if update.isReady {
            row(
                title: "Relaunch to update",
                subtitle: "v\(update.latest)",
                symbol: "arrow.triangle.2.circlepath"
            ) {
                update.relaunch()
            }
        } else if update.failure != nil, update.isAvailable {
            // The automatic path did not work. Rather than say so in an error
            // somebody has to interpret, offer the version of this that always
            // works: the download page.
            row(
                title: "Update by hand",
                subtitle: "v\(update.latest) could not install itself",
                symbol: "arrow.down.circle"
            ) {
                if let url = update.downloadURL { openURL(url) }
            }
        }
    }

    private func row(
        title: String,
        subtitle: String,
        symbol: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: Theme.Space.s) {
                Image(systemName: symbol)
                    .font(.system(size: 15))
                    .foregroundStyle(Theme.accent)
                VStack(alignment: .leading, spacing: 1) {
                    Text(title)
                        .font(.callout.weight(.medium))
                        .foregroundStyle(.primary)
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer(minLength: Theme.Space.s)
                Image(systemName: "arrow.right")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, Theme.Space.m)
            .padding(.vertical, Theme.Space.s)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Theme.panel, in: RoundedRectangle(cornerRadius: Theme.cardRadius))
            .overlay(
                RoundedRectangle(cornerRadius: Theme.cardRadius)
                    .strokeBorder(Theme.border, lineWidth: 1)
            )
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .padding(.horizontal, Theme.Space.s)
        .padding(.bottom, Theme.Space.s)
        .help(update.isReady
            ? "Start the new version. Anything unsaved in a terminal goes with it."
            : "Open the download page")
    }
}
