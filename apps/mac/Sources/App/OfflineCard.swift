// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
//
// Source-available for review, NOT open source. See LICENSE.

import SwiftUI

/// The offline stretch as a card above the sync card, in the same visual
/// language: warning tint, one-line title, one-line subtitle. The subtitle
/// names the retry cadence so "why is this still here" has an answer.
struct OfflineCard: View {
    var connectivity: ConnectivityModel

    var body: some View {
        if connectivity.isOffline {
            HStack(spacing: Theme.Space.s) {
                Image(systemName: "wifi.slash")
                    .font(.system(size: 15))
                    .foregroundStyle(Theme.warning)
                    .frame(width: 18)
                VStack(alignment: .leading, spacing: 1) {
                    Text("Offline")
                        .font(.callout.weight(.medium))
                        .foregroundStyle(.primary)
                    Text("Retrying every \(Self.retrySeconds) seconds")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
                Spacer(minLength: Theme.Space.s)
                Button("Try now") {
                    Task { await connectivity.checkNow() }
                }
                .buttonStyle(.borderless)
                .font(.caption.weight(.medium))
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
