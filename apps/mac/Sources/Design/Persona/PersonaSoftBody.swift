// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
//
// Source-available: source sharing and own builds are permitted.
// Store and commercial distribution of builds is reserved. See LICENSE.
// "tokenstat" is a trademark of pueev OU. See TRADEMARK.md.

import CoreGraphics
import Foundation

enum PersonaStage {
    static let floor: CGFloat = 0.95
    static let ceiling: CGFloat = 0.02
    static let leftRail: CGFloat = 0.02
    static let rightRail: CGFloat = 0.98
    static let centreX: CGFloat = 0.5
    static let restRadius: CGFloat = 0.355

    static var restCentre: CGPoint {
        CGPoint(x: centreX, y: floor - restRadius)
    }
}

struct PersonaDrive {
    var gravity: CGFloat = 0.95
    var stretch = CGSize(width: 1, height: 1)
    var radius: CGFloat = PersonaStage.restRadius
    var roll: CGFloat = 0
    /// How hard the body resists losing volume. This is what makes it read as
    /// a water balloon rather than a rubber band loop.
    var pressure: CGFloat = 44
    var ringStiffness: CGFloat = 210
    var shapeStiffness: CGFloat = 150
    var damping: CGFloat = 3.4
    var lean: CGFloat = 0
    var swirl: CGFloat = 0
    var anchorX: CGFloat = PersonaStage.centreX
    var anchorPull: CGFloat = 7
    var floor: CGFloat = PersonaStage.floor
    var support: CGFloat = 1
    var restitution: CGFloat = 0.34
    var friction: CGFloat = 0.82
    var wobble: CGFloat = 0
    var wobblePhase: CGFloat = 0
    var jiggle: CGFloat = 0
    var jigglePhase: CGFloat = 0
}

struct PersonaSoftBody {
    struct Node {
        var p: CGPoint
        var v: CGVector
    }

    private(set) var nodes: [Node]
    private var forces: [CGVector]
    private var ripple: [CGFloat]
    private var shapeBasis: [(x: CGFloat, y: CGFloat)]
    private var grounded: CGFloat = 0
    private var restEdges: [CGFloat]
    private(set) var restBottom: CGFloat = 1
    private var restOffset: CGPoint = .zero
    private var restArea: CGFloat
    private var lumps: [CGFloat]
    private var impactSpeed: CGFloat = 0
    private var impactX: CGFloat = PersonaStage.centreX

    init(
        count: Int = 20,
        centre: CGPoint = PersonaStage.restCentre,
        radius: CGFloat = PersonaStage.restRadius,
        lumps: [CGFloat] = []
    ) {
        let count = max(6, count - count % 2)
        var nodes: [Node] = []
        nodes.reserveCapacity(count)
        var ripple: [CGFloat] = []
        ripple.reserveCapacity(count)
        for index in 0..<count {
            let angle = CGFloat(index) * 2 * .pi / CGFloat(count)
            nodes.append(Node(
                p: CGPoint(x: centre.x + cos(angle) * radius, y: centre.y + sin(angle) * radius),
                v: .zero
            ))
            ripple.append(angle * 2)
        }
        self.nodes = nodes
        forces = Array(repeating: .zero, count: count)
        self.ripple = ripple
        shapeBasis = (0..<count).map { index in
            let a = CGFloat(index) * 2 * .pi / CGFloat(count)
            return (cos(a), sin(a))
        }
        if lumps.count == count {
            self.lumps = lumps
        } else {
            self.lumps = Array(repeating: 0, count: count)
        }
        restEdges = []
        restArea = 0
        let rest = (0..<count).map { i in
            CGPoint(x: shapeBasis[i].x * (1 + self.lumps[i] * 0.10),
                    y: shapeBasis[i].y * (1 + self.lumps[i] * 0.10))
        }
        restOffset = CGPoint(x: rest.reduce(0) { $0 + $1.x } / CGFloat(count),
                             y: rest.reduce(0) { $0 + $1.y } / CGFloat(count))
        restBottom = (rest.map(\.y).max() ?? 1) - restOffset.y
        restEdges = (0..<count).map { i in
            let next = rest[(i + 1) % count]
            return hypot(next.x - rest[i].x, next.y - rest[i].y)
        }
        restArea = abs((0..<count).reduce(CGFloat(0)) { area, i in
            let next = rest[(i + 1) % count]
            return area + rest[i].x * next.y - next.x * rest[i].y
        }) * 0.5

    }

