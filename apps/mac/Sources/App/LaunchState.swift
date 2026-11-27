// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
//
// Source-available: source sharing and own builds are permitted.
// Store and commercial distribution of builds is reserved. See LICENSE.
// "tokenstat" is a trademark of pueev OU. See TRADEMARK.md.

import Foundation
import Observation
import SwiftUI

/// App-wide launch gate: logo splash until the host is answering, then the
/// real window (wireframes → data).
///
/// Three beats, on purpose:
/// 1. **Splash** — mark only, full window, while launchd / the socket comes up.
/// 2. **Wireframes** — Home draws pulsing skeletons while the archive answers.
/// 3. **Content** — numbers replace skeletons with a short fade.
@MainActor
@Observable
final class LaunchState {
    private(set) var hostReady = false

    private static let minimumSplash: Duration = .milliseconds(560)

    private static let hostDeadline: Duration = .seconds(8)

    func prepare() async {
        let started = ContinuousClock.now

        await BridgeLaunch.wait()

        await Task.detached(priority: .userInitiated) {
            #if os(macOS)
            HostAgentInstaller.refreshIfStale()
            #endif
            Bridge.ensureHosted()
        }.value

        let deadline = ContinuousClock.now + Self.hostDeadline
        while ContinuousClock.now < deadline {
            if await Bridge.hostSettled() {
                break
            }
            try? await Task.sleep(for: .milliseconds(80))
            guard !Task.isCancelled else { return }
        }

        #if os(macOS)
        if let policy = try? await Bridge.hostPolicy() {
            try? HostAgentInstaller.applyPolicy(alwaysOn: policy.alwaysOn)
            let again = ContinuousClock.now + .seconds(4)
            while ContinuousClock.now < again {
                if await Bridge.hostSettled() { break }
                try? await Task.sleep(for: .milliseconds(80))
                guard !Task.isCancelled else { return }
            }
        }
        #endif

        let elapsed = ContinuousClock.now - started
        if elapsed < Self.minimumSplash {
            try? await Task.sleep(for: Self.minimumSplash - elapsed)
        }
        guard !Task.isCancelled else { return }

        // Inserting NavigationSplitView under an animation is what macOS 27
        // aborts on: the hosted column reports a new min/max during the same
        // Update Constraints pass, and AppKit calls abort(). withAnimation(nil)
        // also blocks an ambient transaction from a parent.
        withAnimation(nil) {
            hostReady = true
        }
    }
}

struct LaunchSplashView: View {
    var isFullScreen = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ZStack {
            #if os(macOS)
            if #available(macOS 26, *) {
                SidebarGlassSurface(isFullScreen: isFullScreen, cornerRadius: 0)
                    .ignoresSafeArea()
            } else {
                Theme.sidebar.ignoresSafeArea()
            }
            #else
            Theme.background.ignoresSafeArea()
            #endif
            LogoMark(size: 44, animated: !reduceMotion)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .ignoresSafeArea()
        .accessibilityElement(children: .combine)
        .accessibilityLabel(L10n.text("apple.launchstate.starting_tokenstat.b284c345"))
    }
}

private struct HostReadyKey: EnvironmentKey {
    static let defaultValue = true
}

extension EnvironmentValues {
    var hostReady: Bool {
        get { self[HostReadyKey.self] }
        set { self[HostReadyKey.self] = newValue }
    }
}
