// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
//
// Source-available: source sharing and own builds are permitted.
// Store and commercial distribution of builds is reserved. See LICENSE.
// "tokenstat" is a trademark of pueev OU. See TRADEMARK.md.

import SwiftUI

struct SyncCard: View {
    var account: AccountModel

    var body: some View {
        if account.isSyncing {
            status(
                title: L10n.text("apple.synccard.syncing.8a046cc9"),
                subtitle: L10n.text("apple.synccard.uploading_sealed_counters.127c8ba5"),
                symbol: "arrow.triangle.2.circlepath",
                tint: Theme.accent,
                spinner: true
            )
        } else if let notice = account.syncNotice, !account.syncNoticeDismissed {
            if account.isRateLimited {
                status(
                    title: L10n.text("apple.synccard.rate_limited.a06130a5"),
                    subtitle: notice,
                    symbol: "exclamationmark.triangle.fill",
                    tint: Theme.warning
                )
            } else if account.syncNoticeIsError {
                status(
                    title: L10n.text("apple.synccard.sync_failed.abf3e80b"),
                    subtitle: notice,
                    symbol: "xmark.circle.fill",
                    tint: Theme.danger
                )
            } else {
                status(
                    title: L10n.text("apple.synccard.synced_just_now.1326132c"),
                    subtitle: notice,
                    symbol: "checkmark.seal.fill",
                    tint: Theme.accent
                )
            }
        } else if account.isRateLimited && !account.syncNoticeDismissed {
            status(
                title: L10n.text("apple.synccard.rate_limited.a06130a5"),
                subtitle: L10n.text("apple.synccard.this_plan_allows_a_sync_every_few_minutes.3f3fb97d"),
                symbol: "exclamationmark.triangle.fill",
                tint: Theme.warning
            )
        }
    }

    private func status(
        title: String,
        subtitle: String,
        symbol: String,
        tint: Color,
        spinner: Bool = false
    ) -> some View {
        HStack(alignment: .top, spacing: Theme.Space.s) {
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
            if !spinner {
                NoticeDismissButton { account.dismissSyncNotice() }
            }
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