    var count: Int { nodes.count }

    var centroid: CGPoint {
        var x: CGFloat = 0
        var y: CGFloat = 0
        for node in nodes {
            x += node.p.x
            y += node.p.y
        }
        let inverse = 1 / CGFloat(nodes.count)
        return CGPoint(x: x * inverse, y: y * inverse)
    }

    var momentum: CGVector {
        var dx: CGFloat = 0
        var dy: CGFloat = 0
        for node in nodes {
            dx += node.v.dx
            dy += node.v.dy
        }
        let inverse = 1 / CGFloat(nodes.count)
        return CGVector(dx: dx * inverse, dy: dy * inverse)
    }

    var energy: CGFloat {
        var total: CGFloat = 0
        for node in nodes {
            total += node.v.dx * node.v.dx + node.v.dy * node.v.dy
        }
        return total
    }

    mutating func takeImpact() -> (speed: CGFloat, x: CGFloat)? {
        guard impactSpeed > 0 else { return nil }
        let hit = (speed: impactSpeed, x: impactX)
        impactSpeed = 0
        return hit
    }

    var bounds: CGRect {
        var minX = CGFloat.greatestFiniteMagnitude
        var minY = CGFloat.greatestFiniteMagnitude
        var maxX = -CGFloat.greatestFiniteMagnitude
        var maxY = -CGFloat.greatestFiniteMagnitude
        for node in nodes {
            minX = min(minX, node.p.x)
            minY = min(minY, node.p.y)
            maxX = max(maxX, node.p.x)
            maxY = max(maxY, node.p.y)
        }
        return CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
    }


    mutating func impulse(_ vector: CGVector) {
        for index in nodes.indices {
            nodes[index].v.dx += vector.dx
            nodes[index].v.dy += vector.dy
        }
    }

    mutating func poke(at point: CGPoint, strength: CGFloat, reach: CGFloat = 0.22) {
        for index in nodes.indices {
            let dx = nodes[index].p.x - point.x
            let dy = nodes[index].p.y - point.y
            let distance = sqrt(dx * dx + dy * dy)
            guard distance < reach else { continue }
            let falloff = 1 - distance / reach
            let scale = strength * falloff * falloff
            let inverse = 1 / max(distance, 1e-4)
            nodes[index].v.dx += dx * inverse * scale
            nodes[index].v.dy += dy * inverse * scale
        }
    }

    mutating func pulse(_ strength: CGFloat) {
        let centre = centroid
        for index in nodes.indices {
            let dx = nodes[index].p.x - centre.x
            let dy = nodes[index].p.y - centre.y
            let distance = max(sqrt(dx * dx + dy * dy), 1e-4)
            nodes[index].v.dx += dx / distance * strength
            nodes[index].v.dy += dy / distance * strength
        }
    }

    mutating func slump(_ strength: CGFloat) {
        let centre = centroid
        for index in nodes.indices {
            let above = centre.y - nodes[index].p.y
            nodes[index].v.dy += max(above, 0) * strength
            nodes[index].v.dx += (nodes[index].p.x - centre.x) * strength * 0.6
        }
    }

    mutating func reset(centre: CGPoint = PersonaStage.restCentre, stretch: CGSize = CGSize(width: 1, height: 1), radius: CGFloat = PersonaStage.restRadius) {
        grounded = 1
        for index in nodes.indices {
            let angle = CGFloat(index) * 2 * .pi / CGFloat(nodes.count)
            let reach = radius * (1 + lumps[index] * 0.10)
            nodes[index].p = CGPoint(
                x: centre.x + (cos(angle) * reach - restOffset.x * radius) * stretch.width,
                y: centre.y + (sin(angle) * reach - restOffset.y * radius) * stretch.height
            )
            nodes[index].v = .zero
        }
    }


