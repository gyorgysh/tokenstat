// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
//
// Source-available for review, NOT open source. See LICENSE.

import Foundation

/// How a job's runs are ordered and windowed for the library preview and the
/// history destination.
///
/// The host returns the retained list in one read. Live runs stay on the first
/// page so Stop is never behind Earlier runs. Completed runs are newest first.
enum AutomationRunHistory {
    static let previewCount = 5
    static let pageSize = 20

    static func ordered<R>(
        _ runs: [R],
        id: KeyPath<R, String>,
        startedAtMs: KeyPath<R, Int64>,
        isLive: KeyPath<R, Bool>
    ) -> [R] {
        runs.sorted { lhs, rhs in
            let liveL = lhs[keyPath: isLive]
            let liveR = rhs[keyPath: isLive]
            if liveL != liveR { return liveL }
            let startedL = lhs[keyPath: startedAtMs]
            let startedR = rhs[keyPath: startedAtMs]
            if startedL != startedR { return startedL > startedR }
            return lhs[keyPath: id] > rhs[keyPath: id]
        }
    }

    static func preview<R>(
        _ runs: [R],
        id: KeyPath<R, String>,
        startedAtMs: KeyPath<R, Int64>,
        isLive: KeyPath<R, Bool>
    ) -> [R] {
        Array(ordered(runs, id: id, startedAtMs: startedAtMs, isLive: isLive).prefix(previewCount))
    }

    static func page<R>(
        _ runs: [R],
        shown: Int,
        id: KeyPath<R, String>,
        startedAtMs: KeyPath<R, Int64>,
        isLive: KeyPath<R, Bool>
    ) -> [R] {
        Array(ordered(runs, id: id, startedAtMs: startedAtMs, isLive: isLive).prefix(max(0, shown)))
    }

    static func remaining(total: Int, shown: Int) -> Int {
        max(0, total - max(0, shown))
    }

    static func showsAllRuns(_ total: Int) -> Bool {
        total > previewCount
    }

    static func latest<R>(
        _ runs: [R],
        id: KeyPath<R, String>,
        startedAtMs: KeyPath<R, Int64>,
        isLive: KeyPath<R, Bool>
    ) -> R? {
        ordered(runs, id: id, startedAtMs: startedAtMs, isLive: isLive).first
    }
}
