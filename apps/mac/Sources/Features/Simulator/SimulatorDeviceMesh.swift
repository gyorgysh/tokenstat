// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
#if os(macOS)
import simd
import CoreGraphics

/// Solid, rounded hardware with a separate front display. All dimensions are
/// generic proportions, rather than a claim to match a manufacturer's model.
struct SimulatorDeviceMesh {
    struct Vertex {
        var position: SIMD4<Float>
        var normal: SIMD4<Float>
        var color: SIMD4<Float>
        var texture: SIMD4<Float>
    }
    private(set) var vertices: [Vertex] = []
    let width: Float
    let height: Float
    let depth: Float

    init(aspect: Float, tablet: Bool) {
        let ratio = max(0.35, min(2.8, aspect))
        // Keep physical depth proportional to the long edge in either pose.
        // Scaling only width would turn a landscape phone into a thin slab.
        height = ratio > 1 ? 2.2 / ratio : 2.2
        width = ratio > 1 ? 2.2 : 2.2 * ratio
        depth = tablet ? 0.10 : 0.15
        let radius = min(width, height) * (tablet ? 0.045 : 0.105)
        let bezel: Float = tablet ? 0.045 : 0.025
        let metal = SIMD4<Float>(0.43, 0.47, 0.54, 0.9)
        let coating = SIMD4<Float>(0.13, 0.16, 0.21, 0.45)
        let glass = SIMD4<Float>(0.016, 0.022, 0.032, 0.35)
        box(width, height, depth, radius: radius, bevel: 0.012, color: metal)
        box(width - 0.018, height - 0.018, 0.012, radius: radius - 0.009,
            center: [0, 0, -depth / 2 - 0.003], color: coating)
        box(width - 0.012, height - 0.012, 0.008, radius: radius - 0.006,
            center: [0, 0, depth / 2 + 0.002], color: glass)
        face(width - bezel * 2, height - bezel * 2, radius: max(0.012, radius - bezel),
             z: depth / 2 + 0.007, color: [1, 1, 1, 0], screen: true)
        // Physical side buttons remain visible at edge-on and rear angles.
        box(0.027, 0.22, depth * 0.45, radius: 0.012,
            center: [width / 2 + 0.008, height * 0.22, 0], color: metal)
        for y: Float in [0.23, 0.08] {
            box(0.027, 0.11, depth * 0.42, radius: 0.012,
                center: [-width / 2 - 0.008, height * y, 0], color: metal)
        }
        let cameraX = -width / 2 + (tablet ? 0.13 : 0.17)
        let cameraY = height / 2 - (tablet ? 0.13 : 0.18)
        box(tablet ? 0.20 : 0.25, tablet ? 0.20 : 0.44, 0.035, radius: 0.055,
            center: [cameraX, cameraY - (tablet ? 0 : 0.08), -depth / 2 - 0.026], color: coating)
        for index in 0..<(tablet ? 1 : 2) {
            let y = cameraY - Float(index) * 0.20
            cylinder(radius: 0.077, length: 0.034, center: [cameraX, y, -depth / 2 - 0.05], color: metal)
            cylinder(radius: 0.061, length: 0.037, center: [cameraX, y, -depth / 2 - 0.055], color: glass)
            cylinder(radius: 0.025, length: 0.038, center: [cameraX - 0.008, y + 0.009, -depth / 2 - 0.057], color: [0.08, 0.14, 0.22, 0.8])
        }
        // A connector and speaker openings are inset into the bottom edge.
        box(0.14, 0.008, depth * 0.32, radius: 0.003,
            center: [0, -height / 2 - 0.001, 0], color: glass)
        for side: Float in [-1, 1] {
            for hole in 0..<4 {
                box(0.016, 0.008, 0.026, radius: 0.003,
                    center: [side * (0.14 + Float(hole) * 0.035), -height / 2 - 0.001, 0], color: glass)
            }
        }
    }

