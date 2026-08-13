// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
//
// Source-available for review, NOT open source. See LICENSE: no rights to
// redistribute, publish, or ship a build are granted. Read it, study it, run
// your own build of it.

import Foundation
import Observation

#if os(macOS)

/// Local model servers are optional. A missing provider is a normal state, not
/// an Account error, so this model keeps its own loading and probe result.
@MainActor
@Observable
final class LocalModelsModel {
    private(set) var providers: [LocalProvider] = []
    private(set) var isLoading = false
    private(set) var errorMessage: String?

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
