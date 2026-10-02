// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
import SwiftUI

#if os(macOS)
struct SidebarAccountBar: View {
    let name: String
    let detail: String?
    let accessibilityLabel: String
    let menuItems: () -> [NativeMenuItem]
    let settings: () -> Void

    var body: some View {
        HStack(spacing: Theme.Space.s) {
            VStack(alignment: .leading, spacing: 3) {
                Text(name).font(Theme.callout.weight(.semibold)).foregroundStyle(.primary)
                if let detail { Text(detail).font(Theme.caption).foregroundStyle(.secondary) }
            }.lineLimit(1).truncationMode(.tail).accessibilityHidden(true)
                .frame(maxWidth: .infinity, alignment: .leading)
                .overlay {
                    NativeMenuTrigger(items: menuItems, accessibilityLabel: accessibilityLabel)
                }
            Button(L10n.text("common.settings"), .settings, action: settings)
                .labelStyle(.iconOnly).buttonStyle(.borderless)
                .frame(width: 32, height: 32)
                .help(L10n.text("common.settings"))
        }
        // Match the rail's account slot; the native menu must not size the row.
        .frame(height: 40)
        .padding(.horizontal, Theme.Space.s)
        .padding(.bottom, Theme.Space.m)
    }
}
#endif
