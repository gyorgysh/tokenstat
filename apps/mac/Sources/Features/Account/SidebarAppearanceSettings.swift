// SPDX-License-Identifier: LicenseRef-tokenstat-source-available

#if os(macOS)
import SwiftUI

enum SidebarAppearancePreferences {
    static let enabledKey = "appearance.sidebarGlass"
    static let washKey = "appearance.sidebarWash"
    static let defaultWash = 0.80

    static func normalized(_ value: Double) -> Double {
        value.isFinite ? min(1, max(0, value)) : defaultWash
    }
}

/// Local appearance choices change the surface without resizing the shell.
struct SidebarAppearanceSettings: View {
    @AppStorage(SidebarAppearancePreferences.enabledKey) private var enabled = true
    @AppStorage(SidebarAppearancePreferences.washKey) private var wash = SidebarAppearancePreferences.defaultWash

    var body: some View {
        if #available(macOS 26, *) {
            Card(title: L10n.text("apple.sidebarappearance.title"),
                 subtitle: L10n.text("apple.sidebarappearance.subtitle"), mark: "mark_local") {
                VStack(alignment: .leading, spacing: Theme.Space.s) {
                    Toggle(L10n.text("apple.sidebarappearance.glass"), isOn: $enabled)
                        .toggleStyle(.brandCheckbox)
                        .font(Theme.callout)
                    HStack {
                        Text(L10n.text("apple.sidebarappearance.opacity"))
                        Spacer()
                        Text(SidebarAppearancePreferences.normalized(wash), format: .percent.precision(.fractionLength(0)))
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                    }
                    .font(Theme.callout)
                    Slider(value: Binding(
                        get: { SidebarAppearancePreferences.normalized(wash) },
                        set: { wash = $0 }
                    ), in: 0...1, step: 0.05)
                        .tint(Theme.accent)
                        .disabled(!enabled)
                        .accessibilityLabel(L10n.text("apple.sidebarappearance.opacity"))
                    Text(L10n.text("apple.sidebarappearance.explanation"))
                        .font(Theme.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }
}
#endif
