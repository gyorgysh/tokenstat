// SPDX-License-Identifier: LicenseRef-tokenstat-source-available

#if os(macOS)
import SwiftUI
import UniformTypeIdentifiers

enum SidebarAppearancePreferences {
    static let enabledKey = "appearance.sidebarGlass"
    static let washKey = "appearance.sidebarWash"
    /// Extra light drawn on the glass: a sheen along the top, a glare
    /// streak and a lit edge.
    static let highlightsKey = "appearance.sidebarHighlights"
    static let defaultWash = 0.95

    /// The least wash OLED allows. The glass keeps its edge and its light,
    /// but the rows sit on something close enough to black that the theme
    /// still reads as black rather than as a grey frost.
    static let oledMinimumWash = 0.8

    static func normalized(_ value: Double) -> Double {
        value.isFinite ? min(1, max(0, value)) : defaultWash
    }

    /// The wash actually drawn, after the theme has had its say.
    static func effective(_ value: Double) -> Double {
        let wash = normalized(value)
        return AppAppearance.shared.mode == .oled ? max(wash, oledMinimumWash) : wash
    }
}

struct SidebarAppearanceSettings: View {
    private let appearance = AppAppearance.shared
    @AppStorage(SidebarAppearancePreferences.enabledKey) private var enabled = true
    @AppStorage(SidebarAppearancePreferences.washKey) private var wash = SidebarAppearancePreferences.defaultWash
    @AppStorage(SidebarAppearancePreferences.highlightsKey) private var highlights = true
    @Environment(\.colorScheme) private var scheme
    @State private var showsImporter = false
    @State private var importError: String?
    @State private var copiedPrompt = false

    var body: some View {
        @Bindable var appearance = appearance
        Card(title: L10n.text("apple.sidebarappearance.title"),
             subtitle: L10n.text("apple.sidebarappearance.subtitle"), mark: "mark_local") {
            VStack(alignment: .leading, spacing: Theme.Space.l) {
                Picker(L10n.text("apple.sidebarappearance.mode"), selection: $appearance.mode) {
                    ForEach(AppAppearanceMode.allCases, id: \.self) { mode in
                        Text(mode.title).tag(mode)
                    }
                }
                .pickerStyle(.segmented)

                VStack(alignment: .leading, spacing: Theme.Space.s) {
                    Text(L10n.text("apple.sidebarappearance.theme")).font(Theme.headline)
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 112), spacing: Theme.Space.s)], spacing: Theme.Space.s) {
                        ForEach(AppAppearance.builtIn, id: \.id) { preset in
                            swatch(preset.theme, id: preset.id)
                        }
                        ForEach(appearance.custom) { preset in
                            swatch(preset.theme, id: preset.id.uuidString)

                        }
                    }
                    ViewThatFits(in: .horizontal) {
                        HStack(spacing: Theme.Space.s) { themeActions }
                        VStack(alignment: .leading, spacing: Theme.Space.s) { themeActions }
                    }
                    Text(L10n.text("apple.sidebarappearance.agent_help"))
                        .font(Theme.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    if let importError {
                        Text(importError)
                            .font(Theme.caption)
                            .foregroundStyle(Theme.danger)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                if #available(macOS 26, *) {
                    ThemeRule()
                    glassControls
                }
            }
        }
        .fileImporter(isPresented: $showsImporter, allowedContentTypes: [.json]) { result in
            switch result {
            case let .success(url): importTheme(from: url)
            case let .failure(error): importError = error.localizedDescription
            }
        }
    }

    @ViewBuilder
    private var themeActions: some View {
        Button(L10n.text("apple.sidebarappearance.import_theme"), .upload) {
            showsImporter = true
            importError = nil
        }
        .buttonStyle(SecondaryButtonStyle(small: true))
        Button(copiedPrompt ? L10n.text("apple.sidebarappearance.prompt_copied")
               : L10n.text("apple.sidebarappearance.copy_prompt"),
               copiedPrompt ? .save : .copy, action: copyPrompt)
            .buttonStyle(SecondaryButtonStyle(small: true))
        if let id = UUID(uuidString: appearance.paletteID) {
            Button(L10n.text("apple.sidebarappearance.remove_theme"), .delete) {
                appearance.remove(id)
                importError = nil
                copiedPrompt = false
            }
            .buttonStyle(SecondaryButtonStyle(small: true))
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
            copiedPrompt = false
        } label: {
            VStack(alignment: .leading, spacing: Theme.Space.s) {
                RoundedRectangle(cornerRadius: 6)
                    .fill(LinearGradient(colors: [background, accent, secondary], startPoint: .topLeading, endPoint: .bottomTrailing))
                    .frame(height: 27)
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
            .background(selected ? Theme.accentSoft : Theme.panel, in: RoundedRectangle(cornerRadius: 9))
            .overlay {
                RoundedRectangle(cornerRadius: 9).strokeBorder(selected ? Theme.accent : Theme.border, lineWidth: 1)
            }
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? .isSelected : [])
        .help(theme.name)
    }

    private var glassControls: some View {
        VStack(alignment: .leading, spacing: Theme.Space.s) {
            Toggle(L10n.text("apple.sidebarappearance.glass"), isOn: $enabled)
                .toggleStyle(.brandCheckbox)
                .font(Theme.callout)
            Toggle(L10n.text("apple.sidebarappearance.highlights"), isOn: $highlights)
                .toggleStyle(.brandCheckbox)
                .font(Theme.callout)
                .disabled(!enabled)
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

    private func copyPrompt() {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(appearance.theme),
              let example = String(data: data, encoding: .utf8) else { return }
        NSPasteboard.general.clearContents()
        copiedPrompt = NSPasteboard.general.setString(
            L10n.text("apple.sidebarappearance.agent_prompt") + "\n\n" + example, forType: .string)
    }

    private func importTheme(from url: URL) {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        do {
            let handle = try FileHandle(forReadingFrom: url)
            defer { try? handle.close() }
            let data = try handle.read(upToCount: AppAppearance.maximumImportBytes + 1) ?? Data()
            try appearance.importTheme(data)
            copiedPrompt = false
        } catch let error as AppearanceImportError {
            importError = error.localizedDescription
        } catch {
            importError = L10n.text("apple.sidebarappearance.error_json")
        }
    }
}
#endif
