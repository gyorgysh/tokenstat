// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
#if os(macOS)
import simd
import CoreGraphics

/// Procedural, solid hardware families with a separate live display.
/// Dimensions are illustrative proportions, rather than exact CAD measurements.
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

    private(set) var rearCameraCenters: [SIMD3<Float>] = []
    /// Include lenses, buttons and the hinge in the fit at every orbit angle.
    var boundingRadius: Float { vertices.reduce(0) { max($0, simd_length(SIMD3($1.position.x, $1.position.y, $1.position.z))) } }

    init(aspect: Float, hardware: SimulatorHardware, innerDisplay: Bool = false) {
        let ratio = aspect.isFinite ? max(0.35, min(2.8, aspect)) : 0.46
        height = ratio > 1 ? 2.2 / ratio : 2.2
        width = ratio > 1 ? 2.2 : 2.2 * ratio
        let openDuo = hardware == .iPhoneDuo && innerDisplay
        depth = openDuo ? 0.07 : hardware.depth
        // Duo's inner panel has a landscape physical orientation, even when
        // its framebuffer arrives in portrait. Rotate hardware with its UVs.
        let transpose = openDuo && ratio < 1
        let w = transpose ? height : width, h = transpose ? width : height
        let radius = min(w, h) * (hardware.isTablet ? 0.045 : (hardware == .iPhoneDuo ? 0.065 : 0.105))
        let bezel: Float = hardware.isTablet ? 0.042 : 0.025
        let metal = SIMD4<Float>(0.56, 0.60, 0.66, 0.85)
        let coating = SIMD4<Float>(0.28, 0.33, 0.41, 0.24)
        let glass = SIMD4<Float>(0.016, 0.022, 0.032, 0.55)
        if hardware == .iPhoneDuo && !openDuo {
            // Two enclosures, a real gap and a separate hinge, not a thick slab.
            for side: Float in [-1, 1] {
                box(w, h, depth / 2 - 0.006, radius: radius, bevel: 0.008,
                    center: [0, 0, side * (depth / 4 + 0.003)], color: metal)
            }
        } else { box(w, h, depth, radius: radius, bevel: 0.009, color: metal) }
        box(w - 0.018, h - 0.018, 0.012, radius: radius - 0.009,
            center: [0, 0, -depth / 2 - 0.003], color: coating)
        box(w - 0.012, h - 0.012, 0.008, radius: radius - 0.006,
            center: [0, 0, depth / 2 + 0.002], color: glass)
        let screenHeight = hardware.hasHomeButton ? h - 0.40 : h - bezel * 2
        face(w - bezel * 2, screenHeight, radius: hardware.hasHomeButton ? 0.008 : max(0.012, radius - bezel),
             z: depth / 2 + 0.007, color: [1, 1, 1, 0], screen: true)
        // System cutouts already exist in the live framebuffer. Add only the
        // physical home button and earpiece outside legacy displays.
        if hardware.hasHomeButton {
            cylinder(radius: 0.058, length: 0.006, center: [0, -h / 2 + 0.097, depth / 2 + 0.005], color: metal)
            cylinder(radius: 0.047, length: 0.008, center: [0, -h / 2 + 0.097, depth / 2 + 0.007], color: glass)
            box(0.14, 0.014, 0.008, radius: 0.006, center: [0, h / 2 - 0.10, depth / 2 + 0.007], color: glass)
        }
        if hardware.isTablet {
            box(0.17, 0.022, depth * 0.5, radius: 0.009, center: [-w * 0.30, h / 2 + 0.006, 0], color: metal)
            for y: Float in [0.34, 0.23] {
                box(0.022, 0.12, depth * 0.5, radius: 0.009, center: [w / 2 + 0.006, h * y, 0], color: metal)
            }
        } else {
            box(0.025, 0.22, depth * 0.48, radius: 0.011, center: [w / 2 + 0.008, h * 0.22, 0], color: metal)
            for y: Float in [0.23, 0.08] {
                box(0.025, 0.11, depth * 0.45, radius: 0.011, center: [-w / 2 - 0.008, h * y, 0], color: metal)
            }
            box(0.022, 0.065, depth * 0.42, radius: 0.008, center: [-w / 2 - 0.008, h * 0.33, 0], color: metal)
        }
        if hardware == .iPhoneProPlateau || hardware == .iPhoneAir {
            box(0.018, 0.18, depth * 0.45, radius: 0.008, center: [w / 2 + 0.007, -h * 0.22, 0], color: coating)
        }
        addCameras(width: w, height: h, hardware: hardware, openDuo: openDuo, metal: metal, coating: coating, glass: glass)
        if hardware == .iPhoneDuo {
            let hingeX: Float = openDuo ? 0 : -w / 2
            box(0.035, h - 0.08, depth - 0.012, radius: 0.014, center: [hingeX, 0, 0], color: metal)
            if openDuo {
                // The other enclosure carries the inactive outer display.
                box(w / 2 - 0.05, h - 0.06, 0.009, radius: radius * 0.8,
                    center: [-w / 4, 0, -depth / 2 - 0.015], color: glass)
                box(0.012, h - 0.08, 0.012, radius: 0.004, center: [0, 0, -depth / 2 - 0.014], color: glass)
            } else {
                for y: Float in [-0.42, 0.42] {
                    box(0.042, 0.012, depth - 0.008, radius: 0.004, center: [hingeX, h * y, 0], color: glass)
                }
            }
        }
        // Connector, speaker openings and antenna breaks remain solid geometry.
        box(0.14, 0.008, depth * 0.32, radius: 0.003, center: [0, -h / 2 - 0.001, 0], color: glass)
        for side: Float in [-1, 1] {
            for hole in 0..<4 {
                box(0.016, 0.008, 0.026, radius: 0.003,
                    center: [side * (0.14 + Float(hole) * 0.035), -h / 2 - 0.001, 0], color: glass)
            }
            for y: Float in [-0.36, 0.36] {
                box(0.009, 0.012, depth * 0.9, radius: 0.003, center: [side * w / 2, h * y, 0], color: coating)
            }
        }
        if [.iPadPro, .iPadProDual, .iPadProThin].contains(hardware) {
            for x: Float in [-0.06, 0, 0.06] {
                cylinder(radius: 0.015, length: 0.008, center: [x, -h / 2 + 0.13, -depth / 2 - 0.012], color: metal)
            }
        }
        if transpose {
            for index in vertices.indices {
                let p = vertices[index].position, n = vertices[index].normal
                vertices[index].position = [-p.y, p.x, p.z, 1]
                vertices[index].normal = [-n.y, n.x, n.z, 0]
                if vertices[index].texture.z == 1 {
                    vertices[index].texture.x = -p.y / (width - bezel * 2) + 0.5
                    vertices[index].texture.y = 0.5 - p.x / (height - bezel * 2)
                }
            }
            rearCameraCenters = rearCameraCenters.map { [-$0.y, $0.x, $0.z] }
        }
    }

    private mutating func addCameras(width w: Float, height h: Float, hardware: SimulatorHardware, openDuo: Bool,
                                     metal: SIMD4<Float>, coating: SIMD4<Float>, glass: SIMD4<Float>) {
        let back = -depth / 2 - 0.012
        // Positive X is the left side when viewed from behind the device.
        var center = SIMD2<Float>(w / 2 - 0.25, h / 2 - 0.28)
        var lenses: [SIMD2<Float>] = []
        var lensRadius: Float = 0.087
        var flash: SIMD2<Float>?
        var lidar: SIMD2<Float>?
        func point(_ x: Float, _ y: Float) -> SIMD2<Float> { center + SIMD2(x, y) }
        func bump(_ width: Float, _ height: Float, _ radius: Float) {
            box(width, height, 0.032, radius: radius, bevel: 0.007,
                center: [center.x, center.y, back - 0.012], color: coating)
        }
        switch hardware.cameras {
        case .triple, .plateau:
            center = [w / 2 - 0.28, h / 2 - 0.32]
            if hardware.cameras == .plateau {
                box(w - 0.07, 0.56, 0.042, radius: 0.09, bevel: 0.009,
                    center: [0, center.y, back - 0.015], color: metal)
                box(w - 0.13, h - 0.76, 0.010, radius: 0.09, center: [0, -0.30, back - 0.003], color: coating)
                flash = [-w / 2 + 0.16, center.y + 0.13]; lidar = [-w / 2 + 0.16, center.y - 0.13]
            } else { bump(0.51, 0.54, 0.09); flash = point(-0.13, 0.17); lidar = point(-0.13, -0.17) }
            lenses = [point(0.12, 0.13), point(0.12, -0.13), point(-0.11, 0)]
            lensRadius = 0.10
        case .square, .diagonal:
            bump(0.42, 0.44, 0.085)
            lenses = hardware.cameras == .diagonal ? [point(0.095, 0.105), point(-0.095, -0.105)] : [point(0.08, 0.105), point(0.08, -0.105)]
            flash = point(-0.10, 0.12)
        case .air:
            center = [0, h / 2 - 0.20]
            bump(w - 0.07, 0.30, 0.10)
            lenses = [point(w / 2 - 0.18, 0)]; flash = point(-w / 2 + 0.17, 0)
            lensRadius = 0.095
        case .duo, .horizontal:
            center = [w / 2 - 0.37, h / 2 - 0.22]
            if openDuo { center.x = w / 4 }
            bump(0.62, 0.29, 0.12)
            lenses = [point(0.19, 0), point(-0.02, 0)]; flash = point(-0.23, -0.04)
            lensRadius = hardware == .iPhoneHomeDual ? 0.07 : 0.09
        case .single:
            center = [w / 2 - 0.17, h / 2 - 0.18]
            lenses = [center]; flash = point(-0.19, 0)
            lensRadius = 0.08
        case .tablet, .tabletPro, .tabletDual:
            center = [w / 2 - 0.13, h / 2 - 0.14]
            lensRadius = 0.058
            lenses = [center]
            if hardware.cameras != .tablet {
                center = [w / 2 - 0.17, h / 2 - 0.19]
                bump(0.27, 0.29, 0.055)
                lenses = [point(0.045, 0.06)]; flash = point(-0.065, 0.06)
                if hardware.cameras == .tabletDual { lenses.append(point(0.045, -0.065)) }
                if hardware != .iPadPro { lidar = point(-0.065, -0.065) }
            }
        case .vertical:
            center = [w / 2 - 0.18, h / 2 - 0.29]
            bump(0.25, 0.45, 0.12)
            lenses = [point(0, 0.105), point(0, -0.105)]; flash = point(-0.19, 0)
        }
        for position in lenses {
            let center = SIMD3<Float>(position.x, position.y, back - 0.044)
            rearCameraCenters.append(center)
            cylinder(radius: lensRadius, length: 0.034, center: center, color: metal)
            cylinder(radius: lensRadius * 0.81, length: 0.018, center: center - [0, 0, 0.012], color: glass)
            cylinder(radius: lensRadius * 0.38, length: 0.004, center: center - [0, 0, 0.021], color: [0.055, 0.09, 0.15, 0.75])
            cylinder(radius: lensRadius * 0.12, length: 0.003, center: center + [0.018, 0.022, -0.024], color: [0.22, 0.29, 0.40, 0.5])
        }
        if let flash { cylinder(radius: 0.027, length: 0.012, center: [flash.x, flash.y, back - 0.034], color: [0.86, 0.84, 0.73, 0.25]) }
        if let lidar { cylinder(radius: 0.026, length: 0.012, center: [lidar.x, lidar.y, back - 0.034], color: glass) }
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
