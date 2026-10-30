// SPDX-License-Identifier: LicenseRef-tokenstat-source-available

import SwiftUI

/// This device's outbound route choice, beside the account relay allowance.
struct RelayFallbackSetting: View {
    let enabled: Bool?
    let change: (Bool) async throws -> Void

    @State private var pending: Bool?
    @State private var isSaving = false
    @State private var error: String?

    var body: some View {
        if let enabled {
            #if os(macOS)
            Card(title: L10n.text("common.connection_route"), mark: "mark_activity") {
                content(enabled)
            }
            #else
            VStack(alignment: .leading, spacing: Theme.Space.s) {
                content(enabled)
            }
            .padding(Theme.Space.m)
            .frame(maxWidth: .infinity, alignment: .leading)
            .cardSurface()
            #endif
        }
    }

    private func content(_ enabled: Bool) -> some View {
        VStack(alignment: .leading, spacing: Theme.Space.s) {
            Toggle(L10n.text("common.relay_fallback"), isOn: Binding(
                get: { pending ?? enabled },
                set: { requested in
                    guard !isSaving else { return }
                    pending = requested
                    isSaving = true
                    error = nil
                    Task {
                        do { try await change(requested) }
                        catch { self.error = error.localizedDescription }
                        pending = nil
                        isSaving = false
                    }
                }
            ))
            .disabled(isSaving)
            .frame(minHeight: 44)
            Text(L10n.text("common.relay_fallback_detail"))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if let error {
                Text(error).foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}
