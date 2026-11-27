// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
//
// Source-available: source sharing and own builds are permitted.
// Store and commercial distribution of builds is reserved. See LICENSE.

import Foundation

enum DesktopSyncScheduler {
    static func start() {
        Task.detached {
            await BridgeLaunch.wait()
            var lastScan: Int64?
            var hasRead = false
            while !Task.isCancelled {
                if var info = try? await Bridge.info(), info.hasArchive {
                    let nowMs = Int64(Date().timeIntervalSince1970 * 1000)
                    if !Bridge.isHosted,
                       (try? await Bridge.syncScheduleStatus())?.scheduledNetworkAllowed == true,
                       info.lastScanMs.map({ $0 > nowMs || nowMs - $0 >= 300_000 }) ?? true,
                       (try? await Bridge.scan()) != nil {
                        info = (try? await Bridge.info()) ?? info
                    }
                    if hasRead, lastScan != info.lastScanMs {
                        await MainActor.run {
                            NotificationCenter.default.post(name: .archiveDidChange, object: nil)
                        }
                    }
                    hasRead = true
                    lastScan = info.lastScanMs
                }
                do { try await Task.sleep(for: .seconds(60)) } catch { return }
            }
        }
        Task.detached {
            await BridgeLaunch.wait()
            while !Task.isCancelled {
                guard !Bridge.isHosted else { return }
                let status: SyncScheduleStatus
                do {
                    status = try await Bridge.syncScheduleStatus()
                } catch {
                    try? await Task.sleep(for: .seconds(60))
                    continue
                }
                guard status.scheduledNetworkAllowed else {
                    try? await Task.sleep(for: .seconds(60))
                    continue
                }
                _ = try? await Bridge.pricingRefresh()
                if status.loggedIn && !status.cliScheduleActive && status.due {
                    let again = try? await Bridge.syncScheduleStatus()
                    if again?.scheduledNetworkAllowed == true && again?.due == true,
                       (try? await Bridge.sync()) != nil {
                        await MainActor.run {
                            NotificationCenter.default.post(name: .tokenstatDidSync, object: nil)
                        }
                    }
                }
                try? await Task.sleep(for: .seconds(60))
            }
        }
    }
}
