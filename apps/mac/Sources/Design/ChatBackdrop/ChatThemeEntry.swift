// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
import Foundation

struct ChatThemeEntry: Decodable {
    let id: String?
    let name: String?
    let bg: String
    let text: String
    let accent: String

    static func decode(_ data: Data) throws -> [ChatThemeEntry] {
        let decoder = JSONDecoder()
        if let one = try? decoder.decode(ChatThemeEntry.self, from: data) { return [one] }
        if let many = try? decoder.decode([Lenient].self, from: data) {
            let entries = many.compactMap(\.entry)
            if !entries.isEmpty { return entries }
        }
        throw DecodingError.dataCorrupted(.init(codingPath: [], debugDescription: "not a theme"))
    }

    private struct Lenient: Decodable {
        let entry: ChatThemeEntry?
        init(from decoder: Decoder) throws { entry = try? ChatThemeEntry(from: decoder) }
    }

    func theme() throws -> AppearanceTheme {
        guard let bg = Self.parse(bg), let text = Self.parse(text), let accent = Self.parse(accent)
        else { throw AppearanceImportError.color }
        let title = (name ?? id ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let dark = AsciiKit.luminance(bg) <= 0.5
        let own = Self.colors(bg: bg, text: text, accent: accent, dark: dark)
        let base = AppAppearance.builtIn[0].theme
        let other = Self.colors(from: dark ? base.light : base.dark, accent: accent, dark: !dark)
        return try AppearanceTheme(name: title, light: dark ? other : own, dark: dark ? own : other).validated()
    }

    private static func parse(_ value: String) -> UInt32? {
        AppearanceColors.rgb(value.trimmingCharacters(in: .whitespaces))
    }

    private static func ratio(_ a: UInt32, _ b: UInt32) -> Double {
        let x = AppearanceColors.luminance(a), y = AppearanceColors.luminance(b)
        return (max(x, y) + 0.05) / (min(x, y) + 0.05)
    }

    private static func surface(_ c: UInt32, dark: Bool) -> UInt32 {
        var value = c
        for step in 1...20 where dark ? AppearanceColors.luminance(value) > 0.065 : AppearanceColors.luminance(value) < 0.64 {
            value = AsciiKit.mix(c, dark ? 0x000000 : 0xFFFFFF, Double(step) * 0.05)
        }
        return value
    }

    private static func readable(_ c: UInt32, on grounds: [UInt32], toward ink: UInt32) -> UInt32 {
        var value = c
        for step in 1...20 where grounds.contains(where: { ratio(value, $0) < 4.5 }) {
            value = AsciiKit.mix(c, ink, Double(step) * 0.05)
        }
        return value
    }

    private static func hex(_ c: UInt32) -> String { String(format: "%06X", c) }

    private static func colors(bg: UInt32, text: UInt32, accent: UInt32, dark: Bool) -> AppearanceColors {
        let background = surface(bg, dark: dark)
        let sidebar = surface(AsciiKit.mix(bg, text, 0.03), dark: dark)
        let panel = surface(dark ? AsciiKit.mix(bg, text, 0.06) : AsciiKit.mix(bg, 0xFFFFFF, 0.6), dark: dark)
        let selection = surface(AsciiKit.mix(bg, accent, 0.15), dark: dark)
        let ink: UInt32 = dark ? 0xFFFFFF : 0x000000
        let grounds = [background, sidebar, panel]
        return AppearanceColors(
            hex(background), hex(sidebar), hex(panel), hex(AsciiKit.mix(bg, text, 0.14)),
            hex(readable(accent, on: grounds, toward: ink)),
            hex(readable(AsciiKit.mix(accent, text, 0.35), on: grounds, toward: ink)),
            hex(selection))
    }

    private static func colors(from base: AppearanceColors, accent: UInt32, dark: Bool) -> AppearanceColors {
        let value: (String) -> UInt32 = { AppearanceColors.rgb($0) ?? 0 }
        let grounds = [value(base.background), value(base.sidebar), value(base.panel)]
        let ink: UInt32 = dark ? 0xFFFFFF : 0x000000
        let tinted = readable(accent, on: grounds, toward: ink)
        return AppearanceColors(
            String(base.background.dropFirst()), String(base.sidebar.dropFirst()), String(base.panel.dropFirst()),
            String(base.border.dropFirst()), hex(tinted),
            hex(readable(AsciiKit.mix(tinted, value(base.secondary), 0.5), on: grounds, toward: ink)),
            hex(surface(AsciiKit.mix(value(base.background), tinted, 0.15), dark: dark)))
    }
}
