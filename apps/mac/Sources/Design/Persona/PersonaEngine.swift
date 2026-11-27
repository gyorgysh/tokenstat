// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
//
// Source-available: source sharing and own builds are permitted.
// Store and commercial distribution of builds is reserved. See LICENSE.
// "tokenstat" is a trademark of pueev OU. See TRADEMARK.md.

import CoreGraphics
import Foundation

/// One character's living state: its body, its face, its clock.
///
/// A reference type on purpose. The view redraws every frame anyway, and
/// holding the simulation in `@State` as a value would mean invalidating the
/// view to move a spring, which is the expensive half of doing this at all.
/// Nothing here is observable and nothing here publishes, so a hundred of
/// these cost a hundred small arrays and no SwiftUI work.
///
/// Time is accumulated and spent in fixed steps. A frame that arrives late
/// spends more steps, up to a cap. A frame that arrives after the app was in
/// the background spends none, because a spring integrated across a two second
/// gap is a spring that leaves the frame.
final class PersonaEngine {
    private static let fixedStep: CGFloat = 1.0 / 120
    private static let maxFrame: CGFloat = 1.0 / 12
    private static let shiftDuration: CGFloat = 0.55

    private(set) var body: PersonaSoftBody
    private(set) var face = PersonaFacePose()
    private(set) var motes: [PersonaMote] = []
    private(set) var mood: PersonaMood = .idle
    private(set) var traits: PersonaTraits
    private(set) var seed: UInt64

    private(set) var clock: CGFloat = 0
    private var lifetime: CGFloat = 0
    private(set) var roll: CGFloat = 0
    private(set) var yaw: CGFloat = 0
    private var rollVelocity: CGFloat = 0
    private var yawVelocity: CGFloat = 0

    var sampledTime: TimeInterval { lastTime ?? 0 }

    private var leaving: (mood: PersonaMood, clock: CGFloat)?
    private var shift: CGFloat = 0

    private var softening: CGFloat = 0
    private var jiggle: CGFloat = 0
    private var jiggleClock: CGFloat = 0
    private var dust: [(x: CGFloat, age: CGFloat, weight: CGFloat)] = []
    private var dustCursor = 0

    private var lastTime: TimeInterval?
    private var pending: CGFloat = 0
    private var blinkCountdown: CGFloat = 2.5
    private var blinkAge: CGFloat = -1
    private var blinkLength: CGFloat = 0.17
    private var blinkAgain = false
    private(set) var winkSide: CGFloat = 0
    private var winkAge: CGFloat = -1
    private var winkCountdown: CGFloat = 7

    private(set) var look = CGPoint.zero
    private var lookVelocity = CGVector.zero
    private var lookTarget = CGPoint.zero
    private var fixation: CGFloat = 0.8
    private(set) var headTilt: CGFloat = 0
    private var headTiltVelocity: CGFloat = 0
    private var beatIndex = 0
    private var launches = 0
    private var random: UInt64
    private var started = false

    init(seed: UInt64, mood: PersonaMood = .idle) {
        self.seed = seed
        self.mood = mood
        traits = PersonaTraits(seed: seed)
        body = PersonaSoftBody(lumps: traits.lumps)
        random = seed == 0 ? 0x9E37_79B9_7F4A_7C15 : seed
        face = mood.face(clock: 0, traits: traits).expressed()
        blinkCountdown = 1.4 + nextUnit() * 3.0
        dust = Array(repeating: (x: PersonaStage.centreX, age: 10, weight: 0), count: 4)
    }

    var energy: CGFloat { body.energy }

    func reseed(_ seed: UInt64) {
        guard seed != self.seed else { return }
        self.seed = seed
        traits = PersonaTraits(seed: seed)
        random = seed == 0 ? 0x9E37_79B9_7F4A_7C15 : seed
        body = PersonaSoftBody(lumps: traits.lumps)
        settle()
        body.impulse(CGVector(dx: 0, dy: -0.75))
        body.pulse(0.10)
    }


