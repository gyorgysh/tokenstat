// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
//
// Source-available for review, NOT open source. See LICENSE: no rights to
// redistribute, publish, or ship a build are granted. Read it, study it, run
// your own build of it.

import SwiftUI

#if os(macOS)

/// The host's transient recovery state belongs beside sync and update, not in a
/// screen-sized error banner. A successful retry removes it automatically.
struct HostStatusCard: View {
    @State private var isRecovering = false

    var body: some View {
        Group {
            if isRecovering {
                HStack(spacing: Theme.Space.s) {
                    ProgressView()
                        .controlSize(.small)
                        .tint(Theme.warning)
                        .frame(width: 18)
                    VStack(alignment: .leading, spacing: 1) {
                        Text("Reconnecting to tokenstat")
                            .font(.callout.weight(.medium))
                            .foregroundStyle(.primary)
                        Text("The local helper is retrying in the background")
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
                        .strokeBorder(Theme.warning.opacity(0.35), lineWidth: 1)
                )
                .padding(.horizontal, Theme.Space.s)
                .padding(.bottom, Theme.Space.s)
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .hostRecoveryStarted)) { _ in
            isRecovering = true
        }
        .onReceive(NotificationCenter.default.publisher(for: .hostRecoveryFinished)) { _ in
            isRecovering = false
        }
    }
}

#endif
