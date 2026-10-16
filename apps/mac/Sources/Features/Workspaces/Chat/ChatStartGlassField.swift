// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
import CoreGraphics
import Foundation

/// A small, bounded history of motion impulses. An impulse bends the optical
/// field; it never punches a transparent disc underneath the pointer.
struct ChatStartGlassWake {
    let point: CGPoint
    let velocity: CGVector
    let began: Double
}

struct ChatStartGlassTouch: Identifiable {
    let id = UUID()
    let point: CGPoint
    var began = Date.timeIntervalSinceReferenceDate
}

/// Broad, layered optical folds over the window's real native glass. The
/// image is deliberately small and smoothly reconstructed by Canvas: its
/// curves are measured in hundreds of points, not physical screen pixels.
/// This keeps the same effect on the macOS 14 / iOS 17 baseline without an
/// additional Metal toolchain or a full-resolution per-frame allocation.
enum ChatStartGlassField {
    static let touchLifetime = 9.0
    static let wakeLifetime = 5.5
    static let maximumWakes = 24

    struct Palette {
        let background: SIMD3<Float>
        let accent: SIMD3<Float>
        let secondary: SIMD3<Float>
        let dark: Bool
    }

    /// At rest only the slow optical clock advances. Interaction kernels
    /// ease in over several frames and retain momentum after input has ended.
    static func image(size: CGSize, time: Double, now: Double, touches: [ChatStartGlassTouch],
                      wakes: [ChatStartGlassWake], palette: Palette) -> CGImage? {
        guard size.width > 0, size.height > 0, size.width.isFinite, size.height.isFinite else { return nil }
        let scale = min(1, 96 / max(size.width, size.height))
        let width = max(2, Int(ceil(size.width * scale)))
        let height = max(2, Int(ceil(size.height * scale)))
        let count = width * height
        let flowWidth = max(2, width / 3)
        let flowHeight = max(2, height / 3)
        var shifts = Array(repeating: SIMD2<Float>.zero, count: flowWidth * flowHeight)
        var bends = Array(repeating: Float.zero, count: flowWidth * flowHeight)
        let flowScale = SIMD2<Float>(Float(size.width) / Float(flowWidth), Float(size.height) / Float(flowHeight))
        let pointScale = SIMD2<Float>(Float(size.width) / Float(width), Float(size.height) / Float(height))

        for wake in wakes {
            let age = now - wake.began
            guard age >= 0, age < wakeLifetime else { continue }
            let vx = Float(wake.velocity.dx), vy = Float(wake.velocity.dy)
            let speed = min(900, hypot(vx, vy))
            guard speed > 1 else { continue }
            let direction = SIMD2<Float>(vx, vy) / max(1, hypot(vx, vy))
            let arrival = ease(Float(age / 0.32))
            let decay = Float(exp(-age / 1.55)) * (1 - ease(Float((age - 3.8) / 1.7)))
            let amount = min(1, speed / 650) * arrival * decay
            let drift = direction * Float(22 * (1 - exp(-age / 1.4)))
            let center = SIMD2<Float>(Float(wake.point.x), Float(wake.point.y)) + drift
            let radius = Float(116 + age * 13)
            accumulate(center: center, radius: radius, width: flowWidth, height: flowHeight,
                       pointScale: flowScale, shifts: &shifts, bends: &bends) { offset, weight in
                // A trailing lateral curl carries a fold past the gesture.
                // No abrupt target-following alpha or state is used here.
                let perpendicular = SIMD2<Float>(-direction.y, direction.x)
                let curl = (offset.x * direction.y - offset.y * direction.x) / radius
                return (direction * (25 * amount * weight)
                    + perpendicular * (15 * curl * amount * weight), curl * amount * weight * 0.18)
            }
        }
        for touch in touches {
            let age = now - touch.began
            guard age >= 0, age < touchLifetime else { continue }
            let arrival = ease(Float(age / 0.85))
            let recovery = Float(exp(-age / 2.9)) * (1 - ease(Float((age - 6) / 3)))
            let amount = arrival * recovery
            let radius = Float(150 + 175 * (1 - exp(-age / 1.8)))
            let center = SIMD2<Float>(Float(touch.point.x), Float(touch.point.y))
            accumulate(center: center, radius: radius, width: flowWidth, height: flowHeight,
                       pointScale: flowScale, shifts: &shifts, bends: &bends) { offset, weight in
                let distance = max(1, hypot(offset.x, offset.y))
                let radial = offset / distance
                let curl = SIMD2<Float>(-radial.y, radial.x)
                let irregular = 0.88 + 0.12 * sin(offset.x * 0.014 + offset.y * 0.009)
                // Broad pressure bends the layers into an asymmetric slow fold.
                // The substrate stays intact; this is not an expanding ring.
                let displacement = (radial * 108 + curl * 31) * amount * weight * irregular
                return (displacement, (offset.x * 0.7 - offset.y * 0.45) / radius * amount * weight)
            }
        }

        let phase = Float(time)
        let tint = palette.accent * (palette.dark ? 0.78 : 0.62)
            + palette.background * (palette.dark ? 0.22 : 0.38)
        let highlight = palette.secondary * (palette.dark ? 0.62 : 0.30)
            + palette.background * (palette.dark ? 0.38 : 0.70)
        var pixels = Array(repeating: UInt8.zero, count: count * 4)
        for y in 0..<height {
            let flowY = max(0, min(Float(flowHeight - 1), (Float(y) + 0.5) * Float(flowHeight) / Float(height) - 0.5))
            let y0 = Int(flowY), y1 = min(flowHeight - 1, y0 + 1)
            let fy = flowY - Float(y0)
            for x in 0..<width {
                let index = y * width + x
                let flowX = max(0, min(Float(flowWidth - 1), (Float(x) + 0.5) * Float(flowWidth) / Float(width) - 0.5))
                let x0 = Int(flowX), x1 = min(flowWidth - 1, x0 + 1)
                let fx = flowX - Float(x0)
                let i0 = y0 * flowWidth + x0, i1 = y0 * flowWidth + x1
                let i2 = y1 * flowWidth + x0, i3 = y1 * flowWidth + x1
                let top = shifts[i0] * (1 - fx) + shifts[i1] * fx
                let bottom = shifts[i2] * (1 - fx) + shifts[i3] * fx
                let shift = top * (1 - fy) + bottom * fy
                let bendTop = bends[i0] * (1 - fx) + bends[i1] * fx
                let bendBottom = bends[i2] * (1 - fx) + bends[i3] * fx
                let bend = max(-0.2, min(0.2, bendTop * (1 - fy) + bendBottom * fy))
                let position = (SIMD2<Float>(Float(x) + 0.5, Float(y) + 0.5) * pointScale - shift) / 205
                let fold = sample(at: position, time: phase)
                // Optical depth comes from broad, overlapping translucent
                // layers. Only the side of a bend catches a quiet highlight.
                let alpha = (palette.dark ? 0.085 : 0.05)
                    + fold.x * (palette.dark ? 0.31 : 0.26)
                    + fold.z * (palette.dark ? 0.22 : 0.10)
                let tintMix = fold.y * 0.24 + fold.z * 0.18
                let sheen = SIMD3<Float>(repeating: palette.dark ? 0.78 : 1)
                let layer = tint * (1 - tintMix) + highlight * tintMix
                let color = layer * (1 - fold.z * 0.48) + sheen * fold.z * 0.48
                    + SIMD3<Float>(repeating: bend * (palette.dark ? 0.65 : 0.25))
                let dither = (noiseHash(x: x, y: y, seed: 417) - 0.5) / 255
                let offset = index * 4
                pixels[offset] = byte(min(1, max(0, color.x + dither)) * alpha)
                pixels[offset + 1] = byte(min(1, max(0, color.y + dither)) * alpha)
                pixels[offset + 2] = byte(min(1, max(0, color.z + dither)) * alpha)
                pixels[offset + 3] = byte(alpha)
            }
        }
        guard let provider = CGDataProvider(data: Data(pixels) as CFData) else { return nil }
        return CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32,
                       bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
                       bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                       provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent)
    }

    private static func accumulate(center: SIMD2<Float>, radius: Float, width: Int, height: Int,
                                   pointScale: SIMD2<Float>, shifts: inout [SIMD2<Float>], bends: inout [Float],
                                   response: (SIMD2<Float>, Float) -> (SIMD2<Float>, Float)) {
        let minX = max(0, min(width - 1, Int((center.x - radius) / pointScale.x)))
        let maxX = max(0, min(width - 1, Int((center.x + radius) / pointScale.x) + 1))
        let minY = max(0, min(height - 1, Int((center.y - radius) / pointScale.y)))
        let maxY = max(0, min(height - 1, Int((center.y + radius) / pointScale.y) + 1))
        guard minX <= maxX, minY <= maxY else { return }
        for y in minY...maxY {
            for x in minX...maxX {
                let offset = SIMD2<Float>(Float(x) + 0.5, Float(y) + 0.5) * pointScale - center
                let square = (offset.x * offset.x + offset.y * offset.y) / (radius * radius)
                guard square < 1 else { continue }
                let edge = 1 - square
                let (shift, bend) = response(offset, edge * edge * edge)
                let index = y * width + x
                shifts[index] += shift
                bends[index] += bend
            }
        }
    }

    /// Two curved optical layers travel at slightly different rates. The
    /// low-frequency warp keeps the folds asymmetric without smoke, particles,
    /// a noisy texture, or repeated concentric bands.
    private static func sample(at p: SIMD2<Float>, time: Float) -> SIMD3<Float> {
        let drift = SIMD2<Float>(time * 0.009, -time * 0.006)
        let q = SIMD2<Float>(valueNoise(p * 0.39 + drift, seed: 13),
                             valueNoise(p * 0.32 + SIMD2<Float>(4.7, 8.1) - drift * 0.7, seed: 31))
        let warped = p + (q - SIMD2<Float>(repeating: 0.5)) * 2.1
        let a = warped.x * 1.28 + warped.y * 0.42 + sin(warped.y * 0.8 + q.y) * 0.8 - time * 0.012
        let b = warped.y * 1.14 - warped.x * 0.53 + q.y * 1.6 + time * 0.008
        let first = 0.5 + 0.5 * sin(a)
        let second = 0.5 + 0.5 * sin(b)
        let depth = pow(first, 1.7) * 0.76 + pow(second, 2.4) * 0.24
        let primaryLight = pow(max(0, 1 - abs(sin(a + 0.55))), 7) * (0.45 + second * 0.55)
        let crossingLight = pow(max(0, 1 - abs(sin(b - 0.8))), 9) * first * 0.30
        let catchLight = min(1, primaryLight + crossingLight)
        return SIMD3<Float>(depth, second, catchLight)
    }

    private static func valueNoise(_ point: SIMD2<Float>, seed: UInt32) -> Float {
        let x = Int(floor(point.x)), y = Int(floor(point.y))
        let fx = ease(point.x - Float(x)), fy = ease(point.y - Float(y))
        let a = noiseHash(x: x, y: y, seed: seed)
        let b = noiseHash(x: x + 1, y: y, seed: seed)
        let c = noiseHash(x: x, y: y + 1, seed: seed)
        let d = noiseHash(x: x + 1, y: y + 1, seed: seed)
        return (a + (b - a) * fx) * (1 - fy) + (c + (d - c) * fx) * fy
    }

    private static func noiseHash(x: Int, y: Int, seed: UInt32) -> Float {
        var value = UInt32(truncatingIfNeeded: x) &* 0x8DA6B343
            ^ UInt32(truncatingIfNeeded: y) &* 0xD8163841 ^ seed
        value = (value ^ (value >> 13)) &* 0x85EBCA6B
        value ^= value >> 16
        return Float(value & 0x00FF_FFFF) / Float(0x00FF_FFFF)
    }

    private static func ease(_ value: Float) -> Float {
        let t = min(1, max(0, value))
        return t * t * (3 - 2 * t)
    }

    private static func byte(_ value: Float) -> UInt8 { UInt8(min(255, max(0, value * 255)).rounded()) }
}