    func advance(to time: TimeInterval, mood requested: PersonaMood, moving: Bool) {
        if requested != mood {
            enter(requested)
        }

        guard moving else {
            settle()
            roll = 0
            yaw = 0
            rollVelocity = 0
            yawVelocity = 0
            lastTime = nil
            refresh()
            return
        }

        defer { lastTime = time }
        guard let last = lastTime else {
            if !started {
                started = true
                settle()
                enterImpulse(mood)
            }
            refresh()
            return
        }

        let elapsed = CGFloat(time - last)
        guard elapsed > 0 else {
            refresh()
            return
        }
        pending += min(elapsed, Self.maxFrame)

        while pending >= Self.fixedStep {
            pending -= Self.fixedStep
            let previous = clock
            clock += Self.fixedStep
            lifetime += Self.fixedStep
            step(from: previous, to: clock)
        }
        refresh()
    }

    func suspendClock() {
        lastTime = nil
        pending = 0
    }

    private func step(from previous: CGFloat, to now: CGFloat) {
        fireEvents(from: previous, to: now)

        if shift > 0 {
            shift = max(0, shift - Self.fixedStep / Self.shiftDuration)
            leaving?.clock += Self.fixedStep
            if shift == 0 {
                leaving = nil
            }
        }

        let arriving = mood.drive(clock: now, traits: traits)
        let arrivingFace = mood.face(clock: now, traits: traits).expressed()
        var drive: PersonaDrive
        let target: PersonaFacePose
        if let leaving, shift > 0 {
            let done = 1 - shift
            drive = .blend(leaving.mood.drive(clock: leaving.clock, traits: traits), arriving, by: done)
            target = .blend(leaving.mood.face(clock: leaving.clock, traits: traits).expressed(), arrivingFace, by: done)
        } else {
            drive = arriving
            target = arrivingFace
        }

        let quiet = mood == .sleeping || mood == .failed || mood == .waiting
        if mood == .bouncing || mood == .dancing {
            rollVelocity += (1.25 - rollVelocity) * Self.fixedStep * 4
        } else {
            let resting = (roll / (2 * .pi)).rounded() * 2 * .pi
            rollVelocity += ((resting - roll) * 10 - rollVelocity * 6) * Self.fixedStep
        }
        roll += rollVelocity * Self.fixedStep
        drive.roll = roll
        let desiredYaw: CGFloat = mood == .pacing ? sin(lifetime * 0.65) * .pi
            : quiet ? 0 : sin(lifetime * 0.42) * 0.35
        yawVelocity += ((desiredYaw - yaw) * 12 - yawVelocity * 7) * Self.fixedStep
        yaw += yawVelocity * Self.fixedStep

        if softening > 0 || jiggle > 0 {
            softening = max(0, softening - Self.fixedStep / 0.24)
            jiggle = max(0, jiggle - Self.fixedStep / 0.55)
            jiggleClock += Self.fixedStep
            let eased = softening * softening
            drive.shapeStiffness *= 1 - 0.15 * eased
            drive.pressure *= 1 - 0.10 * eased
            drive.damping *= 1 - 0.22 * eased
            drive.jiggle += jiggle * jiggle * 0.55
            drive.jigglePhase = jiggleClock * 5.2
        }

        body.step(dt: Self.fixedStep, drive: drive)
        absorbLanding()
        face.ease(towards: target, rate: Self.fixedStep * 11)
        advanceGaze(Self.fixedStep)
        advanceBlink(Self.fixedStep)
    }


    private var wander: CGFloat {
        switch mood {
        case .sleeping, .failed: 0
        case .idle, .waiting, .stargazing, .gardening: 0.55
        case .thinking, .pacing: 0.45
        case .working, .typing, .reading, .sketching, .gaming: 0.18
        default: 0.32
        }
    }

