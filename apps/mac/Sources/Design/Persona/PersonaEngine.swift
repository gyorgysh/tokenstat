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

    /// How soft a recent landing has left the body, one to nought.
    ///
    /// A landing that only bounces is a ball. A landing that also stops the
    /// creature holding its own shape for a fifth of a second is jelly, and
    /// the difference is the whole character. It decays on its own, so no mood
    /// has to remember to put the stiffness back.
    private var softening: CGFloat = 0
    /// The ring-out after an impact, and the clock it runs on.
    private var jiggle: CGFloat = 0
    private var jiggleClock: CGFloat = 0
    /// Dust from recent landings. A fixed four, oldest overwritten, because a
    /// growing array in a per-frame path is a leak with a nice name.
    private var dust: [(x: CGFloat, age: CGFloat, weight: CGFloat)] = []
    private var dustCursor = 0

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
        dust = Array(repeating: (x: PersonaStage.centreX, age: 10, weight: 0), count: 4)
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
        var drive: PersonaDrive
        let target: PersonaFacePose
        if let leaving, shift > 0 {
            let done = 1 - shift
            drive = .blend(leaving.mood.drive(clock: leaving.clock, traits: traits), arriving, by: done)
            target = .blend(leaving.mood.face(clock: leaving.clock, traits: traits), arrivingFace, by: done)
        } else {
            drive = arriving
            target = arrivingFace
        }

        // What a landing left behind. Both decay on their own clock, so the
        // squash always comes back and no mood can leave the body permanently
        // slack by forgetting to tidy up after itself.
        if softening > 0 || jiggle > 0 {
            softening = max(0, softening - Self.fixedStep / 0.24)
            jiggle = max(0, jiggle - Self.fixedStep / 0.55)
            jiggleClock += Self.fixedStep
            let eased = softening * softening
            drive.shapeStiffness *= 1 - 0.38 * eased
            drive.pressure *= 1 - 0.20 * eased
            drive.damping *= 1 - 0.22 * eased
            drive.jiggle += jiggle * jiggle * 0.55
            drive.jigglePhase = jiggleClock * 5.2
        }

        body.step(dt: Self.fixedStep, drive: drive)
        absorbLanding()
        // The face eases toward the mood's pose rather than being set to it,
        // which is what makes a change of mood read as an expression moving.
        face.ease(towards: target, rate: Self.fixedStep * 11)
        advanceBlink(Self.fixedStep)
    }

    /// Turn a landing into a splat.
    ///
    /// The floor reports how hard the body arrived. Everything a landing looks
    /// like is bought here, once, for every mood: the body goes briefly slack
    /// so the squash lingers past the bounce, a wave rings round the rim, and
    /// the ground puffs. A mood that adds a hop gets all of it for nothing.
    private func absorbLanding() {
        for index in dust.indices {
            dust[index].age += Self.fixedStep
        }
        guard let hit = body.takeImpact(), hit.speed > 0.32 else { return }
        let force = min(1, (hit.speed - 0.32) / 1.5)
        // The hardest recent landing, not the sum of them. Adding meant a
        // dancing character, which lands on every beat, saturated inside two
        // bars and stayed a slack bag for the rest of the song.
        softening = max(softening, force)
        jiggle = max(jiggle, force)
        jiggleClock = 0
        guard force > 0.18 else { return }
        dust[dustCursor] = (x: hit.x, age: 0, weight: force)
        dustCursor = (dustCursor + 1) % dust.count
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
        addDust()
    }

    /// The ground answering back. Two puffs per landing, thrown outwards from
    /// where the body actually hit rather than from the middle of the frame,
    /// so a character that lands off to one side kicks dust up on that side.
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
            body.impulse(CGVector(dx: 0, dy: -1.30))
            body.pulse(0.24)
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

    /// Discrete beats. Everything continuous is a force in `PersonaMood`;
    /// this is only what has to happen *at* an instant, which is what a hop, a
    /// beat and a bounce are.
    ///
    /// Anticipation lives here too, and it is most of what separates this from
    /// a thing that merely moves. A jump with nothing before it reads as a
    /// teleport upward. The same jump with a crouch an eighth of a second
    /// earlier reads as a decision, and the crouch is one extra call.
    private func fireEvents(from previous: CGFloat, to now: CGFloat) {
        switch mood {
        case .bouncing:
            // Re-kick once it has run out of bounce, rather than on a timer,
            // so the rhythm comes from the physics and a heavy persona takes
            // longer to get going again than a light one.
            // Down, and no longer going anywhere. Measured on the body's
            // travel rather than its total energy, because a slack blob
            // quivering on the floor has plenty of the second kind and would
            // never be kicked again.
            let low = body.centroid.y > PersonaStage.floor - PersonaStage.restRadius * 1.12
            if low, abs(body.momentum.dy) < 0.14 {
                launches += 1
                let side: CGFloat = launches.isMultiple(of: 2) ? 1 : -1
                body.impulse(CGVector(dx: side * 0.34, dy: -1.45))
                body.pulse(-0.10)
            }

        case .working:
            guard PersonaMood.workAdmire(now) < 0.02 else { break }
            // The blow, and the body arriving behind it. A hammer that lands
            // without the shoulder following through is a hammer being waved.
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
                // The ball lands on the crown at the seam between two arcs,
                // and the wild one lands harder because it fell further.
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
            // A shake it cannot absorb, then it stops fighting.
            if now < 0.34, crossed(0.085, previous, now) {
                let side: CGFloat = Int(previous / 0.085).isMultiple(of: 2) ? -1 : 1
                body.impulse(CGVector(dx: side * 1.05, dy: 0))
            }
            if crossed(0.34, previous, now) {
                body.slump(0.85)
            }
            // It has another go every few seconds, gets a third of the way up,
            // and gives that up as well.
            if now > 1.5, struck(4.4, 0.55, previous - 1.5, now - 1.5) {
                body.impulse(CGVector(dx: 0, dy: -0.62))
            }
            if now > 1.5, struck(4.4, 0.80, previous - 1.5, now - 1.5) {
                body.slump(0.45)
            }

        case .idle:
            // A shift of weight, so a resting character is not a loop.
            if crossed(5.4, previous, now) {
                let side: CGFloat = nextUnit() > 0.5 ? 1 : -1
                body.impulse(CGVector(dx: side * 0.12, dy: -0.10))
            }
            if struck(11.5, 0.62, previous, now) {
                body.impulse(CGVector(dx: 0, dy: -0.30))
            }

        case .thinking:
            // The idea arrives as a jolt. It is the one moment in this mood
            // that is not churn, so it has to land like one.
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
                body.slump(0.55)
            } else if crossed(0.26, previous, now) {
                body.poke(at: body.anchors.hands, strength: -0.13, reach: 0.20)
            }

        case .pacing:
            if PersonaMood.pacingIdea(now) < 0.25 {
                // A footfall, and a heavier one at each turn where it plants
                // and pushes off the other way.
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
            // Keystrokes, not hops. A small local knock at the hands for each
            // one, fast and uneven, so the body ripples the way a hand landing
            // on a key ripples the arm it is on.
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
            // Something on the page. The body has to move for it, or the face
            // is reacting to nothing.
            if struck(8.4, 0.66, previous, now) {
                if PersonaMood.readingGag(now).shock > 0 {
                    body.impulse(CGVector(dx: 0, dy: -0.70))
                    body.pulse(0.16)
                } else {
                    body.pulse(-0.12)
                }
            }

        case .sipping:
            // Hot. The whole body finds out at once.
            if struck(PersonaMood.teaPeriod, 0.30, previous, now) {
                body.impulse(CGVector(dx: 0, dy: -0.55))
                body.poke(at: body.anchors.mouth, strength: -0.55, reach: 0.28)
            }

        case .sketching:
            // A small knock at each end of the sweep, where the hand changes
            // direction. That is the only impulse a brush stroke has in it.
            if PersonaMood.sketch(now).look < 0.25, crossed(0.725, previous, now) {
                body.poke(at: body.anchors.hands, strength: -0.16, reach: 0.24)
            }

        case .stargazing:
            if struck(9.4, 0.40, previous, now) {
                body.impulse(CGVector(dx: 0, dy: -0.34))
                body.pulse(0.09)
            }

        case .sleeping:
            // A twitch, in the middle of a good dream.
            if struck(13.0, 0.62, previous, now) {
                body.poke(at: body.crown, strength: -0.22, reach: 0.28)
            }

        case .ok:
            // Once is a result. Twice is a celebration.
            if now < 0.7, crossed(0.62, previous, now) {
                body.impulse(CGVector(dx: 0, dy: -0.72))
                body.pulse(0.10)
            }

        case .bubbling:
            if struck(5.4, 0.60, previous, now) {
                // It knew. It has always known. It is surprised anyway.
                body.poke(at: body.anchors.mouth, strength: -0.95, reach: 0.34)
                body.impulse(CGVector(dx: -0.30, dy: -0.18))
                blinkHold = 0.12
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
        softening = 0
        jiggle = 0
        for index in dust.indices { dust[index].age = 10 }
    }

    private func crossed(_ period: CGFloat, _ previous: CGFloat, _ now: CGFloat) -> Bool {
        floor(previous / period) != floor(now / period)
    }

    /// Once per cycle, at a given phase of it. The same shift a mood applies
    /// when it works out where in its own story it is, so an impulse lands on
    /// the frame the face is already reacting.
    private func struck(_ period: CGFloat, _ at: CGFloat, _ previous: CGFloat, _ now: CGFloat) -> Bool {
        crossed(period, previous - at * period, now - at * period)
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
