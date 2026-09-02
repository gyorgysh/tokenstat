// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
//
// Source-available for review, NOT open source. See LICENSE: no rights to
// redistribute, publish, or ship a build are granted. Read it, study it, run
// your own build of it.
// "tokenstat" is a trademark of pueev OU. See TRADEMARK.md.

import CoreGraphics
import Foundation

/// The stage a persona lives on, in unit coordinates with y pointing down.
///
/// Everything is expressed as a fraction of the mark's frame, so one
/// simulation serves a 16pt seat beside a message and a 96pt hero in the
/// editor without a second set of numbers.
enum PersonaStage {
    /// Where the body rests. Below it there is a shadow, above it a hop has
    /// room to travel without leaving the frame.
    static let floor: CGFloat = 0.95
    /// The highest a node may go. A hard stop, not a spring: a bounce that
    /// escapes the frame is a bounce the transcript sees as a jump.
    static let ceiling: CGFloat = 0.02
    static let leftRail: CGFloat = 0.02
    static let rightRail: CGFloat = 0.98
    static let centreX: CGFloat = 0.5
    /// Radius at rest, so the body fills a little under three quarters of the
    /// frame. What is left over is not slack: it is the headroom a hop, an
    /// antenna and a thought dot need, and the reason a bouncing character
    /// never changes the height of the row it sits in.
    static let restRadius: CGFloat = 0.355

    static var restCentre: CGPoint {
        CGPoint(x: centreX, y: floor - restRadius)
    }
}

/// Everything the simulation needs for one instant, produced by the mood.
///
/// A pose is a set of *goals*, never positions. That is the whole trick: a
/// mood says "be this wide, pull this way, push this hard" and the springs
/// decide how the body gets there, so every change of mood arrives with
/// overshoot, follow-through and settle already in it. Nothing has to be
/// cross-faded, because nothing was keyframed.
struct PersonaDrive {
    /// Downward acceleration. Zero floats, one falls at a cartoon rate.
    var gravity: CGFloat = 0.95
    /// The rest ellipse, as multipliers on `radius`. Squash and stretch.
    var stretch = CGSize(width: 1, height: 1)
    var radius: CGFloat = PersonaStage.restRadius
    /// How hard the body resists losing volume. This is what makes it read as
    /// a water balloon rather than a rubber band loop.
    var pressure: CGFloat = 44
    var ringStiffness: CGFloat = 210
    /// How hard the body insists on being its own shape. This is the one that
    /// decides gel or slime: high snaps back, low lets a squash linger.
    var shapeStiffness: CGFloat = 150
    /// Velocity bleed per second. Low is sloppy slime, high is a firm gel.
    var damping: CGFloat = 3.4
    /// A couple: the top half is pushed one way, the bottom half the other.
    /// A lean, not a rotation, so the feet stay planted.
    var lean: CGFloat = 0
    /// Tangential churn. Thinking looks like something turning over inside.
    var swirl: CGFloat = 0
    /// Where the body wants to stand. Moving this is how a persona travels
    /// without the frame moving under it.
    var anchorX: CGFloat = PersonaStage.centreX
    var anchorPull: CGFloat = 7
    var floor: CGFloat = PersonaStage.floor
    /// How much of its own weight the ground carries once the body is resting
    /// on it. One means all of it.
    ///
    /// Without this, gravity is paid for twice. It is what makes a fall fall
    /// and a landing squash, and it is also a steady downward pull on every
    /// node of a body that has already landed, which flattens a resting
    /// character by a quarter of its height and flattens it more the snappier
    /// its jump was. Cancelling it on contact keeps the two apart: momentum
    /// still deforms the body, its own weight no longer does.
    var support: CGFloat = 1
    var restitution: CGFloat = 0.34
    var friction: CGFloat = 0.82
    /// Per-node radial ripple. Deterministic, driven by `wobblePhase`, so two
    /// personas with the same seed ripple identically on every machine.
    var wobble: CGFloat = 0
    var wobblePhase: CGFloat = 0
    /// The second ripple channel, and the engine owns it.
    ///
    /// `wobble` is character: a mood decides this creature ripples while it
    /// thinks. This one is consequence: it is switched on by a hard landing
    /// and rings down on its own, so the wave that travels round the rim after
    /// a splat is not something a mood had to remember to ask for.
    var jiggle: CGFloat = 0
    var jigglePhase: CGFloat = 0
}

/// A pressure soft body: a closed ring of point masses held out by internal
/// pressure and held in shape by springs.
///
/// Why a simulation rather than a set of sine curves. Sines can fake a
/// breathe, but they cannot carry momentum, so every mood change is a cut and
/// every impact is a pose. Fourteen masses give the thing weight: it lands
/// heavier when it falls further, it keeps ringing after a hit, and a shove
/// on one side travels round the rim. That is the difference between a shape
/// that changes and a creature that reacts.
///
/// The cost is fourteen nodes, fourteen ring springs, seven shape springs and
/// fourteen pressure edges per step, all scalar arithmetic on reused buffers.
/// Measured on the lab's stress grid, a hundred and twenty live marks step in
/// well under a millisecond a frame, and the drawing is what costs.
struct PersonaSoftBody {
    struct Node {
        var p: CGPoint
        var v: CGVector
    }