    private func advanceGaze(_ dt: CGFloat) {
        let reach = face.openness > 0.3 ? wander : 0
        fixation -= dt
        if fixation <= 0 {
            let far = nextUnit() < 0.3
            let angle = nextUnit() * 2 * .pi
            let distance = reach * (far ? 0.7 + nextUnit() * 0.3 : nextUnit() * 0.45)
            let next = CGPoint(x: cos(angle) * distance, y: sin(angle) * distance * 0.6)
            let jump = hypot(next.x - lookTarget.x, next.y - lookTarget.y)
            lookTarget = next
            fixation = 0.45 + nextUnit() * (far ? 2.4 : 1.4)
            if jump > 0.45, blinkAge < 0, face.blinks, nextUnit() < 0.35 {
                startBlink(0.26)
            }
        }
        if reach == 0 { lookTarget = .zero }
        let omega: CGFloat = 34
        lookVelocity.dx += ((lookTarget.x - look.x) * omega * omega - 2 * omega * lookVelocity.dx) * dt
        lookVelocity.dy += ((lookTarget.y - look.y) * omega * omega - 2 * omega * lookVelocity.dy) * dt
        look.x += lookVelocity.dx * dt
        look.y += lookVelocity.dy * dt

        let tiltTarget = clamp(-(look.x + face.gaze.x * 0.5) * 0.10, -0.16, 0.16)
        let stiffness: CGFloat = 70
        let damping: CGFloat = 2 * 0.55 * sqrt(stiffness)
        headTiltVelocity += ((tiltTarget - headTilt) * stiffness - headTiltVelocity * damping) * dt
        headTilt += headTiltVelocity * dt
    }

    private func clamp(_ value: CGFloat, _ lower: CGFloat, _ upper: CGFloat) -> CGFloat {
        min(max(value, lower), upper)
    }

    private func absorbLanding() {
        for index in dust.indices {
            dust[index].age += Self.fixedStep
        }
        guard let hit = body.takeImpact(), hit.speed > 0.32 else { return }
        let force = min(1, (hit.speed - 0.32) / 1.5)
        softening = max(softening, force)
        jiggle = max(jiggle, force)
        jiggleClock = 0
        guard force > 0.18 else { return }
        dust[dustCursor] = (x: hit.x, age: 0, weight: force)
        dustCursor = (dustCursor + 1) % dust.count
    }

    private func refresh() {
        motes.removeAll(keepingCapacity: true)
        let anchors = body.anchors
        if let leaving, shift > 0 {
            let start = motes.count
            leaving.mood.motes(clock: leaving.clock, traits: traits, at: anchors, into: &motes)
            fade(motes[start...].indices, to: eased(ramp((shift - 0.35) / 0.65)))
        }
        let start = motes.count
        mood.motes(clock: clock, traits: traits, at: anchors, into: &motes)
        if shift > 0 {
            fade(motes[start...].indices, to: eased(ramp((0.65 - shift) / 0.65)))
        }
        addDust()
    }

    private func addDust() {
        for grain in dust where grain.age < 0.46 {
            let life = grain.age / 0.46
            for side in [CGFloat(-1), 1] {
                motes.append(PersonaMote(
                    kind: .puff,
                    position: CGPoint(
                        x: grain.x + side * (0.03 + life * 0.11) * grain.weight,
                        y: PersonaStage.floor - 0.012 - life * life * 0.045
                    ),
                    scale: (0.34 + life * 0.62) * grain.weight,
                    opacity: (1 - life) * (1 - life) * 0.42 * grain.weight
                ))
            }
        }
    }

    private func ramp(_ value: CGFloat) -> CGFloat {
        max(0, min(1, value))
    }

    private func fade(_ range: Range<Int>, to amount: CGFloat) {
        for index in range {
            motes[index].opacity *= amount
            motes[index].scale *= 0.62 + 0.38 * amount
        }
    }

    private func eased(_ value: CGFloat) -> CGFloat {
        let t = max(0, min(1, value))
        return t * t * (3 - 2 * t)
    }


    private func enter(_ next: PersonaMood) {
        leaving = (mood, clock)
        shift = 1
        startBlink(0.30)
        body.pulse(-0.13)

        mood = next
        clock = 0
        beatIndex = 0
        launches = 0
        enterImpulse(next)
    }

