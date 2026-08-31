// SPDX-License-Identifier: LicenseRef-tokenstat-source-available

import SwiftUI

/// The four colours the persona engine reads, and nothing else.
///
/// The engine files under `Engine/` are symlinks to the app's own, so they say
/// `Theme.accent` exactly as they do inside the app. This stands in for the
/// app's `Theme` here, which is what keeps the lab from having to link the
/// whole design system, the FFI and the host bridge to draw a blob.
///
/// The values are copied from `apps/mac/Sources/Design/Theme.swift`. If the
/// accent moves there, move it here too, or the lab will be tuning against a
/// colour the app does not use.
enum Theme {
    static let accent = Color.adaptive(light: hex(0x6A3DFF), dark: hex(0x8B5CF6))
    static let secondary = Color.adaptive(light: hex(0xC026D3), dark: hex(0xE879F9))
    static let warning = Color(red: 0xE0 / 255, green: 0xA9 / 255, blue: 0x3B / 255)
    static let danger = Color(red: 0xD6 / 255, green: 0x45 / 255, blue: 0x3F / 255)

    static func hex(_ value: UInt32) -> Color {
        Color(
            red: Double((value >> 16) & 0xFF) / 255,
            green: Double((value >> 8) & 0xFF) / 255,
            blue: Double(value & 0xFF) / 255
        )
    }
}

extension Color {
    static func adaptive(light: Color, dark: Color) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            let isDark = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            return NSColor(isDark ? dark : light)
        })
    }
}
