// SPDX-License-Identifier: LicenseRef-tokenstat-source-available

import Observation
import SwiftUI

/// A feature a newer client can show only when the paired computer speaks the
/// host methods behind it.
///
/// Keep the version beside the feature rather than testing for an error after
/// loading it. `protocol` is present before either feature and gives a person a
/// useful update state instead of exposing an implementation error.
enum RemoteHostFeature {
    case chat
    case pulls

    var title: String {
        switch self {
        case .chat: "Chat"
        case .pulls: "Pull requests"
        }
    }

    /// Version 3 introduced the pull-request host methods. Version 4 added
    /// `chat.eventPage`, which the mobile transcript needs for older pages.
    var minimumProtocol: Int {
        switch self {
        case .chat: 4
        case .pulls: 3
        }
    }

    var symbol: String {
        switch self {
        case .chat: "bubble.left.and.bubble.right.fill"
        case .pulls: "arrow.triangle.merge"
        }
    }
}

/// Ask a paired computer whether it can serve one feature before that feature
/// begins loading. A transport error deliberately fails open, preserving the
/// screen's existing offline and retry behaviour. Only a definite older
/// protocol becomes the update state.
struct RemoteHostFeatureGate<Content: View>: View {
    let feature: RemoteHostFeature
    let peer: String?
    let hostName: String?
    @ViewBuilder let content: () -> Content

    @State private var probe = RemoteHostFeatureProbe()

    var body: some View {
        Group {
            if let peer, !peer.isEmpty {
                switch probe.state {
                case .available:
                    content()
                case .checking:
                    RemoteHostFeatureCheckingView(feature: feature)
                case let .needsUpdate(version):
                    RemoteHostFeatureUpdateView(
                        feature: feature,
                        hostName: hostName,
                        hostProtocol: version,
                        retry: { probe.retry &+= 1 }
                    )
                }
            } else {
                content()
            }
        }
        .task(id: "\(peer ?? "local")-\(probe.retry)") {
            guard let peer, !peer.isEmpty else {
                probe.state = .available
                return
            }
            // This view can be retained while the person changes the selected
            // computer. Do not let the previous host's answer expose a feature
            // while the next host is still being checked.
            probe.state = .checking
            do {
                let version = try await Bridge.peerProtocolVersion(peer)
                guard !Task.isCancelled else { return }
                probe.state = version >= feature.minimumProtocol ? .available : .needsUpdate(version)
            } catch {
                guard !Task.isCancelled else { return }
                // Reachability has its own UI. Turning an asleep host into an
                // "update" instruction sends somebody in the wrong direction.
                probe.state = .available
            }
        }
    }
}

@MainActor @Observable
private final class RemoteHostFeatureProbe {
    enum State: Equatable {
        case checking
        case available
        case needsUpdate(Int)
    }

    var state: State = .checking
    var retry = 0
}

private struct RemoteHostFeatureCheckingView: View {
    let feature: RemoteHostFeature

    var body: some View {
        VStack(spacing: Theme.Space.m) {
            ProgressView()
            Text("Checking \(feature.title) on this computer")
                .font(Theme.callout)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.background)
    }
}

/// The paired desktop has answered, but predates a feature on this client.
/// Reuse the app's living persona rather than a static warning mark: this is a
/// calm detour while the desktop update installs, not a broken connection.
private struct RemoteHostFeatureUpdateView: View {
    let feature: RemoteHostFeature
    let hostName: String?
    let hostProtocol: Int
    let retry: () -> Void

    private var computer: String {
        guard let hostName, !hostName.isEmpty else { return "this computer" }
        return hostName
    }

    var body: some View {
        VStack(spacing: Theme.Space.m) {
            Spacer(minLength: 0)
            ZStack {
                Circle()
                    .fill(Theme.accent.opacity(0.08))
                    .frame(width: 156, height: 156)
                Circle()
                    .stroke(Theme.accent.opacity(0.2), lineWidth: 1)
                    .frame(width: 118, height: 118)
                PersonaPastime(
                    seed: personaSeed(for: "\(computer)-\(feature.title)"),
                    size: 102,
                    doing: .thought
                )
                .frame(width: 132, height: 112)
                Image(systemName: feature.symbol)
                    .font(Theme.fixed(15, weight: .semibold))
                    .foregroundStyle(Theme.accent)
                    .padding(9)
                    .background(Theme.panel, in: Circle())
                    .overlay(Circle().stroke(Theme.border))
                    .offset(x: 58, y: 46)
            }
            Text("Update \(computer) to use \(feature.title)")
                .font(Theme.title3.weight(.semibold))
                .multilineTextAlignment(.center)
            Text("This device is ready, but \(computer) runs an older version of tokenstat. Update the desktop app, then check again.")
                .font(Theme.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 380)
            Button("Check again", .refresh) { retry() }
                .buttonStyle(AccentButtonStyle())
                .accessibilityHint("Checks whether the desktop update is ready")
            Text("Desktop protocol \(hostProtocol) needs \(feature.minimumProtocol) or later")
                .font(Theme.caption)
                .foregroundStyle(.tertiary)
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(Theme.Space.xl)
        .background(Theme.background)
    }
}