    private func enterImpulse(_ mood: PersonaMood) {
        switch mood {
        case .idle:
            break
        case .bouncing:
            body.impulse(CGVector(dx: 0, dy: -1.15))
        case .thinking:
            body.pulse(-0.09)
        case .working:
            body.impulse(CGVector(dx: 0, dy: -0.42))
        case .speaking:
            body.pulse(0.06)
        case .juggling:
            body.impulse(CGVector(dx: 0, dy: -0.20))
        case .dancing:
            body.impulse(CGVector(dx: 0, dy: -0.45))
        case .waiting:
            body.impulse(CGVector(dx: 0, dy: -0.28))
            body.pulse(0.05)
        case .ok:
            body.impulse(CGVector(dx: 0, dy: -1.30))
            body.pulse(0.24)
        case .failed:
            body.impulse(CGVector(dx: 0.55, dy: 0))
        case .sleeping:
            body.slump(0.16)
        case .reading:
            body.pulse(-0.05)
        case .gaming:
            body.impulse(CGVector(dx: 0, dy: -0.22))
        case .pacing:
            body.impulse(CGVector(dx: -0.18, dy: -0.30))
        case .typing:
            body.impulse(CGVector(dx: 0, dy: -0.16))
        case .sipping:
            body.pulse(-0.04)
        case .sketching:
            body.pulse(-0.04)
        case .stargazing:
            body.pulse(0.04)
        case .gardening:
            body.impulse(CGVector(dx: -0.10, dy: -0.14))
        case .bubbling:
            body.pulse(0.05)
        case .snacking:
            body.pulse(-0.05)
        }
    }

