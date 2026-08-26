// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
//
// Source-available for review, NOT open source. See LICENSE: no rights to
// redistribute, publish, or ship a build are granted. Read it, study it, run
// your own build of it.
// "tokenstat" is a trademark of pueev OU. See TRADEMARK.md.

import SwiftUI

/// The outcome of the last sync, as a card above the account row.
///
/// The update card lives in the same slot and the two are drawn with the same
/// shapes on purpose: a sync that worked is a confirmation like an update
/// check, and one that was refused by the plan gate is a warning like an
/// update that could not install itself. Success is the accent, rate limiting
/// is amber, a real failure is red, and all three are the same card so the
/// footer reads as one language instead of a caption plus a card.
///
/// A success also starts a button cooldown so a second press is not sent
/// into the same gate. That cooldown is not a rate limit, and this card
/// must not say it is.
struct SyncCard: View {
    var account: AccountModel

    var body: some View {
        if account.isSyncing {
            status(
                title: "Syncing…",
                subtitle: "Uploading sealed counters",
                symbol: "arrow.triangle.2.circlepath",
                tint: Theme.accent,
                spinner: true
            )
        } else if let notice = account.syncNotice {
            if account.isRateLimited {
                status(
                    title: "Rate limited",
                    subtitle: notice,
                    symbol: "exclamationmark.triangle.fill",
                    tint: Theme.warning
                )
            } else if account.syncNoticeIsError {
                status(
                    title: "Sync failed",
                    subtitle: notice,
                    symbol: "xmark.circle.fill",
                    tint: Theme.danger
                )
            } else {
                status(
                    title: "Synced just now",
                    subtitle: notice,
                    symbol: "checkmark.seal.fill",
                    tint: Theme.accent
                )
            }
        } else if account.isRateLimited {
            // The 429 notice has faded, but the gate is still shut. Keep the
            // warning until the remembered wait elapses. A success cooldown
            // does not come through here.
            status(
                title: "Rate limited",
                subtitle: "This plan allows a sync every few minutes. Try again shortly.",
                symbol: "exclamationmark.triangle.fill",
                tint: Theme.warning
            )
        }
    }

    /// A non-interactive confirmation row, matching `UpdateCard.status`.
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
                        .font(Theme.fixed(15))
                }
            }
            .foregroundStyle(tint)
            .frame(width: 18)
            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .font(Theme.callout.weight(.medium))
                    .foregroundStyle(.primary)
                Text(subtitle)
                    .font(Theme.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
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
}
