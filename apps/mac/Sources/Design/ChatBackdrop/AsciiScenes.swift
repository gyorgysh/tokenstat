// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
import SwiftUI

enum AsciiScenes {
    typealias K = AsciiKit

    static let dotWaves = AsciiScene(
        id: "dot-waves",
        cell: { x, y, cols, rows, t, palette in
            guard (x + y) % 2 == 0 else { return nil }
            let fx = Double(x), fy = Double(y)
            let ax = Double(cols) * (0.3 + 0.2 * sin(t * 0.07)), ay = Double(rows) * (0.4 + 0.25 * cos(t * 0.05))
            let ripple = sin(hypot(fx - ax, (fy - ay) * 1.3) * 0.42 - t * 1.6)
            let swell = sin(fx * 0.11 + t * 0.55) + sin(fy * 0.17 - t * 0.4) + sin((fx - fy) * 0.07 + t * 0.3)
            let v = (ripple * 0.45 + swell / 3 * 0.55 + 1) / 2
            guard v > 0.42 else { return nil }
            let level = (v - 0.42) / 0.58
            let color = K.pick(palette.ramp, level)
            if level > 0.93, K.noise(x, y, 7) < 0.5 {
                return AsciiCell("+", palette.light ? palette.bg : 0xFFFFFF, a: 0.85, dot: color)
            }
            return .dot(color, a: (palette.light ? 0.18 : 0.12) + level * (palette.light ? 0.55 : 0.7))
        },
        sprites: { cols, rows, t, palette in
            (0..<3).map { i in
                let speed = 0.6 + K.noise(i, 3) * 0.5
                let x = K.wrap(K.noise(i, 1) * Double(cols) + t * speed * 4, Double(cols + 20)) - 10
                let y = Double(rows) * (0.2 + 0.6 * K.noise(i, 2)) + sin(t * 0.4 + Double(i)) * 3
                let core: UInt32 = palette.light ? palette.accent : 0xFFFFFF
                return AsciiSprite(art: AsciiArt(["o"]), pal: ["o": .dot(core, a: 0.9)], x: x, y: y,
                                   glow: AsciiGlow(r: 6, color: palette.accent, a: palette.light ? 0.18 : 0.35))
            }
        }
    )

    private static let codeGlyphs: [Character] = Array("01{}<>/;=()#$*")

    static let dotCode = AsciiScene(
        id: "dot-code",
        cell: { x, y, cols, rows, t, palette in
            guard x % 2 == 0, y % 2 == 0 else { return nil }
            let dx = Double(x) - Double(cols) / 2, dy = (Double(y) - Double(rows)) * 1.4
            let travel = sin(hypot(dx, dy) * 0.09 + t * 0.7)
            let wave = pow(0.5 + 0.5 * travel, 6)
            let tick = K.cellFloor(t * 0.45 + K.noise(x, y, 61) * 9)
            if K.noise(x, y, tick) < 0.012 {
                return AsciiCell(K.pick(codeGlyphs, K.noise(x, y, tick + 1)), palette.tint(0.75), a: (palette.light ? 0.6 : 0.4) + wave * 0.35)
            }
            let low = palette.tint(palette.light ? 0.3 : 0.45), high = palette.tint(palette.light ? 0.85 : 1)
            return .dot(K.mix(low, high, wave), a: (palette.light ? 0.35 : 0.16) + wave * 0.34, size: 0.3 + wave * 0.18)
        }
    )
}