    private func fireEvents(from previous: CGFloat, to now: CGFloat) {
        switch mood {
        case .bouncing:
            let low = body.centroid.y > PersonaStage.floor - PersonaStage.restRadius * 1.12
            if low, abs(body.momentum.dy) < 0.14 {
                launches += 1
                let side: CGFloat = launches.isMultiple(of: 2) ? 1 : -1
                body.impulse(CGVector(dx: side * 0.34, dy: -1.45))
                body.pulse(-0.10)
            }

        case .working:
            guard PersonaMood.workAdmire(now) < 0.02 else { break }
            if crossed(PersonaMood.blowPeriod, previous + 0.07, now + 0.07) {
                body.pulse(-0.06)
            }
            if struck(PersonaMood.blowPeriod, 0.93, previous, now) {
                body.impulse(CGVector(dx: 0.10, dy: 0.34))
                body.poke(at: body.anchors.hands, strength: -0.42, reach: 0.30)
            }

        case .dancing:
            if crossed(PersonaMood.beatPeriod, previous + 0.10, now + 0.10) {
                body.pulse(-0.06)
            }
            if crossed(PersonaMood.beatPeriod, previous, now) {
                beatIndex += 1
                let accent = beatIndex.isMultiple(of: 4)
                body.impulse(CGVector(dx: 0, dy: accent ? -0.34 : -0.15))
                body.pulse(accent ? 0.07 : -0.04)
            }

        case .juggling:
            if crossed(PersonaMood.rallyPeriod, previous, now) {
                let wild = Int(floor(now / PersonaMood.rallyPeriod)) % 4 == 0
                body.poke(at: body.crown, strength: wild ? -1.25 : -0.85, reach: 0.26)
                body.impulse(CGVector(dx: 0, dy: wild ? 0.34 : 0.22))
            }

        case .waiting:
            if crossed(1.2, previous, now) {
                body.impulse(CGVector(dx: 0, dy: 0.46))
            }
            if struck(5.6, 0.70, previous, now) {
                body.pulse(-0.11)
            }

        case .failed:
            if now < 0.34, crossed(0.085, previous, now) {
                let side: CGFloat = Int(previous / 0.085).isMultiple(of: 2) ? -1 : 1
                body.impulse(CGVector(dx: side * 1.05, dy: 0))
            }
            if previous < 0.34, now >= 0.34 {
                body.slump(0.85)
            }
            if now > 1.5, struck(4.4, 0.55, previous - 1.5, now - 1.5) {
                body.impulse(CGVector(dx: 0, dy: -0.62))
            }
            if now > 1.5, struck(4.4, 0.80, previous - 1.5, now - 1.5) {
                body.slump(0.45)
            }

        case .idle:
            if crossed(5.4, previous, now) {
                let side: CGFloat = nextUnit() > 0.5 ? 1 : -1
                body.impulse(CGVector(dx: side * 0.12, dy: -0.10))
            }
            if struck(11.5, 0.62, previous, now) {
                body.impulse(CGVector(dx: 0, dy: -0.30))
            }

        case .thinking:
            if struck(7.2, 0.84, previous, now) {
                body.impulse(CGVector(dx: 0, dy: -0.80))
                body.pulse(0.18)
            }

        case .gaming:
            let round = PersonaMood.gamingRound(now)
            if round.win > 0.6, struck(PersonaMood.gamePeriod, 0.078, previous, now) {
                body.impulse(CGVector(dx: 0, dy: -0.95))
                body.pulse(0.13)
            } else if round.loss > 0.6, struck(PersonaMood.gamePeriod, 0.578, previous, now) {
                body.slump(0.16)
            } else if crossed(0.26, previous, now) {
                body.poke(at: body.anchors.hands, strength: -0.13, reach: 0.20)
            }

        case .pacing:
            if PersonaMood.pacingIdea(now) < 0.25 {
                if crossed(0.42, previous, now) {
                    body.impulse(CGVector(dx: 0, dy: -0.32))
                }
                if crossed(PersonaMood.stridePeriod, previous, now) {
                    body.impulse(CGVector(dx: 0, dy: -0.44))
                    body.pulse(-0.07)
                }
            }
            if struck(PersonaMood.paceThinkPeriod, 0.78, previous, now) {
                body.impulse(CGVector(dx: 0, dy: -0.50))
                body.pulse(0.14)
            }

        case .typing:
            let keys = PersonaMood.typing(now)
            if keys.tap > 0.5, crossed(0.078, previous, now) {
                body.poke(at: body.anchors.hands, strength: -0.20, reach: 0.22)
                body.impulse(CGVector(dx: 0, dy: -0.05))
            }
            if struck(PersonaMood.typePeriod, 0.90, previous, now) {
                body.impulse(CGVector(dx: 0, dy: -0.34))
                body.pulse(0.08)
            }

        case .gardening:
            if PersonaMood.garden(now).joy < 0.3, crossed(1.15, previous, now) {
                body.impulse(CGVector(dx: -0.04, dy: -0.16))
                body.poke(at: body.anchors.hands, strength: -0.12, reach: 0.20)
            }
            if struck(11.2, 0.70, previous, now) {
                body.impulse(CGVector(dx: 0, dy: -0.85))
                body.pulse(0.14)
            }

        case .reading:
            if struck(8.4, 0.66, previous, now) {
                if PersonaMood.readingGag(now).shock > 0 {
                    body.impulse(CGVector(dx: 0, dy: -0.70))
                    body.pulse(0.16)
                } else {
                    body.pulse(-0.12)
                }
            }

        case .sipping:
            if struck(PersonaMood.teaPeriod, 0.30, previous, now) {
                body.impulse(CGVector(dx: 0, dy: -0.55))
                body.poke(at: body.anchors.mouth, strength: -0.55, reach: 0.28)
            }

        case .sketching:
            if PersonaMood.sketch(now).look < 0.25, crossed(0.725, previous, now) {
                body.poke(at: body.anchors.hands, strength: -0.16, reach: 0.24)
            }

        case .stargazing:
            if struck(9.4, 0.40, previous, now) {
                body.impulse(CGVector(dx: 0, dy: -0.34))
                body.pulse(0.09)
            }

        case .sleeping:
            if struck(13.0, 0.62, previous, now) {
                body.poke(at: body.crown, strength: -0.22, reach: 0.28)
            }

        case .ok:
            if now < 0.7, crossed(0.62, previous, now) {
                body.impulse(CGVector(dx: 0, dy: -0.72))
                body.pulse(0.10)
            }

        case .bubbling:
            if struck(5.4, 0.60, previous, now) {
                body.poke(at: body.anchors.mouth, strength: -0.95, reach: 0.34)
                body.impulse(CGVector(dx: -0.30, dy: -0.18))
                startBlink(0.26)
            }

        case .snacking:
            for start in [CGFloat(0.10), 0.32, 0.54] where struck(7.6, start, previous, now) {
                body.impulse(CGVector(dx: -0.22, dy: -0.20))
                body.poke(at: body.anchors.mouth, strength: -0.30, reach: 0.26)
            }
            if struck(7.6, 0.80, previous, now) {
                body.impulse(CGVector(dx: 0, dy: -0.40))
                body.pulse(0.10)
            }

        case .speaking:
            break
        }
    }


