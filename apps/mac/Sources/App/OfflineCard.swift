// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
//
// Source-available, not open source. See LICENSE for permissions and restrictions.

import SwiftUI

struct OfflineCard: View {
    var connectivity: ConnectivityModel
    var connection: ConnectionModel?

    var body: some View {
        if connectivity.isOffline, !connectivity.offlineDismissed {
            HStack(spacing: Theme.Space.s) {
                Image(systemName: "wifi.slash")
                    .font(Theme.font(15))
                    .foregroundStyle(Theme.warning)
                    .frame(width: 18)
                VStack(alignment: .leading, spacing: 1) {
                    Text(L10n.text("common.offline"))
                        .font(Theme.callout.weight(.medium))
                        .foregroundStyle(.primary)
                    Text(L10n.text("apple.offlinecard.retrying_every_0_seconds.cacf655a", "\(Self.retrySeconds)"))
                        .font(Theme.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
                Spacer(minLength: Theme.Space.s)
                HStack(spacing: Theme.Space.xs) {
                    Button(L10n.text("apple.offlinecard.try_now.549f5e23"), .refresh) {
                        connectivity.checkNow()
                    }
                    .buttonStyle(.borderless)
                    .font(Theme.caption.weight(.medium))
                    .foregroundStyle(Theme.accent)
                    NoticeDismissButton { connectivity.dismissOffline() }
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
        } else if let connection, connection.severity != .ok, !connection.isDismissed {
            HStack(spacing: Theme.Space.s) {
                Image(systemName: connection.serviceFailing
                    ? "exclamationmark.icloud"
                    : "laptopcomputer.slash")
                    .font(Theme.font(15))
                    .foregroundStyle(Theme.warning)
                    .frame(width: 18)
                VStack(alignment: .leading, spacing: 1) {
                    Text(connection.title)
                        .font(Theme.callout.weight(.medium))
                        .foregroundStyle(.primary)
                    Text(connection.detail)
                        .font(Theme.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(3)
                }
                Spacer(minLength: Theme.Space.s)
                HStack(spacing: Theme.Space.xs) {
                    Button(L10n.text("apple.offlinecard.try_now.549f5e23"), .refresh) {
                        connectivity.checkNow()
                        connection.reset()
                    }
                    .buttonStyle(.borderless)
                    .font(Theme.caption.weight(.medium))
                    .foregroundStyle(Theme.accent)
                    NoticeDismissButton { connection.dismiss() }
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
    }

    private static var retrySeconds: Int {
        Int(ConnectivityModel.retryInterval.components.seconds)
    }
}
