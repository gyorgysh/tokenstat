// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
import SwiftUI

#if os(macOS)
struct SidebarAccountBar: View {
    let avatar: AnyView
    let name: String
    let detail: String?
    let accessibilityLabel: String
    let menuItems: () -> [NativeMenuItem]
    let settings: () -> Void

    var body: some View {
        HStack(spacing: Theme.Space.s) {
            avatar.background {
                Circle().fill(LinearGradient(colors: [Theme.accent, Theme.secondary],
                    startPoint: .topLeading, endPoint: .bottomTrailing))
                    .frame(width: 44, height: 44).blur(radius: 7).opacity(0.28)
                    .allowsHitTesting(false)
            }
            ZStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text(name).font(Theme.callout.weight(.semibold)).foregroundStyle(.primary)
                    if let detail { Text(detail).font(Theme.caption).foregroundStyle(.secondary) }
                }.lineLimit(1).truncationMode(.tail).accessibilityHidden(true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                NativeMenuTrigger(items: menuItems, accessibilityLabel: accessibilityLabel)
            }
            Button(L10n.text("common.settings"), .settings, action: settings)
                .labelStyle(.iconOnly).buttonStyle(.borderless)
                .frame(width: 32, height: 32)
                .help(L10n.text("common.settings"))
        }
        .padding(Theme.Space.s)
        .background(Theme.panel, in: .rect(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Theme.border, lineWidth: 1))
        .padding(Theme.Space.s)
    }
}
#endif
