// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
import SwiftUI

enum LaunchPreferences {
    static let restoreLocationKey = "navigation.reopenLastLocation"
    static var restoresLocation: Bool { UserDefaults.standard.bool(forKey: restoreLocationKey) }
}

/// Startup behavior belongs to this device, independently of saved-work storage.
struct LaunchSettings: View {
    @AppStorage(LaunchPreferences.restoreLocationKey) private var restoreLocation = false

    var body: some View {
        #if os(macOS)
        Card(title: "Startup", subtitle: "When tokenstat opens", mark: "mark_local") {
            controls
        }
        #else
        VStack(alignment: .leading, spacing: Theme.Space.m) {
            ClientSectionTitle(title: "Startup", mark: "mark_local")
            controls
        }
        .padding(Theme.Space.m)
        .frame(maxWidth: .infinity, alignment: .leading)
        .cardSurface()
        #endif
    }

    private var controls: some View {
        VStack(alignment: .leading, spacing: Theme.Space.s) {
            Toggle("Reopen last location", isOn: $restoreLocation)
                .toggleStyle(.brandCheckbox)
                .font(Theme.callout)
                #if os(iOS)
                .frame(minHeight: 44)
                #endif
                .tint(Theme.accent)
            Text("Open where you left off on this device. When off, new launches start on Home. Applies next launch; unavailable locations open Home.")
                .font(Theme.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}
