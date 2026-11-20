// SPDX-License-Identifier: LicenseRef-tokenstat-source-available

#if os(iOS)
import SwiftUI

/// Mode and colour theme on the phone and the iPad.
///
/// The same store as the Mac, with the built-in themes only. Writing and
/// importing a theme file is desktop work. OLED matters most here: an iPhone
/// screen turns a black pixel off, which a Mac display does not.
struct ClientAppearanceCard: View {
    private let appearance = AppAppearance.shared
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        @Bindable var appearance = appearance
        VStack(alignment: .leading, spacing: Theme.Space.m) {
            ClientSectionTitle(title: L10n.text("apple.sidebarappearance.title"), mark: "mark_device")
            SegmentedTabs(options: AppAppearanceMode.allCases, selection: $appearance.mode, title: \.title,
                          comfortable: true)
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 132), spacing: Theme.Space.s)], spacing: Theme.Space.s) {
                ForEach(AppAppearance.builtIn, id: \.id) { preset in
                    swatch(preset.theme, id: preset.id)
                }
            }
        }
        .padding(Theme.Space.m)
        .frame(maxWidth: .infinity, alignment: .leading)
        .cardSurface()
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
                    .frame(height: 34)
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
                .font(ClientType.label)
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
#endif
