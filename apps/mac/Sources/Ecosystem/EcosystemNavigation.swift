// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
import Foundation
import Observation

@MainActor @Observable
final class EcosystemNavigation {
    static let shared = EcosystemNavigation()
    var pending: EcosystemRoute?
    // Prevent relaunch restoration from replacing an explicit system action.
    private(set) var hasRequestedNavigation = false

    func open(_ route: EcosystemRoute) {
        hasRequestedNavigation = true
        pending = route
    }

    func receive(_ url: URL) {
        guard let route = EcosystemRoute(url: url) else { return }
        open(route)
    }
}
