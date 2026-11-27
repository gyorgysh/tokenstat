// SPDX-License-Identifier: LicenseRef-tokenstat-source-available

import SwiftUI
#if os(iOS)
import UIKit
#endif

enum AppAppearanceMode: String, CaseIterable {
    case auto, light, dark, oled

    var title: String {
        switch self {
        case .auto: L10n.text("apple.sidebarappearance.auto")
        case .light: L10n.text("apple.sidebarappearance.light")
        case .dark: L10n.text("apple.sidebarappearance.dark")
        case .oled: L10n.text("apple.sidebarappearance.oled")
        }
    }

    var colorScheme: ColorScheme? {
        switch self {
        case .auto: nil
        case .light: .light
        case .dark, .oled: .dark
        }
    }
}

struct AppearanceColors: Codable, Equatable {
    let background: String
    let sidebar: String
    let panel: String
    let border: String
    let accent: String
    let secondary: String
    let selection: String

    init(_ background: String, _ sidebar: String, _ panel: String, _ border: String,
         _ accent: String, _ secondary: String, _ selection: String) {
        self.background = "#" + background
        self.sidebar = "#" + sidebar
        self.panel = "#" + panel
        self.border = "#" + border
        self.accent = "#" + accent
        self.secondary = "#" + secondary
        self.selection = "#" + selection
    }

    static func rgb(_ hex: String) -> UInt32? {
        guard hex.utf8.count == 7, hex.first == "#" else { return nil }
        let digits = hex.utf8.dropFirst()
        guard digits.allSatisfy({ (48...57).contains($0) || (65...70).contains($0) || (97...102).contains($0) })
        else { return nil }
        return UInt32(hex.dropFirst(), radix: 16)
    }

    private static func luminance(_ value: UInt32) -> Double {
        [16, 8, 0].map { shift -> Double in
            let channel = Double((value >> shift) & 255) / 255
            return channel <= 0.04045 ? channel / 12.92 : pow((channel + 0.055) / 1.055, 2.4)
        }.enumerated().reduce(0) { sum, channel in
            sum + channel.element * [0.2126, 0.7152, 0.0722][channel.offset]
        }
    }

    func validate(onDark: Bool) throws {
        let values = [background, sidebar, panel, border, accent, secondary, selection]
        let rgb = values.compactMap(Self.rgb)
        guard rgb.count == values.count else { throw AppearanceImportError.color }
        let surface = [rgb[0], rgb[1], rgb[2], rgb[6]].map(Self.luminance)
        guard surface.allSatisfy({ onDark ? $0 <= 0.065 : $0 >= 0.64 }) else {
            throw AppearanceImportError.contrast
        }
        let accent = Self.luminance(rgb[4])
        let secondary = Self.luminance(rgb[5])
        guard surface.prefix(3).allSatisfy({ ground in
            ([accent, secondary]).allSatisfy { color in
                (max(color, ground) + 0.05) / (min(color, ground) + 0.05) >= 4.5
            }
        }) else { throw AppearanceImportError.contrast }
    }
}

struct AppearanceTheme: Codable, Equatable {
    let version: Int
    let name: String
    let light: AppearanceColors
    let dark: AppearanceColors

    init(name: String, light: AppearanceColors, dark: AppearanceColors) {
        version = 1
        self.name = name
        self.light = light
        self.dark = dark
    }

    private var trimmedName: String { name.trimmingCharacters(in: .whitespacesAndNewlines) }

    func validated() throws -> Self {
        guard version == 1 else { throw AppearanceImportError.version }
        guard !trimmedName.isEmpty, trimmedName.count <= 40, trimmedName.utf8.count <= 160,
              !trimmedName.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) })
        else { throw AppearanceImportError.name }
        try light.validate(onDark: false)
        try dark.validate(onDark: true)
        return Self(name: trimmedName, light: light, dark: dark)
    }
}

enum AppearanceImportError: LocalizedError {
    case tooLarge, version, name, color, contrast, limit

    var errorDescription: String? {
        switch self {
        case .tooLarge: L10n.text("apple.sidebarappearance.error_size")
        case .version: L10n.text("apple.sidebarappearance.error_version")
        case .name: L10n.text("apple.sidebarappearance.error_name")
        case .color: L10n.text("apple.sidebarappearance.error_color")
        case .contrast: L10n.text("apple.sidebarappearance.error_contrast")
        case .limit: L10n.text("apple.sidebarappearance.error_limit")
        }
    }
}

@Observable
final class AppAppearance {
    static let shared = AppAppearance()
    static let maximumImportBytes = 16_384
    static let maximumCustomThemes = 24
    private static let modeKey = "appearance.mode"
    private static let paletteKey = "appearance.palette"
    private static let themesKey = "appearance.customThemes"

    struct Custom: Codable, Identifiable {
        let id: UUID
        let theme: AppearanceTheme
    }

