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
        // Reading the revision makes a setEnabled bump observable, so the row
        // redraws instead of sitting on the old switch position.
        _ = preferenceRevision
        return LocalProviderPreference.isEnabled(providerID)
    }

    func setEnabled(_ enabled: Bool, for providerID: String) {
        LocalProviderPreference.setEnabled(enabled, for: providerID)
        preferenceRevision += 1
    }

    func setPort(_ port: Int, for providerID: String) async throws {
        guard !isLoading else {
            throw NSError(domain: "LocalProviderSettings", code: 1, userInfo: [NSLocalizedDescriptionKey: L10n.text("common.local_provider_busy")])
        }
        isLoading = true
        defer { isLoading = false }
        try await Bridge.setLocalProviderPort(providerID, port: port)
        if let index = providers.firstIndex(where: { $0.id == providerID }) {
            providers[index].port = port
            var address = URLComponents(string: providers[index].baseURL)
            address?.port = port
            if let base = address?.string { providers[index].baseURL = base }
            providers[index].available = false
            providers[index].models = []
        }
        do {
            providers = try await Bridge.localModels()
            errorMessage = nil
        } catch {
            throw NSError(domain: "LocalProviderSettings", code: 2, userInfo: [NSLocalizedDescriptionKey: L10n.text("common.local_provider_saved_refresh")])
        }
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
