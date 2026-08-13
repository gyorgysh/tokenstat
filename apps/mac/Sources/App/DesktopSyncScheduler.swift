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
                // The daemon refreshes pricing on its own schedule; in-process
                // this loop is the only scheduler there is. Once up front so a
                // fresh install without the CLI gets real rates, then on the
                // same minute cadence as sync.
                try? await Bridge.pricingRefresh()
                do {
                    let status = try await Bridge.syncScheduleStatus()
                    if status.loggedIn && !status.cliScheduleActive && status.due {
                        // Re-read due immediately before posting. A Sync now
                        // that landed while this loop was between ticks would
                        // otherwise send a second usage POST into the same
                        // gate the account just accepted.
                        let again = try await Bridge.syncScheduleStatus()
                        if again.due {
                            _ = try? await Bridge.sync()
                        }
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
