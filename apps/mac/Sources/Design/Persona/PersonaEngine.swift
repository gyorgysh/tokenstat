// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
//
// Source-available for review, NOT open source. See LICENSE: no rights to
// redistribute, publish, or ship a build are granted. Read it, study it, run
// your own build of it.
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
    /// The simulation's own step. Springs this stiff are stable well past it,
    /// and it divides evenly into both 60 and 120.
    private static let fixedStep: CGFloat = 1.0 / 120
    /// The most real time one frame may spend. Beyond this the clock is
    /// simply skipped: catching up is never worth a visible lurch.
    private static let maxFrame: CGFloat = 1.0 / 12
    /// How long one mood takes to become another.
    ///
    /// Long enough that a newspaper has time to be put down and a game picked
    /// up, short enough that nobody waits through it. Both moods run for the
    /// whole of it: the one leaving keeps moving as it fades, because a prop
    /// that freezes and then disappears is two cuts instead of none.
    private static let shiftDuration: CGFloat = 0.55

    private(set) var body: PersonaSoftBody
    private(set) var face = PersonaFacePose()
    private(set) var motes: [PersonaMote] = []
    private(set) var mood: PersonaMood = .idle
    private(set) var traits: PersonaTraits
    private(set) var seed: UInt64

    /// Seconds since this mood began. Every mood function reads this, so a
    /// mood always starts at its own beginning however long the app has run.
    private(set) var clock: CGFloat = 0

    /// The instant the body has been simulated up to, or zero before the
    /// first frame. Read by the lab when it samples frames off the clock.
    var sampledTime: TimeInterval { lastTime ?? 0 }

    /// The mood being left behind, still running on its own clock, and how
    /// much of it is left. One means the change just happened.
    private var leaving: (mood: PersonaMood, clock: CGFloat)?
    private var shift: CGFloat = 0

    private var lastTime: TimeInterval?
    private var pending: CGFloat = 0
    private var blinkCountdown: CGFloat = 2.5
    private var blinkHold: CGFloat = 0
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
        face = mood.face(clock: 0, traits: traits)
        blinkCountdown = 1.4 + nextUnit() * 3.0
    }

    /// Kinetic energy, for the lab's readouts and for anything that wants to
    /// know whether this character has finished reacting.
    var energy: CGFloat { body.energy }

    /// Become a different character in the same seat. A reroll in the editor
    /// changes the seed of a view that is already on screen, and rebuilding
    /// the whole view to change one number would throw away the motion the
    /// person is watching.
    func reseed(_ seed: UInt64) {
        guard seed != self.seed else { return }
        self.seed = seed
        traits = PersonaTraits(seed: seed)
        random = seed == 0 ? 0x9E37_79B9_7F4A_7C15 : seed
        body = PersonaSoftBody(lumps: traits.lumps)
        settle()
        // A new face announces itself rather than appearing mid-breath.
        body.impulse(CGVector(dx: 0, dy: -0.75))
        body.pulse(0.10)
    }

    // MARK: - Time

    /// Advance to a wall-clock instant and refresh everything the renderer
    /// reads. Safe to call with the same date twice.
    func advance(to time: TimeInterval, mood requested: PersonaMood, moving: Bool) {
        if requested != mood {
            enter(requested)
        }

        guard moving else {
            // Motion is off, or nobody is looking. Present the mood's resting
            // pose rather than freezing mid-bounce, which reads as a glitch.
            settle()
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
            step(from: previous, to: clock)
        }
        refresh()
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

        // While a mood is changing, both are asked what they want and the
        // answers are mixed. The body is never handed a new set of forces in
        // one frame, so it never has a moment where it visibly changes its
        // mind.
        let arriving = mood.drive(clock: now, traits: traits)
        let arrivingFace = mood.face(clock: now, traits: traits)
        let drive: PersonaDrive
        let target: PersonaFacePose
        if let leaving, shift > 0 {
            let done = 1 - shift
            drive = .blend(leaving.mood.drive(clock: leaving.clock, traits: traits), arriving, by: done)
            target = .blend(leaving.mood.face(clock: leaving.clock, traits: traits), arrivingFace, by: done)
        } else {
            drive = arriving
            target = arrivingFace
        }

        body.step(dt: Self.fixedStep, drive: drive)
        // The face eases toward the mood's pose rather than being set to it,
        // which is what makes a change of mood read as an expression moving.
        face.ease(towards: target, rate: Self.fixedStep * 11)
        advanceBlink(Self.fixedStep)
    }

    /// Everything the renderer reads that is not integrated: the blink, the
    /// motes, and the squash the face borrows from the body.
    ///
    /// Mid-change, both moods put their things in the air at once. The old
    /// ones shrink away and the new ones grow in, which is what puts something
    /// between a newspaper and a game console rather than swapping one for the
    /// other on a single frame.
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
    }

    /// Zero to one, clamped. The two props overlap only in the middle third of
    /// a shift: the old one is most of the way gone before the new one is
    /// really there, so the handover has a moment of empty hands in it rather
    /// than a moment of holding both.
    private func ramp(_ value: CGFloat) -> CGFloat {
        max(0, min(1, value))
    }

    /// Take a prop down to nothing, or bring it up from nothing. It shrinks as
    /// well as fades, because something set down moves away from the hands.
    private func fade(_ range: Range<Int>, to amount: CGFloat) {
        for index in range {
            motes[index].opacity *= amount
            motes[index].scale *= 0.62 + 0.38 * amount
        }
    }

    /// Smoothstep. A linear crossfade has a corner at each end and the eye
    /// finds both of them.
    private func eased(_ value: CGFloat) -> CGFloat {
        let t = max(0, min(1, value))
        return t * t * (3 - 2 * t)
    }

    // MARK: - Moods

    private func enter(_ next: PersonaMood) {
        // Keep the old mood alive for half a second while the new one takes
        // over, and blink on the way through. A blink over a change is the
        // oldest trick in animation: the eye forgives almost anything that
        // happens behind one.
        leaving = (mood, clock)
        shift = 1
        blinkHold = 0.13
        // A gather. The body dips and springs back, which is the beat that
        // makes the change look like a decision rather than an edit.
        body.pulse(-0.13)

        mood = next
        clock = 0
        beatIndex = 0
        launches = 0
        enterImpulse(next)
    }

    /// The kick a mood arrives with. Without one, a change of mood is a change
    /// of forces, and forces take time to show. With one, the character reacts
    /// on the frame the news arrives.
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
            body.impulse(CGVector(dx: 0, dy: -1.18))
            body.pulse(0.20)
        case .failed:
            body.impulse(CGVector(dx: 0.55, dy: 0))
        case .sleeping:
            body.slump(0.55)
        case .reading:
            body.pulse(-0.05)
        case .gaming:
            body.impulse(CGVector(dx: 0, dy: -0.22))
        case .pacing:
            body.impulse(CGVector(dx: -0.18, dy: -0.30))
        }
    }

    /// Discrete beats. Everything continuous is a force in `PersonaMood`;
    /// this is only what has to happen *at* an instant, which is what a hop, a
    /// beat and a bounce are.
    private func fireEvents(from previous: CGFloat, to now: CGFloat) {
        switch mood {
        case .bouncing:
            // Re-kick once it has run out of bounce, rather than on a timer,
            // so the rhythm comes from the physics and a heavy persona takes
            // longer to get going again than a light one.
            let low = body.centroid.y > PersonaStage.floor - PersonaStage.restRadius * 1.12
            if low, body.energy < 0.30 {
                launches += 1
                let side: CGFloat = launches.isMultiple(of: 2) ? 1 : -1
                body.impulse(CGVector(dx: side * 0.30, dy: -1.35))
                body.pulse(-0.08)
            }

        case .working:
            if crossed(PersonaMood.workPeriod, previous, now) {
                body.impulse(CGVector(dx: 0, dy: -0.78))
                body.poke(at: body.crown, strength: -0.26, reach: 0.30)
            }

        case .dancing:
            if crossed(PersonaMood.beatPeriod, previous, now) {
                beatIndex += 1
                let accent = beatIndex.isMultiple(of: 4)
                body.impulse(CGVector(dx: 0, dy: accent ? -0.92 : -0.40))
                body.pulse(accent ? 0.14 : -0.09)
            }

        case .juggling:
            if crossed(PersonaMood.rallyPeriod, previous, now) {
                // The ball lands on the crown at the seam between two arcs.
                body.poke(at: body.crown, strength: -0.85, reach: 0.26)
                body.impulse(CGVector(dx: 0, dy: 0.22))
            }

        case .waiting:
            if crossed(1.5, previous, now) {
                body.impulse(CGVector(dx: 0, dy: 0.46))
            }

        case .failed:
            // A shake it cannot absorb, then it stops fighting.
            if now < 0.34, crossed(0.085, previous, now) {
                let side: CGFloat = Int(previous / 0.085).isMultiple(of: 2) ? -1 : 1
                body.impulse(CGVector(dx: side * 1.05, dy: 0))
            }
            if crossed(0.34, previous, now) {
                body.slump(0.85)
            }

        case .idle:
            // A shift of weight, so a resting character is not a loop.
            if crossed(5.4, previous, now) {
                let side: CGFloat = nextUnit() > 0.5 ? 1 : -1
                body.impulse(CGVector(dx: side * 0.12, dy: -0.10))
            }

        case .gaming:
            // A win is a jump, and the frantic thumbing in between is a
            // steady low patter that never lets the body settle.
            if crossed(4.3, previous - 2.6, now - 2.6) {
                body.impulse(CGVector(dx: 0, dy: -0.85))
                body.pulse(0.11)
            } else if crossed(0.26, previous, now) {
                body.poke(at: body.anchors.hands, strength: -0.13, reach: 0.20)
            }

        case .pacing:
            // A footfall, and a heavier one at each turn where it plants and
            // pushes off the other way.
            if crossed(0.42, previous, now) {
                body.impulse(CGVector(dx: 0, dy: -0.30))
            }
            if crossed(PersonaMood.stridePeriod, previous, now) {
                body.impulse(CGVector(dx: 0, dy: -0.42))
                body.pulse(-0.07)
            }

        case .thinking, .speaking, .ok, .sleeping, .reading:
            break
        }
    }

    // MARK: - One-shot the app can ask for

    /// Poke the character. A real, local hit at a point in unit space, so a
    /// click on its left side pushes its left side.
    func poke(at point: CGPoint) {
        body.poke(at: point, strength: 0.85, reach: 0.30)
        blinkCountdown = min(blinkCountdown, 0.12)
    }

    // MARK: - Blink

    private func advanceBlink(_ dt: CGFloat) {
        if blinkHold > 0 {
            blinkHold -= dt
            if blinkHold <= 0 {
                blinkCountdown = 2.2 + nextUnit() * 3.4
            }
            return
        }
        guard face.blinks else { return }
        blinkCountdown -= dt
        if blinkCountdown <= 0 {
            blinkHold = 0.10
        }
    }

    /// How shut the eyes are from blinking alone, zero to one.
    var blink: CGFloat {
        guard blinkHold > 0 else { return 0 }
        // Fast down, slower up: a real blink is not symmetric.
        let progress = 1 - blinkHold / 0.10
        return progress < 0.35 ? progress / 0.35 : max(0, 1 - (progress - 0.35) / 0.65)
    }

    // MARK: - Rest

    /// Put the body at the mood's resting shape with no motion in it. Used on
    /// the first frame, and whenever motion is off.
    private func settle() {
        leaving = nil
        shift = 0
        let drive = mood.drive(clock: 0, traits: traits)
        let centre = CGPoint(
            x: drive.anchorX,
            y: PersonaStage.floor - drive.radius * drive.stretch.height
        )
        body.reset(centre: centre, stretch: drive.stretch, radius: drive.radius)
        face = mood.face(clock: 0, traits: traits)
        blinkHold = 0
        pending = 0
    }

    private func crossed(_ period: CGFloat, _ previous: CGFloat, _ now: CGFloat) -> Bool {
        floor(previous / period) != floor(now / period)
    }

    /// xorshift, so a blink pattern is this persona's own and the same on
    /// every machine. Not security, just variety.
    private func nextUnit() -> CGFloat {
        random ^= random << 13
        random ^= random >> 7
        random ^= random << 17
        return CGFloat(random % 10_000) / 10_000
    }
}
