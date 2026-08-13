// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
//
// Source-available for review, NOT open source. See LICENSE: no rights to
// redistribute, publish, or ship a build are granted. Read it, study it, run
// your own build of it.

import Foundation
import Observation

#if os(macOS)

/// Local provider preferences stay in UserDefaults, beside other per-machine
/// launch settings. They never travel through the archive or sync.
enum LocalProviderPreference {
    private static let enabledKey = "localProvider.enabled"

    static func isEnabled(_ providerID: String) -> Bool {
        UserDefaults.standard.object(forKey: "\(enabledKey).\(providerID)") as? Bool ?? true
    }

    static func setEnabled(_ enabled: Bool, for providerID: String) {
        UserDefaults.standard.set(enabled, forKey: "\(enabledKey).\(providerID)")
    }
}

/// Local model servers are optional. A missing provider is a normal state, not
/// an Account error, so this model keeps its own loading and probe result.
@MainActor
@Observable
final class LocalModelsModel {
    private(set) var providers: [LocalProvider] = []
    private(set) var isLoading = false
    private(set) var errorMessage: String?
    private(set) var preferenceRevision = 0

    func isEnabled(_ providerID: String) -> Bool {
        LocalProviderPreference.isEnabled(providerID)
    }

    func setEnabled(_ enabled: Bool, for providerID: String) {
        LocalProviderPreference.setEnabled(enabled, for: providerID)
        preferenceRevision += 1
    }

    func load() async {
        guard !isLoading else { return }
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }
        do {
            providers = try await Bridge.localModels()
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

#endif
