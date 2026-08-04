// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
//
// Source-available for review, NOT open source. See LICENSE.

import Foundation
import Observation

/// Read-only release availability for the app chrome.
@MainActor
@Observable
final class AppUpdateModel {
    private(set) var release: AppUpdate?
    private(set) var isChecking = false
    private(set) var lastError: String?

    var isAvailable: Bool { release?.isAvailable == true }
    var latest: String { release?.latest ?? "" }
    var htmlURL: String { release?.htmlURL ?? "" }

    func check() async {
        guard !isChecking else { return }
        isChecking = true
        defer { isChecking = false }
        do {
            release = try await Bridge.appUpdateCheck()
            lastError = nil
        } catch {
            // Update checks are optional. Do not put network noise into the
            // account or workspace error surfaces.
            lastError = error.localizedDescription
        }
    }
}
