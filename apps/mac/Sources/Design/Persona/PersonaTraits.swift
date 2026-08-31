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
    enum EyeShape { case round, oval, pixel }
    enum Mouth { case dot, smile, flat, frown }

    let hue: Color
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

    init(seed: UInt64, nodes: Int = 14) {
        var bits = seed == 0 ? 0x9E37_79B9_7F4A_7C15 : seed
        func next(_ modulo: UInt64) -> UInt64 {
            bits ^= bits << 13
            bits ^= bits >> 7
            bits ^= bits << 17
            return bits % modulo
        }
        eyeCount = switch next(10) {
        case 0, 1: 1
        case 2: 3
        default: 2
        }
        eyeShape = switch next(4) {
        case 0: .round
        case 1: .pixel
        default: .oval
        }
        mouth = switch next(5) {
        case 0: .smile
        case 1: .flat
        case 2: .dot
        default: nil
        }
        hasAntenna = next(3) == 0
        mouthWidth = 0.78 + CGFloat(next(9)) * 0.06
        firmness = 0.78 + CGFloat(next(9)) * 0.055
        // Two low harmonics rather than per-node noise. Noise reads as a
        // damaged circle, harmonics read as a shape somebody drew.
        let firstPhase = CGFloat(next(360)) * .pi / 180
        let secondPhase = CGFloat(next(360)) * .pi / 180
        let firstAmount = 0.35 + CGFloat(next(100)) / 100 * 0.45
        let secondAmount = CGFloat(next(100)) / 100 * 0.30
        var lumps: [CGFloat] = []
        lumps.reserveCapacity(nodes)
        for index in 0..<nodes {
            let angle = CGFloat(index) * 2 * .pi / CGFloat(nodes)
            lumps.append(
                sin(angle * 2 + firstPhase) * firstAmount
                    + sin(angle * 3 + secondPhase) * secondAmount
            )
        }
        self.lumps = lumps
        hue = Theme.accent.mixed(with: Theme.secondary, by: Double(next(7)) / 6)
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
