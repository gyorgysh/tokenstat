// SPDX-License-Identifier: LicenseRef-tokenstat-source-available

import SwiftUI

/// Mode and the built-in colour themes, as one control.
///
/// Shared by the phone's This device card and the setup tour on every
/// platform, so a theme picked in one place looks the same as in the other.
/// The Mac's Appearance settings keep their own grid, which also lists
/// imported themes.
struct AppearancePicker: View {
    var comfortable = false
    private let appearance = AppAppearance.shared
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        @Bindable var appearance = appearance
        VStack(alignment: .leading, spacing: Theme.Space.m) {
            SegmentedTabs(options: AppAppearanceMode.allCases, selection: $appearance.mode, title: \.title,
                          comfortable: comfortable)
            LazyVGrid(columns: [GridItem(.adaptive(minimum: comfortable ? 132 : 108), spacing: Theme.Space.s)],
                      spacing: Theme.Space.s) {
                ForEach(AppAppearance.builtIn, id: \.id) { preset in
                    swatch(preset.theme, id: preset.id)
                }
            }
        }
    }

    private func swatch(_ theme: AppearanceTheme, id: String) -> some View {
        let selected = appearance.paletteID == id
        let colors = scheme == .dark ? theme.dark : theme.light
        let background = appearance.mode == .oled ? Color.black : AppAppearance.color(colors.background) ?? Theme.background
        let accent = AppAppearance.color(colors.accent) ?? Theme.accent
        let secondary = AppAppearance.color(colors.secondary) ?? Theme.secondary
        return Button {
            appearance.select(id)
        } label: {
            VStack(alignment: .leading, spacing: Theme.Space.s) {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(LinearGradient(colors: [background, accent, secondary],
                                         startPoint: .topLeading, endPoint: .bottomTrailing))
                    .frame(height: comfortable ? 34 : 28)
                    .accessibilityHidden(true)
                HStack(spacing: Theme.Space.xs) {
                    Text(id == "default" ? L10n.text("apple.sidebarappearance.default_theme") : theme.name)
                        .lineLimit(1)
                    Spacer(minLength: 0)
                    if selected {
                        Image(systemName: "checkmark")
                            .foregroundStyle(Theme.accent)
                            .accessibilityHidden(true)
                    }
                }
                .font(Theme.callout)
            }
            .padding(Theme.Space.s)
            .background(selected ? Theme.accentSoft : Theme.panel,
                        in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(selected ? Theme.accent : Theme.border, lineWidth: 1)
            }
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}
