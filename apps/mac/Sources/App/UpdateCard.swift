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
            // The automatic path did not work. Two ways forward, both in front
            // of the person: retry the install here, or take the download page
            // that always works.
            failedCard
        } else if update.isRetrying {
            status(
                title: "Trying again…",
                subtitle: "Re-downloading v\(update.latest)",
                symbol: "arrow.triangle.2.circlepath",
                tint: Theme.accent,
                spinner: true
            )
        } else if update.checkNotice == AppUpdateModel.upToDateMessage {
            // A manual check that found nothing is a confirmation, not a
            // non-event, so it gets the same card treatment as the other
            // update states rather than a flat caption.
            status(
                title: "Up to date",
                subtitle: "v\(update.current)",
                symbol: "checkmark.seal.fill",
                // Brand purple, not a generic success green: this is a
                // tokenstat confirmation, not a system-level one.
                tint: Theme.accent
            )
        }
    }

    /// A non-interactive confirmation row, for states that have no action.
    private func status(
        title: String,
        subtitle: String,
        symbol: String,
        tint: Color,
        spinner: Bool = false
    ) -> some View {
        HStack(spacing: Theme.Space.s) {
            Group {
                if spinner {
                    ProgressView()
                        .controlSize(.small)
                        .tint(tint)
                } else {
                    Image(systemName: symbol)
                        .font(.system(size: 15))
                }
            }
            .foregroundStyle(tint)
            .frame(width: 18)
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
        }
        .padding(.horizontal, Theme.Space.m)
        .padding(.vertical, Theme.Space.s)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.panel, in: RoundedRectangle(cornerRadius: Theme.cardRadius))
        .overlay(
            RoundedRectangle(cornerRadius: Theme.cardRadius)
                .strokeBorder(tint.opacity(0.35), lineWidth: 1)
        )
        .padding(.horizontal, Theme.Space.s)
        .padding(.bottom, Theme.Space.s)
    }

    /// The automatic install failed: retry it here, or go get it by hand.
    ///
    /// Two buttons rather than one "Update by hand" row, because a person who
    /// pressed nothing and still got an update that failed deserves a way to
    /// try the automatic path again without leaving the app.
    private var failedCard: some View {
        VStack(alignment: .leading, spacing: Theme.Space.s) {
            HStack(spacing: Theme.Space.s) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 15))
                    .foregroundStyle(Theme.warning)
                VStack(alignment: .leading, spacing: 1) {
                    Text("Update didn't finish")
                        .font(.callout.weight(.medium))
                        .foregroundStyle(.primary)
                    Text("v\(update.latest) could not install itself")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
                Spacer(minLength: Theme.Space.s)
            }
            HStack(spacing: Theme.Space.s) {
                Button {
                    Task { await update.retry() }
                } label: {
                    Label("Retry", systemImage: "arrow.clockwise")
                }
                .buttonStyle(AccentButtonStyle(small: true))
                .help("Try the automatic install again")

                Button {
                    if let url = update.downloadURL { openURL(url) }
                } label: {
                    Label("Manual", systemImage: "arrow.down.circle")
                }
                .buttonStyle(SecondaryButtonStyle(small: true))
                .disabled(update.downloadURL == nil)
                .help("Open the download page and install by hand")
            }
        }
        .padding(.horizontal, Theme.Space.m)
        .padding(.vertical, Theme.Space.s)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.panel, in: RoundedRectangle(cornerRadius: Theme.cardRadius))
        .overlay(
            RoundedRectangle(cornerRadius: Theme.cardRadius)
                .strokeBorder(Theme.warning.opacity(0.35), lineWidth: 1)
        )
        .padding(.horizontal, Theme.Space.s)
        .padding(.bottom, Theme.Space.s)
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
