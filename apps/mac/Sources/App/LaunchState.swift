// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
//
// Source-available for review, NOT open source. See LICENSE: no rights to
// redistribute, publish, or ship a build are granted. Read it, study it, run
// your own build of it.
// "tokenstat" is a trademark of pueev OU. See TRADEMARK.md.

import Foundation
import Observation
import SwiftUI

/// App-wide launch gate: logo splash until the host is answering, then the
/// real window (wireframes → data).
///
/// Three beats, on purpose:
/// 1. **Splash** — animated mark while launchd / the socket comes up.
/// 2. **Wireframes** — Home (and peers) draw sharp skeletons with a light pulse.
/// 3. **Content** — numbers replace skeletons with a short fade.
///
/// Collapsing those into one blurred pane made the wait feel longer than it
/// was. Separating them lets each phase finish cleanly.
@MainActor
@Observable
final class LaunchState {
    /// False until the host has answered at least once (or we give up waiting).
    private(set) var hostReady = false

    /// Shortest the splash stays on screen, so a hot host is not a one-frame flash.
    private static let minimumSplash: Duration = .milliseconds(480)

    /// Longest we wait for the host before showing the app over in-process.
    private static let hostDeadline: Duration = .seconds(8)

    /// Bring the host up and prove it answers, then release the splash.
    func prepare() async {
        let started = ContinuousClock.now

        await Task.detached(priority: .userInitiated) {
            #if os(macOS)
            HostAgentInstaller.refreshIfStale()
            #endif
            Bridge.ensureHosted()
        }.value

        // Prove a real method answers, not only that a socket file exists.
        let deadline = ContinuousClock.now + Self.hostDeadline
        while ContinuousClock.now < deadline {
            if (try? await Bridge.info()) != nil {
                break
            }
            try? await Task.sleep(for: .milliseconds(80))
            guard !Task.isCancelled else { return }
        }

        let elapsed = ContinuousClock.now - started
        if elapsed < Self.minimumSplash {
            try? await Task.sleep(for: Self.minimumSplash - elapsed)
        }
        guard !Task.isCancelled else { return }

        withAnimation(.easeOut(duration: 0.32)) {
            hostReady = true
        }
    }
}

/// Full-window splash: brand mark only, no wireframe underneath.
struct LaunchSplashView: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ZStack {
            Theme.background
            VStack(spacing: Theme.Space.m) {
                LogoMark(size: 48, animated: !reduceMotion)
                Text("tokenstat")
                    .font(.system(size: 15, weight: .semibold))
                    .textCase(.lowercase)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Starting tokenstat")
    }
}
