// SPDX-License-Identifier: LicenseRef-tokenstat-source-available

#if !os(macOS)
import SceneKit
import SwiftUI
import UIKit

struct ClientReviewGem: UIViewRepresentable {
    var accent: Color
    var secondary: Color
    var reduceMotion: Bool

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIView(context: Context) -> SCNView {
        let view = SCNView(frame: .zero)
        view.backgroundColor = .clear
        view.antialiasingMode = .multisampling4X
        view.preferredFramesPerSecond = 60
        view.rendersContinuously = !reduceMotion
        let scene = SCNScene()
        view.scene = scene
        context.coordinator.build(in: scene, accent: UIColor(accent), secondary: UIColor(secondary),
                                  reduceMotion: reduceMotion)
        view.addGestureRecognizer(UIPanGestureRecognizer(target: context.coordinator,
                                                         action: #selector(Coordinator.pan(_:))))
        view.addGestureRecognizer(UITapGestureRecognizer(target: context.coordinator,
                                                         action: #selector(Coordinator.tap(_:))))
        return view
    }

    func updateUIView(_ view: SCNView, context: Context) {}

    static func dismantleUIView(_ view: SCNView, coordinator: Coordinator) {
        coordinator.stop()
    }

    @MainActor
    final class Coordinator: NSObject {
        private let pivot = SCNNode()
        private let star = SCNNode()
        private let glare = SCNNode()
        private let sparkles = SCNParticleSystem()
        private var velocity = CGPoint.zero
        private var yaw: Float = 0.3
        private var pitch: Float = -0.08
        private var dragging = false
        private static let maxPitch: Float = 0.18
        private var link: CADisplayLink?
        private var reduceMotion = false
        private static let idleKey = "idle"

        func build(in scene: SCNScene, accent: UIColor, secondary: UIColor, reduceMotion: Bool) {
            self.reduceMotion = reduceMotion
            let camera = SCNNode()
            camera.camera = SCNCamera()
            camera.camera?.fieldOfView = 32
            camera.position = SCNVector3(0, 0, 5.4)
            scene.rootNode.addChildNode(camera)

            addLight(.ambient, color: UIColor(white: 0.24, alpha: 1), to: scene)
            addLight(.directional, color: .white, intensity: 560, angles: SCNVector3(-0.55, -0.45, 0), to: scene)
            addLight(.directional, color: secondary, intensity: 300, angles: SCNVector3(0.9, 0.6, 0), to: scene)
            addLight(.omni, color: .white, intensity: 70, position: SCNVector3(1.2, 1.5, 3.0), to: scene)

            glare.geometry = Self.glarePlane(tint: accent)
            glare.constraints = [SCNBillboardConstraint()]
            glare.position = SCNVector3(0, 0, -0.2)
            glare.opacity = 0.22
            scene.rootNode.addChildNode(glare)

            star.geometry = Self.starGeometry(accent: accent, secondary: secondary)
            pivot.addChildNode(star)
            scene.rootNode.addChildNode(pivot)
            pivot.eulerAngles = SCNVector3(pitch, yaw, 0)

            guard !reduceMotion else { return }

            sparkles.particleImage = Self.sparkleImage()
            sparkles.emitterShape = SCNSphere(radius: 1.05)
            sparkles.birthLocation = .surface
            sparkles.birthRate = 5
            sparkles.particleLifeSpan = 1.1
            sparkles.particleLifeSpanVariation = 0.5
            sparkles.particleSize = 0.07
            sparkles.particleSizeVariation = 0.05
            sparkles.particleVelocity = 0.25
            sparkles.particleVelocityVariation = 0.2
            sparkles.spreadingAngle = 180
            sparkles.particleColor = UIColor(white: 1, alpha: 0.75)
            sparkles.particleColorVariation = SCNVector4(0.08, 0.2, 0, 0)
            sparkles.blendMode = .additive
            sparkles.isLightingEnabled = false
            let fade = CAKeyframeAnimation()
            fade.values = [0, 1, 1, 0]
            fade.keyTimes = [0, 0.15, 0.6, 1]
            sparkles.propertyControllers = [.opacity: SCNParticlePropertyController(animation: fade)]
            scene.rootNode.addParticleSystem(sparkles)

            star.scale = SCNVector3(0.01, 0.01, 0.01)
            let grow = SCNAction.scale(to: 1, duration: 0.6)
            grow.timingFunction = { t in
                let s: Float = 1.70158
                let u = t - 1
                return u * u * ((s + 1) * u + s) + 1
            }
            star.runAction(.sequence([
                .wait(duration: 0.15),
                .group([grow, .rotateBy(x: 0, y: .pi * 2, z: 0, duration: 0.8)]),
            ])) { [weak self] in
                Task { @MainActor in self?.idle() }
            }
            velocity = CGPoint(x: 9, y: 0)
            startLink()
        }

        private func addLight(_ type: SCNLight.LightType, color: UIColor, intensity: CGFloat = 1000,
                              angles: SCNVector3? = nil, position: SCNVector3? = nil, to scene: SCNScene) {
            let node = SCNNode()
            node.light = SCNLight()
            node.light?.type = type
            node.light?.color = color
            node.light?.intensity = intensity
            if let angles { node.eulerAngles = angles }
            if let position { node.position = position }
            scene.rootNode.addChildNode(node)
        }

        private func idle() {
            guard !reduceMotion else { return }
            star.runAction(.repeatForever(.rotateBy(x: 0, y: .pi * 2, z: 0, duration: 6)), forKey: Self.idleKey)
        }

        @objc func pan(_ gesture: UIPanGestureRecognizer) {
            guard let view = gesture.view else { return }
            switch gesture.state {
            case .began:
                dragging = true
                star.removeAction(forKey: Self.idleKey)
                startLink()
            case .changed:
                let t = gesture.translation(in: view)
                gesture.setTranslation(.zero, in: view)
                velocity = t
                turn(by: t)
            case .ended, .cancelled:
                dragging = false
                let v = gesture.velocity(in: view)
                velocity = CGPoint(x: v.x / 60, y: 0)
            default: break
            }
        }

        @objc func tap(_ gesture: UITapGestureRecognizer) {
            star.removeAction(forKey: Self.idleKey)
            velocity = CGPoint(x: velocity.x + 38, y: velocity.y)
            startLink()
        }

        private func turn(by delta: CGPoint) {
            yaw += Float(delta.x) * 0.012
            pitch = min(Self.maxPitch, max(-Self.maxPitch, pitch + Float(delta.y) * 0.004))
            pivot.eulerAngles = SCNVector3(pitch, yaw, 0)
        }

        private func startLink() {
            guard link == nil else { return }
            link = CADisplayLink(target: self, selector: #selector(step))
            link?.add(to: .main, forMode: .common)
        }

        @objc private func step() {
            let speed = hypot(velocity.x, velocity.y)
            let energy = min(1, speed / 30)
            glare.opacity = 0.22 + 0.4 * energy
            glare.scale = SCNVector3(Float(1 + 0.35 * energy), Float(1 + 0.35 * energy), 1)
            sparkles.birthRate = reduceMotion ? 0 : 4 + 90 * energy
            sparkles.particleVelocity = 0.25 + 1.4 * energy
            velocity = CGPoint(x: velocity.x * 0.95, y: velocity.y * 0.95)
            if !dragging { turn(by: CGPoint(x: velocity.x, y: 0)) }
            if !dragging {
                pitch += (-0.08 - pitch) * 0.08
                pivot.eulerAngles = SCNVector3(pitch, yaw, 0)
            }
            if speed < 0.05, !dragging {
                velocity = .zero
                stop()
                glare.opacity = 0.22
                sparkles.birthRate = reduceMotion ? 0 : 5
                if star.action(forKey: Self.idleKey) == nil { idle() }
            }
        }

        func stop() {
            link?.invalidate()
            link = nil
        }


        private static func starGeometry(accent: UIColor, secondary: UIColor) -> SCNGeometry {
            let outer: Float = 1.0, inner: Float = 0.4, rim: Float = 0.045, peak: Float = 0.26
            let ring: [SIMD2<Float>] = (0..<10).map { index in
                let angle = Float(index) * .pi / 5 + .pi / 2
                let radius = index.isMultiple(of: 2) ? outer : inner
                return SIMD2(cos(angle) * radius, sin(angle) * radius)
            }
            var positions: [SIMD3<Float>] = []
            var normals: [SIMD3<Float>] = []
            var colors: [SIMD4<Float>] = []
            func rgba(_ color: UIColor, _ light: CGFloat) -> SIMD4<Float> {
                var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
                color.getRed(&r, green: &g, blue: &b, alpha: &a)
                return SIMD4(Float(min(1, r * light)), Float(min(1, g * light)), Float(min(1, b * light)), 1)
            }
            func face(_ a: SIMD3<Float>, _ b: SIMD3<Float>, _ c: SIMD3<Float>, _ color: SIMD4<Float>) {
                let normal = simd_normalize(simd_cross(b - a, c - a))
                positions += [a, b, c]
                normals += [normal, normal, normal]
                colors += [color, color, color]
            }
            let front = SIMD3<Float>(0, 0, rim + peak)
            let back = SIMD3<Float>(0, 0, -(rim + peak))
            for index in 0..<10 {
                let p = ring[index], q = ring[(index + 1) % 10]
                let pf = SIMD3(p.x, p.y, rim), qf = SIMD3(q.x, q.y, rim)
                let pb = SIMD3(p.x, p.y, -rim), qb = SIMD3(q.x, q.y, -rim)
                let even = index.isMultiple(of: 2)
                face(front, pf, qf, even ? rgba(accent, 0.9) : rgba(secondary, 0.8))
                face(back, qb, pb, even ? rgba(secondary, 0.7) : rgba(accent, 0.62))
                let side = even ? rgba(accent, 0.55) : rgba(secondary, 0.5)
                face(pf, pb, qb, side)
                face(pf, qb, qf, side)
            }
            let count = positions.count
            let positionSource = SCNGeometrySource(vertices: positions.map { SCNVector3($0.x, $0.y, $0.z) })
            let normalSource = SCNGeometrySource(normals: normals.map { SCNVector3($0.x, $0.y, $0.z) })
            let colorData = colors.withUnsafeBufferPointer { Data(buffer: $0) }
            let colorSource = SCNGeometrySource(data: colorData, semantic: .color, vectorCount: count,
                                                usesFloatComponents: true, componentsPerVector: 4,
                                                bytesPerComponent: MemoryLayout<Float>.size, dataOffset: 0,
                                                dataStride: MemoryLayout<SIMD4<Float>>.stride)
            let element = SCNGeometryElement(indices: (0..<Int32(count)).map { $0 }, primitiveType: .triangles)
            let geometry = SCNGeometry(sources: [positionSource, normalSource, colorSource], elements: [element])
            let material = SCNMaterial()
            material.lightingModel = .blinn
            material.diffuse.contents = UIColor.white
            material.specular.contents = UIColor(white: 0.4, alpha: 1)
            material.shininess = 90
            geometry.materials = [material]
            return geometry
        }

        private static func glarePlane(tint: UIColor) -> SCNGeometry {
            let size = CGSize(width: 512, height: 512)
            let image = UIGraphicsImageRenderer(size: size).image { context in
                let cg = context.cgContext
                let center = CGPoint(x: size.width / 2, y: size.height / 2)
                let colors = [tint.withAlphaComponent(0.35).cgColor, tint.withAlphaComponent(0.07).cgColor,
                              UIColor.clear.cgColor] as CFArray
                if let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: colors,
                                             locations: [0, 0.35, 1]) {
                    cg.drawRadialGradient(gradient, startCenter: center, startRadius: 0, endCenter: center,
                                          endRadius: size.width / 2, options: [])
                }
                let streaks: [(CGFloat, CGFloat, CGFloat)] = [(500, 3, 0), (300, 2.5, .pi / 2),
                                                              (170, 1.5, .pi / 4), (170, 1.5, -.pi / 4)]
                for (length, thickness, angle) in streaks {
                    cg.saveGState()
                    cg.translateBy(x: center.x, y: center.y)
                    cg.rotate(by: angle)
                    let streak = [UIColor.clear.cgColor, UIColor.white.withAlphaComponent(0.55).cgColor,
                                  UIColor.clear.cgColor] as CFArray
                    if let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: streak,
                                                 locations: [0, 0.5, 1]) {
                        cg.clip(to: CGRect(x: -length / 2, y: -thickness / 2, width: length, height: thickness))
                        cg.drawLinearGradient(gradient, start: CGPoint(x: -length / 2, y: 0),
                                              end: CGPoint(x: length / 2, y: 0), options: [])
                    }
                    cg.restoreGState()
                }
            }
            let plane = SCNPlane(width: 3.4, height: 3.4)
            let material = SCNMaterial()
            material.diffuse.contents = image
            material.lightingModel = .constant
            material.blendMode = .add
            material.writesToDepthBuffer = false
            material.isDoubleSided = true
            plane.materials = [material]
            return plane
        }

        private static func sparkleImage() -> UIImage {
            let size = CGSize(width: 64, height: 64)
            return UIGraphicsImageRenderer(size: size).image { context in
                let cg = context.cgContext
                let center = CGPoint(x: 32, y: 32)
                let colors = [UIColor.white.cgColor, UIColor.white.withAlphaComponent(0).cgColor] as CFArray
                if let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: colors, locations: [0, 1]) {
                    cg.drawRadialGradient(gradient, startCenter: center, startRadius: 0, endCenter: center,
                                          endRadius: 10, options: [])
                }
                cg.setFillColor(UIColor.white.cgColor)
                let path = UIBezierPath()
                path.move(to: CGPoint(x: 32, y: 2)); path.addLine(to: CGPoint(x: 35, y: 29))
                path.addLine(to: CGPoint(x: 62, y: 32)); path.addLine(to: CGPoint(x: 35, y: 35))
                path.addLine(to: CGPoint(x: 32, y: 62)); path.addLine(to: CGPoint(x: 29, y: 35))
                path.addLine(to: CGPoint(x: 2, y: 32)); path.addLine(to: CGPoint(x: 29, y: 29))
                path.close()
                path.fill()
            }
        }
    }
}
#endif