    private func perimeter(_ width: Float, _ height: Float, radius: Float) -> [(SIMD2<Float>, SIMD2<Float>)] {
        let r = max(0.001, min(radius, min(width, height) / 2))
        return (0..<64).map { index in
            let corner = index / 16
            let angle = Float(corner) * .pi / 2 + Float(index % 16) / 15 * .pi / 2
            let normal = SIMD2<Float>(cos(angle), sin(angle))
            let center = SIMD2<Float>(corner == 0 || corner == 3 ? width / 2 - r : -width / 2 + r,
                                      corner < 2 ? height / 2 - r : -height / 2 + r)
            return (center + normal * r, normal)
        }
    }
    private mutating func triangle(_ a: SIMD3<Float>, _ b: SIMD3<Float>, _ c: SIMD3<Float>,
                                   normals: (SIMD3<Float>, SIMD3<Float>, SIMD3<Float>), color: SIMD4<Float>) {
        for (point, normal) in [(a, normals.0), (b, normals.1), (c, normals.2)] {
            vertices.append(Vertex(position: SIMD4(point, 1), normal: SIMD4(normal, 0), color: color, texture: .zero))
        }
    }
    private mutating func face(_ width: Float, _ height: Float, radius: Float, z: Float,
                               center: SIMD3<Float> = .zero, color: SIMD4<Float>, screen: Bool = false, back: Bool = false) {
        let ring = perimeter(width, height, radius: radius)
        let normal = SIMD3<Float>(0, 0, back ? -1 : 1)
        for index in ring.indices {
            let a = ring[index].0, b = ring[(index + 1) % ring.count].0
            for point in [SIMD2<Float>.zero, a, b] {
                vertices.append(Vertex(position: SIMD4(center + SIMD3(point.x, point.y, z), 1),
                    normal: SIMD4(normal, 0), color: color,
                    texture: [point.x / width + 0.5, 0.5 - point.y / height, screen ? 1 : 0, 0]))
            }
        }
    }
    private mutating func box(_ width: Float, _ height: Float, _ depth: Float, radius: Float,
                              bevel: Float = 0.002, center: SIMD3<Float> = .zero, color: SIMD4<Float>) {
        let edge = min(bevel, depth / 3)
        let outer = perimeter(width, height, radius: radius)
        let inner = perimeter(width - edge * 2, height - edge * 2, radius: max(0.001, radius - edge))
        for side: Float in [-1, 1] {
            face(width - edge * 2, height - edge * 2, radius: max(0.001, radius - edge), z: side * depth / 2, center: center, color: color, back: side < 0)
        }
        let rings: [(Float, Float)] = [(-depth / 2, -1), (-depth / 2 + edge, 0), (depth / 2 - edge, 0), (depth / 2, 1)]
        for level in 0..<3 {
            for index in outer.indices {
                let next = (index + 1) % outer.count
                func corner(_ ring: Int, _ i: Int) -> (SIMD3<Float>, SIMD3<Float>) {
                    let (z, face) = rings[ring]
                    let xy = face == 0 ? outer[i].0 : inner[i].0
                    let n = simd_normalize(SIMD3<Float>(outer[i].1.x, outer[i].1.y, face))
                    return (center + SIMD3<Float>(xy.x, xy.y, z), n)
                }
                let a = corner(level, index), b = corner(level, next), c = corner(level + 1, index), d = corner(level + 1, next)
                triangle(a.0, b.0, c.0, normals: (a.1, b.1, c.1), color: color)
                triangle(b.0, d.0, c.0, normals: (b.1, d.1, c.1), color: color)
            }
        }
    }
    private mutating func cylinder(radius: Float, length: Float, center: SIMD3<Float>, color: SIMD4<Float>) {
        box(radius * 2, radius * 2, length, radius: radius, bevel: min(0.004, length / 4), center: center, color: color)
    }
}

/// Unit quaternions allow continuous rotation past the poles without a pitch
/// clamp, Euler-angle jumps or a front/back surface swap.
struct SimulatorOrbit {
    var rotation = simd_quatf(angle: -0.22, axis: [1, 0, 0]) * simd_quatf(angle: -0.32, axis: [0, 1, 0])
    mutating func rotate(from: SIMD3<Float>, to: SIMD3<Float>) -> simd_quatf {
        let delta = simd_quatf(from: from, to: to)
        rotation = simd_normalize(delta * rotation)
        return delta
    }
    mutating func advance(velocity: SIMD3<Float>, seconds: Float) {
        let speed = simd_length(velocity)
        guard speed > 0.0001, seconds > 0 else { return }
        rotation = simd_normalize(simd_quatf(angle: speed * seconds, axis: velocity / speed) * rotation)
    }
    static func point(_ point: CGPoint, in size: CGSize) -> SIMD3<Float> {
        let extent = Float(max(1, min(size.width, size.height)))
        let p = SIMD2<Float>((Float(point.x) * 2 - Float(size.width)) / extent,
                             (Float(point.y) * 2 - Float(size.height)) / extent)
        let squared = simd_length_squared(p)
        return squared < 1 ? SIMD3(p.x, p.y, sqrt(1 - squared)) : simd_normalize(SIMD3(p.x, p.y, 0))
    }
    static func deviceRotation(orientation: Int) -> simd_quatf {
        let angle: Float
        switch orientation { case 2: angle = .pi; case 3: angle = -.pi / 2; case 4: angle = .pi / 2; default: angle = 0 }
        return simd_quatf(angle: angle, axis: [0, 0, 1])
    }
}
#endif
