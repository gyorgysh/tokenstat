// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
//
// Source-available: source sharing and own builds are permitted.
// Store and commercial distribution of builds is reserved. See LICENSE.
// "tokenstat" is a trademark of pueev OU. See TRADEMARK.md.

import SwiftUI

struct PersonaTraits {
    enum BodyShape: Int { case ball, star, heart, tortilla }
    enum EyeShape { case round, oval, pixel }
    enum Mouth { case dot, smile, flat, frown }

    let bodyShape: BodyShape
    let hue: Color
    let faceInk: Color
    let bodyHighlight: Color
    let eyeCount: Int
    let eyeShape: EyeShape
    let mouth: Mouth?
    let hasAntenna: Bool
    let mouthWidth: CGFloat
    let firmness: CGFloat
    let lumps: [CGFloat]

    private static let heartOutline: [CGPoint] = (0..<64).map { i in
        let t = CGFloat(i) * 2 * .pi / 64
        return CGPoint(x: 16 * pow(sin(t), 3) / 17,
                       y: -(13 * cos(t) - 5 * cos(2 * t) - 2 * cos(3 * t) - cos(4 * t)) / 17)
    }

    private static func heartRadius(at angle: CGFloat) -> CGFloat {
        let dx = cos(angle), dy = sin(angle)
        var radius: CGFloat = 1
        for i in heartOutline.indices {
            let p = heartOutline[i], q = heartOutline[(i + 1) % heartOutline.count]
            let ex = q.x - p.x, ey = q.y - p.y
            let cross = dx * ey - dy * ex
            guard abs(cross) > 1e-8 else { continue }
            let u = (p.x * dy - p.y * dx) / cross
            let r = (p.x * ey - p.y * ex) / cross
            if u >= 0, u <= 1, r > 0 { radius = min(radius, r) }
        }
        return max(0.42, radius)
    }

    init(seed: UInt64, nodes: Int = 20) {
        bodyShape = BodyShape(rawValue: Int((seed >> 1) % 4))!
        var bits = seed == 0 ? 0x9E37_79B9_7F4A_7C15 : seed
        func next(_ modulo: UInt64) -> UInt64 {
            bits ^= bits << 13
            bits ^= bits >> 7
            bits ^= bits << 17
            return bits % modulo
        }
        _ = next(10)
        eyeCount = 2
        eyeShape = next(4) == 0 ? .round : .oval
        _ = next(5)
        mouth = .smile
        _ = next(3)
        hasAntenna = false
        mouthWidth = 0.72 + CGFloat(next(9)) * 0.035
        firmness = 0.95 + CGFloat(next(9)) * 0.03
        let firstPhase = CGFloat(next(360)) * .pi / 180
        let secondPhase = CGFloat(next(360)) * .pi / 180
        let firstAmount = 0.10 + CGFloat(next(100)) / 100 * 0.15
        let secondAmount = 0.04 + CGFloat(next(100)) / 100 * 0.07
        var lumps: [CGFloat] = []
        lumps.reserveCapacity(nodes)
        for index in 0..<nodes {
            let angle = CGFloat(index) * 2 * .pi / CGFloat(nodes)
            let silhouette: CGFloat = switch bodyShape {
            case .ball: 0
            case .star: -sin(5 * angle) * 0.24
            case .heart: Self.heartRadius(at: angle) - 1
            case .tortilla: (0.6 * cos(2 * angle) + 0.35 * sin(angle)) * 0.34
            }
            let softness = sin(angle * 2 + firstPhase) * firstAmount
                + sin(angle * 3 + secondPhase) * secondAmount
            lumps.append(silhouette * 10 + softness * 0.25)
        }
        self.lumps = lumps
        let palette = Theme.accent.mixed(with: Theme.secondary, by: Double(next(7)) / 6)
        hue = palette
        faceInk = palette.mixed(with: .black, by: 0.78)
        bodyHighlight = palette.mixed(with: .white, by: 0.34)
    }
}

extension Color {
    func mixed(with other: Color, by amount: Double) -> Color {
        let amount = min(max(amount, 0), 1)
        #if canImport(AppKit)
        guard let from = NSColor(self).usingColorSpace(.sRGB),
              let to = NSColor(other).usingColorSpace(.sRGB)
        else { return self }
        #else
        let from = UIColor(self)
        let to = UIColor(other)
        #endif
        var fromComponents = (r: CGFloat(0), g: CGFloat(0), b: CGFloat(0), a: CGFloat(0))
        var toComponents = (r: CGFloat(0), g: CGFloat(0), b: CGFloat(0), a: CGFloat(0))
        from.getRed(&fromComponents.r, green: &fromComponents.g, blue: &fromComponents.b, alpha: &fromComponents.a)
        to.getRed(&toComponents.r, green: &toComponents.g, blue: &toComponents.b, alpha: &toComponents.a)
        let mix = CGFloat(amount)
        return Color(
            .sRGB,
            red: Double(fromComponents.r + (toComponents.r - fromComponents.r) * mix),
            green: Double(fromComponents.g + (toComponents.g - fromComponents.g) * mix),
            blue: Double(fromComponents.b + (toComponents.b - fromComponents.b) * mix),
            opacity: Double(fromComponents.a + (toComponents.a - fromComponents.a) * mix)
        )
    }
}

func personaSeed(for identifier: String) -> UInt64 {
    var hash: UInt64 = 0xcbf2_9ce4_8422_2325
    for byte in identifier.utf8 {
        hash ^= UInt64(byte)
        hash = hash &* 0x0000_0100_0000_01b3
    }
    return hash | 1
}