    mutating func step(dt: CGFloat, drive: PersonaDrive) {
        let n = nodes.count
        guard n > 3 else { return }

        let weight = drive.gravity * (1 - grounded * drive.support)
        for index in 0..<n {
            forces[index] = CGVector(dx: 0, dy: weight)
        }

        var centreX: CGFloat = 0
        var centreY: CGFloat = 0
        for node in nodes {
            centreX += node.p.x
            centreY += node.p.y
        }
        centreX /= CGFloat(n)
        centreY /= CGFloat(n)

        var doubleArea: CGFloat = 0
        for index in 0..<n {
            let a = nodes[index].p
            let b = nodes[(index + 1) % n].p
            doubleArea += a.x * b.y - b.x * a.y
        }
        let area = abs(doubleArea) * 0.5
        let target = restArea * drive.radius * drive.radius * drive.stretch.width * drive.stretch.height
        let pressure = drive.pressure * min(max(target / max(area, 2e-4) - 1, -1.5), 3.0)

        for index in 0..<n {
            let next = (index + 1) % n
            var dx = nodes[next].p.x - nodes[index].p.x
            var dy = nodes[next].p.y - nodes[index].p.y
            let length = max(sqrt(dx * dx + dy * dy), 1e-5)
            dx /= length
            dy /= length

            let spring = drive.ringStiffness * (length - restEdges[index] * drive.radius)
            forces[index].dx += spring * dx
            forces[index].dy += spring * dy
            forces[next].dx -= spring * dx
            forces[next].dy -= spring * dy

            let push = pressure * length * 0.5
            forces[index].dx += dy * push
            forces[index].dy += -dx * push
            forces[next].dx += dy * push
            forces[next].dy += -dx * push
        }

        let rollSin = sin(drive.roll)
        let rollCos = cos(drive.roll)
        let offsetX = (restOffset.x * rollCos - restOffset.y * rollSin) * drive.radius
        let offsetY = (restOffset.y * rollCos + restOffset.x * rollSin) * drive.radius
        for index in 0..<n {
            let basis = shapeBasis[index]
            let x = basis.x * rollCos - basis.y * rollSin
            let y = basis.y * rollCos + basis.x * rollSin
            let reach = drive.radius * (1 + lumps[index] * 0.10)
            let goalX = centreX + (x * reach - offsetX) * drive.stretch.width
            let goalY = centreY + (y * reach - offsetY) * drive.stretch.height
            forces[index].dx += (goalX - nodes[index].p.x) * drive.shapeStiffness
            forces[index].dy += (goalY - nodes[index].p.y) * drive.shapeStiffness
        }

        let anchor = (drive.anchorX - centreX) * drive.anchorPull
        let inverseRadius = 1 / max(drive.radius, 1e-4)
        for index in 0..<n {
            forces[index].dx += anchor

            if drive.lean != 0 {
                forces[index].dx += drive.lean * (centreY - nodes[index].p.y) * inverseRadius
            }

            let dx = nodes[index].p.x - centreX
            let dy = nodes[index].p.y - centreY
            if drive.swirl != 0 {
                forces[index].dx += -dy * drive.swirl
                forces[index].dy += dx * drive.swirl
            }
            if drive.wobble != 0 || drive.jiggle != 0 {
                let distance = max(sqrt(dx * dx + dy * dy), 1e-4)
                var amount = drive.wobble * sin(drive.wobblePhase * 2 * .pi + self.ripple[index])
                amount += drive.jiggle * sin(drive.jigglePhase * 2 * .pi - self.ripple[index] * 1.5)
                forces[index].dx += dx / distance * amount
                forces[index].dy += dy / distance * amount
            }
        }

        let damp = max(0, 1 - drive.damping * dt)
        var contacts = 0
        for index in 0..<n {
            var node = nodes[index]
            node.v.dx = (node.v.dx + forces[index].dx * dt) * damp
            node.v.dy = (node.v.dy + forces[index].dy * dt) * damp
            node.p.x += node.v.dx * dt
            node.p.y += node.v.dy * dt

            if node.p.y > drive.floor - 0.004 {
                contacts += 1
                if node.p.y > drive.floor {
                    node.p.y = drive.floor
                    if node.v.dy > 0 {
                        if grounded < 0.55, node.v.dy > impactSpeed {
                            impactSpeed = node.v.dy
                            impactX = node.p.x
                        }
                        node.v.dy = -node.v.dy * drive.restitution
                    }
                    node.v.dx *= drive.friction
                }
            }
            if node.p.y < PersonaStage.ceiling {
                node.p.y = PersonaStage.ceiling
                if node.v.dy < 0 {
                    node.v.dy = -node.v.dy * 0.25
                }
            }
            if node.p.x < PersonaStage.leftRail {
                node.p.x = PersonaStage.leftRail
                if node.v.dx < 0 { node.v.dx = -node.v.dx * 0.4 }
            }
            if node.p.x > PersonaStage.rightRail {
                node.p.x = PersonaStage.rightRail
                if node.v.dx > 0 { node.v.dx = -node.v.dx * 0.4 }
            }
            nodes[index] = node
        }

        let resting = min(1, CGFloat(contacts) / 3)
        grounded += (resting - grounded) * min(1, dt * 22)
    }


