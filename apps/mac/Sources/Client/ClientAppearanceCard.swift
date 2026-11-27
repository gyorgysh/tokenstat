// SPDX-License-Identifier: LicenseRef-tokenstat-source-available

#if !os(macOS)
import SwiftUI

struct ClientAppearanceCard: View {
    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.m) {
            ClientSectionTitle(title: L10n.text("apple.sidebarappearance.title"), mark: "mark_device")
            AppearancePicker(comfortable: true)
            ChatBackdropPicker(comfortable: true)
            Button(L10n.text("apple.setuptour.run_again"), .theme) {
                SetupTourPreferences.requestShow()
            }
            .buttonStyle(SecondaryButtonStyle(comfortable: true))
        }
        .padding(Theme.Space.m)
        .frame(maxWidth: .infinity, alignment: .leading)
        .cardSurface()
    }
}
#endif