    func poke(at point: CGPoint) {
        body.poke(at: point, strength: 0.85, reach: 0.30)
        blinkCountdown = min(blinkCountdown, 0.12)
    }


    private func startBlink(_ length: CGFloat) {
        blinkAge = 0
        blinkLength = length
        blinkAgain = nextUnit() < 0.2
    }

    private func advanceBlink(_ dt: CGFloat) {
        if blinkAge >= 0 {
            blinkAge += dt
            if blinkAge >= blinkLength {
                if blinkAgain {
                    blinkAgain = false
                    blinkAge = 0
                    blinkLength = 0.26
                } else {
                    blinkAge = -1
                    blinkCountdown = 1.6 + nextUnit() * 4.4
                }
            }
        } else if face.blinks {
            blinkCountdown -= dt
            if blinkCountdown <= 0 {
                startBlink(0.30)
            }
        }
        advanceWink(dt)
    }

    private var winks: Bool {
        switch mood {
        case .idle, .ok, .dancing, .juggling, .bouncing, .waiting: true
        default: false
        }
    }

    private func advanceWink(_ dt: CGFloat) {
        if winkAge >= 0 {
            winkAge += dt
            if winkAge >= 0.62 { winkAge = -1; winkSide = 0 }
            return
        }
        guard winks, face.blinks, blinkAge < 0 else { return }
        winkCountdown -= dt
        if winkCountdown <= 0 {
            winkCountdown = 6 + nextUnit() * 9
            winkAge = 0
            winkSide = nextUnit() < 0.5 ? -1 : 1
        }
    }

    var wink: CGFloat {
        guard winkAge >= 0 else { return 0 }
        let t = winkAge
        if t < 0.08 { return t / 0.08 }
        if t < 0.42 { return 1 }
        let x = min(1, (t - 0.42) / 0.20)
        return 1 - x * x * (3 - 2 * x)
    }

    var blink: CGFloat {
        guard blinkAge >= 0 else { return 0 }
        let close: CGFloat = 0.06
        let hold = close + 0.035
        let t = blinkAge
        if t < close {
            let x = t / close
            return x * x
        }
        if t < hold { return 1 }
        let open = hold + max(0.05, (blinkLength - hold) * 0.45)
        if t < open {
            let x = (t - hold) / (open - hold)
            return 1 - 1.08 * x * x * (3 - 2 * x)
        }
        let x = min(1, (t - open) / max(0.01, blinkLength - open))
        return -0.08 * (1 - x * x * (3 - 2 * x))
    }


    private func settle() {
        leaving = nil
        shift = 0
        let drive = mood.drive(clock: 0, traits: traits)
        let centre = CGPoint(
            x: drive.anchorX,
            y: PersonaStage.floor - drive.radius * drive.stretch.height * body.restBottom
        )
        body.reset(centre: centre, stretch: drive.stretch, radius: drive.radius)
        face = mood.face(clock: 0, traits: traits).expressed()
        blinkAge = -1
        winkAge = -1
        winkSide = 0
        look = .zero
        lookTarget = .zero
        lookVelocity = .zero
        headTilt = 0
        headTiltVelocity = 0
        pending = 0
        softening = 0
        jiggle = 0
        for index in dust.indices { dust[index].age = 10 }
    }

    private func crossed(_ period: CGFloat, _ previous: CGFloat, _ now: CGFloat) -> Bool {
        floor(previous / period) != floor(now / period)
    }

    private func struck(_ period: CGFloat, _ at: CGFloat, _ previous: CGFloat, _ now: CGFloat) -> Bool {
        crossed(period, previous - at * period, now - at * period)
    }

    private func nextUnit() -> CGFloat {
        random ^= random << 13
        random ^= random >> 7
        random ^= random << 17
        return CGFloat(random % 10_000) / 10_000
    }
}
