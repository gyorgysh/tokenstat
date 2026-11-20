// Compile with AppAppearance.swift.
// SPDX-License-Identifier: LicenseRef-tokenstat-source-available

import SwiftUI

// The app resolves adaptive colors in Theme.swift. These tests exercise file
// validation, settings storage, and the OLED override without the full shell.
extension Color {
    static func adaptive(light: Color, dark: Color) -> Color { light }
}

@main
struct AppAppearanceTests {
    static func main() throws {
        let suite = "tokenstat-appearance-tests-\(UUID())"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = AppAppearance(defaults: defaults)
        assert(store.mode == .auto && store.paletteID == "default")
        assert(store.mode.colorScheme == nil)
        assert(AppAppearanceMode.oled.colorScheme == .dark)
        for preset in AppAppearance.builtIn { _ = try preset.theme.validated() }

        let example = AppAppearance.builtIn[1].theme
        let custom = AppearanceTheme(name: "   Harbor   ", light: example.light, dark: example.dark)
        try store.importTheme(JSONEncoder().encode(custom))
        assert(store.theme.name == "Harbor")
        let id = store.paletteID
        assert(UUID(uuidString: id) != nil)

        let revised = AppAppearance.builtIn[3].theme
        let update = AppearanceTheme(name: "Harbor", light: revised.light, dark: revised.dark)
        try store.importTheme(JSONEncoder().encode(update))
        assert(store.paletteID == id && store.custom.count == 1 && store.theme == update)
        store.mode = .oled
        assert(store.color(\.background, fallback: .white, blackInOLED: true) == .black)
        assert(store.color(\.accent, fallback: .white) != .black)

        let reloaded = AppAppearance(defaults: defaults)
        assert(reloaded.mode == .oled && reloaded.paletteID == id && reloaded.theme == update)
        assert(AppearanceColors.rgb("#aB5678") == 0xAB5678)
        for bad in ["+234567", "#+45678", "#1234", "#12A3ZB", "#１２３"] {
            assert(AppearanceColors.rgb(bad) == nil)
        }
        let badContrast = AppearanceTheme(name: "Glare", light: revised.dark, dark: revised.light)
        let oversized = Data(count: AppAppearance.maximumImportBytes + 1)
        let badVersion = Data(String(decoding: try JSONEncoder().encode(update), as: UTF8.self)
            .replacingOccurrences(of: "\"version\":1", with: "\"version\":2").utf8)
        for invalid in [Data("broken".utf8), oversized, badVersion, try JSONEncoder().encode(badContrast)] {
            do {
                try reloaded.importTheme(invalid)
                preconditionFailure("An invalid theme was imported")
            } catch {
                assert(reloaded.paletteID == id && reloaded.theme == update && reloaded.custom.count == 1)
            }
        }
        reloaded.remove(reloaded.custom[0].id)
        assert(reloaded.paletteID == "default" && AppAppearance(defaults: defaults).custom.isEmpty)
        print("PASS: appearance defaults, import, replacement, persistence, OLED, validation, and removal")
    }
}
