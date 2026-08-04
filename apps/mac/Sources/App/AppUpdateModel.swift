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
    var current: String { release?.current ?? "" }
    var htmlURL: String { release?.htmlURL ?? "" }
    /// The disk image if this release has one, the release page otherwise.
    var downloadURL: URL? { release?.downloadURL }
    /// Whether the download is the app itself, which decides whether the sheet
    /// can say "drag it into Applications" or has to send somebody to a page.
    var hasDiskImage: Bool { release?.dmgURL?.isEmpty == false }

    /// A release the user said they did not want to hear about again.
    ///
    /// Per version rather than a blanket "stop checking": somebody skipping
    /// 0.2.0 has not asked to be kept off 0.3.0, and an updater that treats
    /// those as the same thing is one people turn off entirely.
    private static let skippedKey = "AppUpdate.skippedVersion"

    var isSkipped: Bool {
        guard let latest = release?.latest, !latest.isEmpty else { return false }
        return UserDefaults.standard.string(forKey: Self.skippedKey) == latest
    }

    func skipThisVersion() {
        guard let latest = release?.latest, !latest.isEmpty else { return }
        UserDefaults.standard.set(latest, forKey: Self.skippedKey)
    }

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
