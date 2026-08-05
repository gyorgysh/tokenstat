// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
//
// Source-available for review, NOT open source. See LICENSE: no rights to
// redistribute, publish, or ship a build are granted.

import Foundation

/// Keeps an in-process app useful when the host agent is not installed yet.
///
/// Once the app is connected to `hostd`, the daemon owns this work and this
/// loop exits. The CLI schedule is checked by Rust, so installing the CLI later
/// hands ownership back without making two uploaders compete.
enum DesktopSyncScheduler {
    static func start() {
        Task.detached {
            while !Task.isCancelled {
                guard !Bridge.isHosted else { return }
                do {
                    let status = try await Bridge.syncScheduleStatus()
                    if status.loggedIn && !status.cliScheduleActive && status.due {
                        _ = try? await Bridge.sync()
                    }
                } catch {
                    // The next minute retries. Sync errors belong on the next
                    // explicit Account or Insights surface, not a timer log.
                }
                try? await Task.sleep(for: .seconds(60))
            }
        }
    }
}
