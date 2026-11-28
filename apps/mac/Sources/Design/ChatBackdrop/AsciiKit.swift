// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
import Foundation

struct AsciiCell {
    var ch: Character
    var fg: UInt32
    var dot: UInt32?
    var a: Double
    var size: Double

    init(_ ch: Character, _ fg: UInt32, a: Double, dot: UInt32? = nil, size: Double = 1) {
        self.ch = ch
        self.fg = fg
        self.dot = dot
        self.a = a
        self.size = size
    }

    static func dot(_ fill: UInt32, a: Double, size: Double = 1) -> AsciiCell {
        AsciiCell(" ", 0, a: a, dot: fill, size: size)
    }

    func faded(_ k: Double) -> AsciiCell {
        var copy = self
        copy.a *= k
        return copy
    }
}

final class AsciiArt {
    let rows: [[Character]]
    let width: Int
    var height: Int { rows.count }

    init(_ rows: [String]) {
        self.rows = rows.map(Array.init)
        width = self.rows.map(\.count).max() ?? 0
    }
}

struct AsciiGlow {
    var r: Double
    var color: UInt32
    var a: Double
}

struct AsciiSprite {
    var art: AsciiArt
    var pal: [Character: AsciiCell]
    var x: Double
    var y: Double
    var a: Double = 1
    var glow: AsciiGlow?
}

enum AsciiKit {
    static func noise(_ a: Int, _ b: Int, _ c: Int = 0) -> Double {
        var h = UInt32(truncatingIfNeeded: a) &* 0x9E37_79B1
        h ^= UInt32(truncatingIfNeeded: b) &* 0x85EB_CA77
        h ^= UInt32(truncatingIfNeeded: c) &* 0xC2B2_AE3D
        h ^= h >> 16
        h &*= 0x7FEB_352D
        h ^= h >> 15
        h &*= 0x846C_A68B
        h ^= h >> 16
        return Double(h) / 4_294_967_296
    }

    static func cellFloor(_ v: Double) -> Int { Int(v.rounded(.down)) }

    static func wrap(_ value: Double, _ span: Double) -> Double {
        let r = value.truncatingRemainder(dividingBy: span)
        return r < 0 ? r + span : r
    }

    static func pick<T>(_ items: [T], _ seed: Double) -> T {
        let scaled = seed * Double(items.count)
        let index = scaled.isFinite ? Int(max(0, min(scaled, Double(items.count - 1)))) : 0
        return items[index]
    }

    static func rgb(_ c: UInt32) -> (Double, Double, Double) {
        (Double((c >> 16) & 255) / 255, Double((c >> 8) & 255) / 255, Double(c & 255) / 255)
    }

    static func hex(_ r: Double, _ g: Double, _ b: Double) -> UInt32 {
        let q: (Double) -> UInt32 = { UInt32(max(0, min(255, ($0 * 255).rounded()))) }
        return q(r) << 16 | q(g) << 8 | q(b)
    }

    static func mix(_ a: UInt32, _ b: UInt32, _ k: Double) -> UInt32 {
        let (ar, ag, ab) = rgb(a), (br, bg, bb) = rgb(b)
        return hex(ar + (br - ar) * k, ag + (bg - ag) * k, ab + (bb - ab) * k)
    }

    static func luminance(_ c: UInt32) -> Double {
        let (r, g, b) = rgb(c)
        return 0.2126 * r + 0.7152 * g + 0.0722 * b
    }

}
