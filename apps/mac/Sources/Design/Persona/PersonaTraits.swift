// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
//
// Source-available for review, NOT open source. See LICENSE: no rights to
// redistribute, publish, or ship a build are granted. Read it, study it, run
// your own build of it.
// "tokenstat" is a trademark of pueev OU. See TRADEMARK.md.

import SwiftUI

/// The fixed features of one character, derived from its seed.
///
/// Deterministic and cheap: the same persona is the same creature on every
/// launch, on every device, with nothing stored but the number. Nothing here
/// changes with mood, and the mood cannot reach in and edit it.
///
/// Two of these traits are physics rather than looks. `firmness` scales every
/// spring in the body, so one persona is a firm gel that snaps back and
/// another is slack slime that keeps wobbling. `lumps` gives each silhouette
/// its own permanent dents. Together they mean two personas doing the same
/// thing still do not move the same way, which is the difference between a
/// cast and a mascot repeated.
struct PersonaTraits {
    /// How this creature's eyes are drawn when they are open. Curved arcs are
    /// deliberately not in here: a persona whose eyes were permanently two
    /// curves could not look up, narrow them, or open them wide, so every mood
    /// landed on the same face. Arcs are an expression, not a feature.
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
    /// How wide this creature's mouth sits, as a multiplier.
    let mouthWidth: CGFloat
    /// Stiffness multiplier. Below one is slime, above one is gel.
    let firmness: CGFloat
    /// A permanent radial offset per node: this creature's own dents.
    let lumps: [CGFloat]

    // Sample the familiar heart outline once; ray intersections keep its point
    // and soft shoulders instead of turning it into a notched ball.
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
        // Keep the identity draw order stable: existing chats retain their hue.
        _ = next(10)
        eyeCount = 2
        eyeShape = next(4) == 0 ? .round : .oval
        _ = next(5)
        mouth = .smile
        _ = next(3)
        hasAntenna = false
        mouthWidth = 0.72 + CGFloat(next(9)) * 0.035
        firmness = 0.95 + CGFloat(next(9)) * 0.03
        // Two low harmonics rather than per-node noise. Noise reads as a
        // damaged circle, harmonics read as a shape somebody drew.
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
        // Resolve platform colors once per identity, never in the frame loop.
        faceInk = palette.mixed(with: .black, by: 0.78)
        bodyHighlight = palette.mixed(with: .white, by: 0.34)
    }
}

extension Color {
    /// Blend towards another colour. Used to walk the accent-to-secondary arc
    /// so a persona's tint is always a colour this app already owns.
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

/// A face for something that has no persona.
///
/// Every conversation gets a character, whether or not anybody made one, so
/// the transcript is never a row of grey dots waiting for a feature to be
/// used. Derived from the conversation's own id, so it is that chat's face for
/// as long as the chat exists.
///
/// The same FNV-1a as `chat_turn::stable_hash` on the host, on purpose: a
/// persona seeded there and a chat seeded here have to sit in the same family,
/// and a second hash function would be a second set of faces.
func personaSeed(for identifier: String) -> UInt64 {
    var hash: UInt64 = 0xcbf2_9ce4_8422_2325
    for byte in identifier.utf8 {
        hash ^= UInt64(byte)
        hash = hash &* 0x0000_0100_0000_01b3
    }
    return hash | 1
}