    func outline(in rect: CGRect, smoothing: CGFloat = 0.18) -> CGPath {
        let n = nodes.count
        let path = CGMutablePath()
        guard n > 3 else { return path }

        var points = [CGPoint](repeating: .zero, count: n)
        for index in 0..<n {
            let previous = nodes[(index + n - 1) % n].p
            let current = nodes[index].p
            let next = nodes[(index + 1) % n].p
            let x = current.x + ((previous.x + next.x) * 0.5 - current.x) * smoothing
            let y = current.y + ((previous.y + next.y) * 0.5 - current.y) * smoothing
            points[index] = CGPoint(
                x: rect.minX + x * rect.width,
                y: rect.minY + y * rect.height
            )
        }

        path.move(to: points[0])
        for index in 0..<n {
            let p0 = points[(index + n - 1) % n]
            let p1 = points[index]
            let p2 = points[(index + 1) % n]
            let p3 = points[(index + 2) % n]
            path.addCurve(
                to: p2,
                control1: CGPoint(x: p1.x + (p2.x - p0.x) / 6, y: p1.y + (p2.y - p0.y) / 6),
                control2: CGPoint(x: p2.x - (p3.x - p1.x) / 6, y: p2.y - (p3.y - p1.y) / 6)
            )
        }
        path.closeSubpath()
        return path
    }

    var anchors: PersonaAnchors {
        let bounds = bounds
        return PersonaAnchors(crown: crown, centroid: centroid, bounds: bounds)
    }

    var crown: CGPoint {
        var best = nodes[0].p
        for node in nodes where node.p.y < best.y {
            best = node.p
        }
        return best
    }
}


extension PersonaDrive {
    static func blend(_ from: PersonaDrive, _ to: PersonaDrive, by amount: CGFloat) -> PersonaDrive {
        let t = max(0, min(1, amount))
        let k = t * t * (3 - 2 * t)
        func mix(_ a: CGFloat, _ b: CGFloat) -> CGFloat { a + (b - a) * k }
        var out = to
        out.gravity = mix(from.gravity, to.gravity)
        out.stretch = CGSize(
            width: mix(from.stretch.width, to.stretch.width),
            height: mix(from.stretch.height, to.stretch.height)
        )
        out.radius = mix(from.radius, to.radius)
        out.roll = mix(from.roll, to.roll)
        out.pressure = mix(from.pressure, to.pressure)
        out.ringStiffness = mix(from.ringStiffness, to.ringStiffness)
        out.shapeStiffness = mix(from.shapeStiffness, to.shapeStiffness)
        out.damping = mix(from.damping, to.damping)
        out.lean = mix(from.lean, to.lean)
        out.swirl = mix(from.swirl, to.swirl)
        out.anchorX = mix(from.anchorX, to.anchorX)
        out.anchorPull = mix(from.anchorPull, to.anchorPull)
        out.floor = mix(from.floor, to.floor)
        out.support = mix(from.support, to.support)
        out.restitution = mix(from.restitution, to.restitution)
        out.friction = mix(from.friction, to.friction)
        out.wobble = mix(from.wobble, to.wobble)
        out.jiggle = mix(from.jiggle, to.jiggle)
        out.wobblePhase = to.wobblePhase
        out.jigglePhase = to.jigglePhase
        return out
    }
}

struct PersonaAnchors {
    let crown: CGPoint
    let centroid: CGPoint
    let bounds: CGRect

    var hands: CGPoint {
        CGPoint(x: centroid.x, y: bounds.maxY - bounds.height * 0.20)
    }

    var mouth: CGPoint {
        CGPoint(x: centroid.x, y: centroid.y + bounds.height * 0.18)
    }

    var raised: CGPoint {
        CGPoint(x: centroid.x, y: centroid.y + bounds.height * 0.26)
    }
}
