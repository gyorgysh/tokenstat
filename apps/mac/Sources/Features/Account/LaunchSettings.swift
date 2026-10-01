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
        Card(title: L10n.text("apple.launchsettings.startup.65d48235"), subtitle: L10n.text("apple.launchsettings.when_tokenstat_opens.18072775"), mark: "mark_local") {
            controls
        }
        #else
        VStack(alignment: .leading, spacing: Theme.Space.m) {
            ClientSectionTitle(title: L10n.text("apple.launchsettings.startup.65d48235"), mark: "mark_local")
            controls
        }
        .padding(Theme.Space.m)
        .frame(maxWidth: .infinity, alignment: .leading)
        .cardSurface()
        #endif
    }

    private var controls: some View {
        VStack(alignment: .leading, spacing: Theme.Space.s) {
            Toggle(L10n.text("apple.launchsettings.reopen_last_location.1d524ca3"), isOn: $restoreLocation)
                .toggleStyle(.brandCheckbox)
                .font(Theme.callout)
                #if os(iOS)
                .frame(minHeight: 44)
                #endif
                .tint(Theme.accent)
            Text(L10n.text("apple.launchsettings.open_where_you_left_off_on_this_device_whe.26b59662"))
                .font(Theme.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}
