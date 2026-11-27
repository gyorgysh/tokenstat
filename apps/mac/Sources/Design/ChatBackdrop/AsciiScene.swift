// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
import SwiftUI

struct AsciiPalette: Equatable {
    let bg: UInt32
    let accent: UInt32
    let secondary: UInt32
    let light: Bool
    let oled: Bool

    static func current(_ scheme: ColorScheme) -> AsciiPalette {
        let appearance = AppAppearance.shared
        let oled = appearance.mode == .oled
        let light = scheme == .light && !oled
        let colors = light ? appearance.theme.light : appearance.theme.dark
        let value: (String, UInt32) -> UInt32 = { AppearanceColors.rgb($0) ?? $1 }
        return AsciiPalette(
            bg: oled ? 0x000000 : value(colors.background, light ? 0xFBFBFD : 0x08070D),
            accent: value(colors.accent, light ? 0x6A3DFF : 0xA786FF),
            secondary: value(colors.secondary, light ? 0xA21CAF : 0xE879F9),
            light: light, oled: oled)
    }

    func tint(_ k: Double) -> UInt32 { AsciiKit.mix(bg, accent, k) }

    var ramp: [UInt32] {
        [tint(0.35), tint(0.6), accent, AsciiKit.mix(accent, secondary, 0.5), secondary]
    }

    var glowStrength: Double { light ? 0.07 : oled ? 0.05 : 0.12 }
}

struct AsciiScene: Identifiable {
    let id: String
    var cell: ((Int, Int, Int, Int, Double, AsciiPalette) -> AsciiCell?)?
    var sprites: ((Int, Int, Double, AsciiPalette) -> [AsciiSprite])?

    static let all: [AsciiScene] = [AsciiScenes.dotWaves, AsciiScenes.dotCode]

    static func named(_ id: String) -> AsciiScene? { all.first { $0.id == id } }
}

enum AsciiColor {
    static func color(_ value: UInt32) -> Color {
        let (r, g, b) = AsciiKit.rgb(value)
        return Color(.sRGB, red: r, green: g, blue: b)
    }
}