    private(set) var nodes: [Node]
    /// Scratch, kept as a stored property so a step allocates nothing.
    private var forces: [CGVector]
    /// Fixed per-node phase offsets, so the ripple runs round the rim rather
    /// than pulsing everywhere at once.
    private var ripple: [CGFloat]
    /// How much of the body is resting on the ground, zero to one, eased so
    /// that touching down ramps the support in rather than snapping it on.
    private var grounded: CGFloat = 0
    /// This creature's permanent dents, as a radial offset per node.
    ///
    /// Built from the second and third harmonics only, so no persona is an
    /// off-centre circle: the shape is dented rather than displaced.
    private var lumps: [CGFloat]
    /// The hardest a node hit the floor since the engine last looked, and
    /// where. Nought when nothing has landed.
    ///
    /// Recorded here rather than inferred upstairs, because the floor is the
    /// only place that knows how fast the body was going when it arrived. It
    /// is what pays for the dust, the extra squash and the ring-out, in every
    /// mood, without a mood having to ask.
    private var impactSpeed: CGFloat = 0
    private var impactX: CGFloat = PersonaStage.centreX

    init(
        count: Int = 14,
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
        if lumps.count == count {
            self.lumps = lumps
        } else {
            self.lumps = Array(repeating: 0, count: count)
        }
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

    /// The body's travel, with its own ringing left out.
    ///
    /// `energy` counts every node, so a slack blob quivering on the floor
    /// looks energetic to it. This is the mean velocity, where an internal
    /// wobble cancels itself and only the creature actually going somewhere
    /// survives. It is what tells a bouncing character it has stopped
    /// bouncing.
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

    /// Sum of squared speeds. The sleep test: a body this still, under a mood
    /// with nothing driving it, can stop being stepped at all.
    var energy: CGFloat {
        var total: CGFloat = 0
        for node in nodes {
            total += node.v.dx * node.v.dx + node.v.dy * node.v.dy
        }
        return total
    }

    /// The landing since this was last called, and forget it.
    ///
    /// Consumed rather than read, so one landing pays for one splat however
    /// many steps the frame spent.
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

    // MARK: - Impulses

    /// Shove the whole body. Momentum is conserved, so a kick launches it and
    /// the jelly catches up: squash on the way out, stretch at the top.
    mutating func impulse(_ vector: CGVector) {
        for index in nodes.indices {
            nodes[index].v.dx += vector.dx
            nodes[index].v.dy += vector.dy
        }
    }

    /// A local hit, falling off with distance. What a landed ball does, and
    /// what makes a catch look like a catch rather than a jump.
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

    /// Push every node away from the centroid, or pull it in. A gasp, a
    /// flinch, the pop at the top of a celebration.
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

    /// Collapse toward the floor without moving sideways. The failure melt.
    mutating func slump(_ strength: CGFloat) {
        let centre = centroid
        for index in nodes.indices {
            let above = centre.y - nodes[index].p.y
            nodes[index].v.dy += max(above, 0) * strength
            nodes[index].v.dx += (nodes[index].p.x - centre.x) * strength * 0.6
        }
    }

    /// Snap back to a clean ring. Used when motion is off and for the first
    /// frame, so a paused mark is a settled character rather than a spasm.
    mutating func reset(centre: CGPoint = PersonaStage.restCentre, stretch: CGSize = CGSize(width: 1, height: 1), radius: CGFloat = PersonaStage.restRadius) {
        grounded = 1
        for index in nodes.indices {
            let angle = CGFloat(index) * 2 * .pi / CGFloat(nodes.count)
            nodes[index].p = CGPoint(
                x: centre.x + cos(angle) * radius * stretch.width,
                y: centre.y + sin(angle) * radius * stretch.height
            )
            nodes[index].v = .zero
        }
    }

    // MARK: - Simulation

    /// One fixed step. Callers accumulate real time and run this at a fixed
    /// `dt`, because a spring integrated at a variable step is a spring that
    /// explodes the first time a frame is late.
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
        let target = .pi * drive.radius * drive.radius * drive.stretch.width * drive.stretch.height
        // Clamped: an area that has briefly collapsed must not answer with a
        // force big enough to turn the body inside out.
        let pressure = drive.pressure * min(max(target / max(area, 2e-4) - 1, -1.5), 3.0)

        let edgeRest = 2 * drive.radius * sin(.pi / CGFloat(n))
        for index in 0..<n {
            let next = (index + 1) % n
            var dx = nodes[next].p.x - nodes[index].p.x
            var dy = nodes[next].p.y - nodes[index].p.y
            let length = max(sqrt(dx * dx + dy * dy), 1e-5)
            dx /= length
            dy /= length

            let spring = drive.ringStiffness * (length - edgeRest)
            forces[index].dx += spring * dx
            forces[index].dy += spring * dy
            forces[next].dx -= spring * dx
            forces[next].dy -= spring * dy

            // Outward normal for a ring wound in increasing angle with y down.
            let push = pressure * length * 0.5
            forces[index].dx += dy * push
            forces[index].dy += -dx * push
            forces[next].dx += dy * push
            forces[next].dy += -dx * push
        }

        // Shape matching, and it is what holds the creature together.
        //
        // A ring of springs has no bending stiffness: edge lengths and area
        // can all be satisfied by a teardrop, so gravity and a floor turn the
        // blob into a tent within a second and it stays there. This pulls each
        // node toward where it would be on the target ellipse, drawn around
        // wherever the body currently is. Because the goals are built on the
        // live centroid, they sum to zero and add no momentum: the body is
        // free to fall, bounce and travel, it just is not free to stop being
        // this shape.
        for index in 0..<n {
            let angle = CGFloat(index) * 2 * .pi / CGFloat(n)
            let reach = drive.radius * (1 + lumps[index] * 0.10)
            let goalX = centreX + cos(angle) * reach * drive.stretch.width
            let goalY = centreY + sin(angle) * reach * drive.stretch.height
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
                // The impact ring runs at its own faster rate and against the
                // ripple order, so a splat travels up the body rather than
                // beating with whatever the mood was already doing.
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
                        // Only a body that was in the air lands. A node of a
                        // resting creature grazing the floor is not an event,
                        // and treating it as one would have every idle persona
                        // standing in its own dust cloud.
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

    // MARK: - Outline

    /// The silhouette, as one closed path of cubic segments.
    ///
    /// One pass of Laplacian smoothing first, on a copy: the simulation wants
    /// fourteen distinct masses, the eye wants a curve with no corners in it.
    /// Then Catmull-Rom through the smoothed ring, converted to Béziers,
    /// which is what keeps a heavy squash from creasing.
    func outline(in rect: CGRect, smoothing: CGFloat = 0.34) -> CGPath {
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

    /// Where the body is right now, for anything drawn against it.
    ///
    /// Handed to a mood as one value rather than three arguments, because a
    /// newspaper has to be held at the front of a body that is squashing and a
    /// thought has to hover over a head that is moving.
    var anchors: PersonaAnchors {
        let bounds = bounds
        return PersonaAnchors(crown: crown, centroid: centroid, bounds: bounds)
    }

    /// Where the top of the head is, in unit space. The antenna roots here and
    /// a caught ball lands here, so both follow the squash instead of hovering
    /// over a rectangle that no longer describes the body.
    var crown: CGPoint {
        var best = nodes[0].p
        for node in nodes where node.p.y < best.y {
            best = node.p
        }
        return best
    }
}


extension PersonaDrive {
    /// One set of forces on its way to becoming another.
    ///
    /// Every field is a number, so a mood change can be a crossfade rather
    /// than a cut: for half a second the body is being pulled by both moods at
    /// once and by neither completely. It is the difference between a
    /// character putting the newspaper down and picking up a game, and a
    /// character being replaced by a different character.
    static func blend(_ from: PersonaDrive, _ to: PersonaDrive, by amount: CGFloat) -> PersonaDrive {
        // Smoothstep, so the crossfade has no corner at either end. A linear
        // blend starts and stops abruptly and reads as a cut with a ramp.
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
        // Phases are clocks, not amounts. Blending two of them walks the
        // ripple backwards; the incoming one simply takes over.
        out.wobblePhase = to.wobblePhase
        out.jigglePhase = to.jigglePhase
        return out
    }
}

/// Where a character's body is, in unit space, for whatever is drawn against
/// it.
struct PersonaAnchors {
    let crown: CGPoint
    let centroid: CGPoint
    let bounds: CGRect

    /// Where a small thing is held: low and forward, straddling the bottom
    /// edge of the body.
    ///
    /// A blob has no arms, so a prop drawn wholly inside the silhouette reads
    /// as being *in* the creature rather than held by it. Sitting it across
    /// the outline, with the eyes looking down at it, is what makes the
    /// difference.
    var hands: CGPoint {
        CGPoint(x: centroid.x, y: bounds.maxY - bounds.height * 0.20)
    }

    /// Where the mouth is, near enough. Anything that comes out of the
    /// character rather than being held by it starts here.
    var mouth: CGPoint {
        CGPoint(x: centroid.x, y: centroid.y + bounds.height * 0.18)
    }

    /// Where something is held up to be read: high enough to cover the body
    /// from just under the eyes down, so the character looks over the top of
    /// it. That is the whole picture of somebody reading a newspaper.
    var raised: CGPoint {
        CGPoint(x: centroid.x, y: centroid.y + bounds.height * 0.26)
    }
}
