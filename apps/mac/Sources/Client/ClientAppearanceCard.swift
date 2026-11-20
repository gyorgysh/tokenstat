// SPDX-License-Identifier: LicenseRef-tokenstat-source-available

#if !os(macOS)
import SwiftUI

/// Mode and colour theme on the phone and the iPad.
///
/// The same store as the Mac, with the built-in themes only. Writing and
/// importing a theme file is desktop work. OLED matters most here: an iPhone
/// screen turns a black pixel off, which a Mac display does not.
struct ClientAppearanceCard: View {
    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.m) {
            ClientSectionTitle(title: L10n.text("apple.sidebarappearance.title"), mark: "mark_device")
            AppearancePicker(comfortable: true)
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
