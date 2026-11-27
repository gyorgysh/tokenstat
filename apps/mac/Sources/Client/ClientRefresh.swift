// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
//
// Source-available: source sharing and own builds are permitted.
// Store and commercial distribution of builds is reserved. See LICENSE.
// "tokenstat" is a trademark of pueev OU. See TRADEMARK.md.

import Foundation

#if !os(macOS)

@MainActor
enum ClientRefresh {
    static let minimumInterval: TimeInterval = 5

    private static var lastRun: [String: Date] = [:]
    private static var inFlight: Set<String> = []

    static func began() {
        LogoRefresh.began()
    }

    static func pull(_ key: String, work: () async -> Void) async {
        guard !Task.isCancelled else { return }
        began()
        let window = scoped(key)
        let now = Date()
        lastRun = lastRun.filter { now.timeIntervalSince($0.value) < minimumInterval }
        if inFlight.contains(window) || lastRun[window] != nil {
            try? await Task.sleep(for: .milliseconds(450))
            return
        }
        inFlight.insert(window)
        defer { inFlight.remove(window) }
        await work()
        lastRun[window] = Date()
    }

    private static func scoped(_ key: String) -> String {
        guard let scope = WorkSessionContext.shared.scope else { return key }
        return "\(scope.origin)|\(scope.identity)|\(key)"
    }
}

#endif
