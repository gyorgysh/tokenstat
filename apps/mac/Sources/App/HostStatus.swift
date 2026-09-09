// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
//
// Source-available for review, NOT open source. See LICENSE: no rights to
// redistribute, publish, or ship a build are granted. Read it, study it, run
// your own build of it.

import Combine
import SwiftUI

#if os(macOS)

/// The host's transient state belongs beside sync and update, not in a modal
/// alert. A successful call removes it automatically.
///
/// A network flap used to raise "Could not start session" every time the
/// background session list timed out waiting on a tunnel redial. That is not
/// a launch, and it is not something a person can dismiss into being fixed.
struct HostStatusCard: View {
    @State private var isRecovering = false
    @State private var issue: Issue?

    private enum Issue: Equatable {
        case silent
        case down
    }

    var body: some View {
        Group {
            if isRecovering {
                status(
                    title: "Reconnecting to tokenstat",
                    subtitle: "The local helper is retrying in the background",
                    spinner: true
                )
            } else if issue == .silent {
                status(
                    title: "Host is quiet",
                    subtitle: "The local helper did not answer. Retrying in the background."
                )
            } else if issue == .down {
                status(
                    title: "Host is not answering",
                    subtitle: "tokenstat tried to restart it and will keep retrying."
                )
            }
        }
        .onReceive(signal(.hostRecoveryStarted)) { _ in
            isRecovering = true
            issue = nil
        }
        .onReceive(signal(.hostRecoveryFinished)) { _ in
            isRecovering = false
            issue = nil
        }
        .onReceive(signal(.hostBecameSilent)) { _ in
            guard !isRecovering else { return }
            issue = .silent
        }
        .onReceive(signal(.hostBecameUnreachable)) { _ in
            isRecovering = false
            issue = .down
        }
    }

    /// The host's own notifications, on the thread this card is drawn on.
    ///
    /// `NotificationCenter` delivers on whichever thread posted, and these
    /// four are raised by the bridge from its call queue. `Bridge` hops to
    /// the main thread before posting; this is the same rule stated on the
    /// side that would be damaged if it ever stopped doing so. Writing
    /// `@State` off the main thread hung the app for ten minutes once.
    private func signal(_ name: Notification.Name) -> AnyPublisher<Notification, Never> {
        NotificationCenter.default
            .publisher(for: name)
            .receive(on: DispatchQueue.main)
            .eraseToAnyPublisher()
    }

    private func status(title: String, subtitle: String, spinner: Bool = false) -> some View {
        HStack(spacing: Theme.Space.s) {
            Group {
                if spinner {
                    ProgressView()
                        .controlSize(.small)
                        .tint(Theme.warning)
                } else {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(Theme.fixed(15))
                }
            }
            .foregroundStyle(Theme.warning)
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
                .strokeBorder(Theme.warning.opacity(0.35), lineWidth: 1)
        )
        .padding(.horizontal, Theme.Space.s)
        .padding(.bottom, Theme.Space.s)
    }
}

#endif