    static let builtIn: [(id: String, theme: AppearanceTheme)] = [
        ("default", .init(name: "Default",
            light: .init("FBFBFD", "F3F2F8", "FFFFFF", "E7E7EE", "6A3DFF", "A21CAF", "F0ECFF"),
            dark: .init("08070D", "12101D", "100E1A", "211D33", "A786FF", "E879F9", "1B1430"))),
        ("ink", .init(name: "Ink",
            light: .init("EDF2F7", "E3EAF1", "F9FBFD", "D1DCE7", "315B83", "2B6578", "DCE8F1"),
            dark: .init("0D141C", "1B2A37", "151F2A", "293B4B", "79B4E0", "63C2CF", "1D3848"))),
        ("ember", .init(name: "Ember",
            light: .init("FBF1E8", "F3E1D2", "FFFAF5", "EAD4C3", "A6431D", "8B521E", "F6DFCF"),
            dark: .init("1B100D", "352019", "281814", "4B2C22", "FF9A63", "EDBD67", "48271D"))),
        ("aurora", .init(name: "Aurora",
            light: .init("EAF7F5", "D9EFEB", "F8FFFE", "C7E2DD", "096E67", "236798", "D2EEEA"),
            dark: .init("081B1B", "143836", "102928", "20504C", "65DFC9", "81CEF9", "17433E"))),
    ]

    private let defaults: UserDefaults
    var mode: AppAppearanceMode {
        didSet { defaults.set(mode.rawValue, forKey: Self.modeKey) }
    }
    private(set) var paletteID: String {
        didSet { defaults.set(paletteID, forKey: Self.paletteKey) }
    }
    private(set) var custom: [Custom]

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        mode = defaults.string(forKey: Self.modeKey).flatMap(AppAppearanceMode.init(rawValue:)) ?? .auto
        let decoded = defaults.data(forKey: Self.themesKey).flatMap { try? JSONDecoder().decode([Custom].self, from: $0) } ?? []
        let themes = Array(decoded.filter { (try? $0.theme.validated()) != nil }.prefix(Self.maximumCustomThemes))
        custom = themes
        let saved = defaults.string(forKey: Self.paletteKey)
        paletteID = saved.flatMap { id in
            Self.builtIn.contains { $0.id == id } || themes.contains { $0.id.uuidString == id } ? id : nil
        } ?? "default"
    }

    var theme: AppearanceTheme {
        Self.builtIn.first { $0.id == paletteID }?.theme
            ?? custom.first { $0.id.uuidString == paletteID }?.theme
            ?? Self.builtIn[0].theme
    }

    var markdownCacheKey: String {
        guard paletteID != "default" else { return "" }
        let theme = theme
        return [theme.light.accent, theme.dark.accent, theme.light.secondary, theme.dark.secondary].joined()
    }

    func select(_ id: String) {
        guard Self.builtIn.contains(where: { $0.id == id }) || custom.contains(where: { $0.id.uuidString == id })
        else { return }
        paletteID = id
    }

    func importTheme(_ data: Data) throws {
        guard data.count <= Self.maximumImportBytes else { throw AppearanceImportError.tooLarge }
        let theme = try JSONDecoder().decode(AppearanceTheme.self, from: data).validated()
        let id: UUID
        if let index = custom.firstIndex(where: { $0.theme.name.caseInsensitiveCompare(theme.name) == .orderedSame }) {
            id = custom[index].id
            custom[index] = .init(id: id, theme: theme)
        } else {
            guard custom.count < Self.maximumCustomThemes else { throw AppearanceImportError.limit }
            id = UUID()
            custom.append(.init(id: id, theme: theme))
        }
        saveCustom()
        paletteID = id.uuidString
    }

    func remove(_ id: UUID) {
        if paletteID == id.uuidString { paletteID = "default" }
        custom.removeAll { $0.id == id }
        saveCustom()
    }

    private func saveCustom() {
        defaults.set(try? JSONEncoder().encode(custom), forKey: Self.themesKey)
    }

    @ObservationIgnored private var cachedTheme: AppearanceTheme?
    @ObservationIgnored private var cachedColors: [KeyPath<AppearanceColors, String>: Color] = [:]

    func color(_ key: KeyPath<AppearanceColors, String>, fallback: Color, blackInOLED: Bool = false) -> Color {
        if blackInOLED, mode == .oled { return .black }
        guard paletteID != "default" else { return fallback }
        let theme = theme
        if theme != cachedTheme {
            cachedTheme = theme
            cachedColors.removeAll(keepingCapacity: true)
        }
        if let cached = cachedColors[key] { return cached }
        guard let light = Self.color(theme.light[keyPath: key]), let dark = Self.color(theme.dark[keyPath: key])
        else { return fallback }
        let color = Color.adaptive(light: light, dark: dark)
        cachedColors[key] = color
        return color
    }

    static func color(_ hex: String) -> Color? {
        AppearanceColors.rgb(hex).map {
            Color(red: Double(($0 >> 16) & 255) / 255, green: Double(($0 >> 8) & 255) / 255,
                  blue: Double($0 & 255) / 255)
        }
    }
}
struct AppAppearanceScheme: ViewModifier {
    func body(content: Content) -> some View {
        #if os(iOS)
        content
            .onChange(of: AppAppearance.shared.mode, initial: true) { _, mode in
                let style: UIUserInterfaceStyle = switch mode.colorScheme {
                case .light: .light
                case .dark: .dark
                default: .unspecified
                }
                for case let scene as UIWindowScene in UIApplication.shared.connectedScenes {
                    for window in scene.windows { window.overrideUserInterfaceStyle = style }
                }
            }
        #else
        content.preferredColorScheme(AppAppearance.shared.mode.colorScheme)
        #endif
    }
}
