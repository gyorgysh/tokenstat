// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
//
// Source-available for review, NOT open source. See LICENSE.

import SwiftUI

/// The offline stretch as a card above the sync card, in the same visual
/// language: warning tint, one-line title, one-line subtitle. The subtitle
/// names the retry cadence so "why is this still here" has an answer.
struct OfflineCard: View {
    var connectivity: ConnectivityModel
    /// The other two things that can be wrong. Optional so a caller that has
    /// no connection model still gets the offline card it always had.
    var connection: ConnectionModel?

    var body: some View {
        if connectivity.isOffline {
            HStack(spacing: Theme.Space.s) {
                Image(systemName: "wifi.slash")
                    .font(Theme.font(15))
                    .foregroundStyle(Theme.warning)
                    .frame(width: 18)
                VStack(alignment: .leading, spacing: 1) {
                    Text("Offline")
                        .font(Theme.callout.weight(.medium))
                        .foregroundStyle(.primary)
                    Text("Retrying every \(Self.retrySeconds) seconds")
                        .font(Theme.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
                Spacer(minLength: Theme.Space.s)
                Button("Try now", .refresh) {
                    Task { await connectivity.checkNow() }
                }
                .buttonStyle(.borderless)
                .font(Theme.caption.weight(.medium))
                .foregroundStyle(Theme.accent)
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
        } else if let connection, connection.severity != .ok {
            // Online, and something else is not answering: the service, or a
            // machine that is not on the tunnel. Same card, same language, so
            // the two are not learned as different kinds of news.
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
                Button("Try now", .refresh) {
                    connectivity.checkNow()
                    connection.reset()
                }
                .buttonStyle(.borderless)
                .font(Theme.caption.weight(.medium))
                .foregroundStyle(Theme.accent)
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
