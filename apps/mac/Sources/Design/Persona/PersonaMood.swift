// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
//
// Source-available for review, NOT open source. See LICENSE: no rights to
// redistribute, publish, or ship a build are granted. Read it, study it, run
// your own build of it.
// "tokenstat" is a trademark of pueev OU. See TRADEMARK.md.

import SwiftUI

/// What the character is doing, which is what the conversation is doing.
///
/// A mood is not a picture. It is three pure functions of elapsed time: the
/// forces to apply, where the face is looking, and what is in the air around
/// it. Nothing here positions a node, so every mood inherits weight, overshoot
/// and settle from the soft body underneath, and switching mood mid-bounce
/// carries the bounce across instead of cutting.
enum PersonaMood: Hashable, CaseIterable {
    /// Alive and doing nothing. Breathes, sways, blinks, shifts its weight.
    case idle
    /// A ball. Real gravity, a real floor, squash on landing, and a fresh
    /// kick whenever it runs out of bounce.
    case bouncing
    /// Something is turning over inside. Churn, a lean back, eyes up on a
    /// thought that orbits.
    case thinking
    /// Head down and hammering. Short heavy hops that thud rather than bounce,
    /// with dust.
    case working
    /// Talking. The body pulses with the mouth, so a streaming reply has a
    /// voice rather than a spinner.
    case speaking
    /// Keeping a ball up, leaning left and right to meet it, taking the hit
    /// on the crown each time.
    case juggling
    /// On the beat: squash down, spring up, sway, and a hop every fourth.
    case dancing
    /// A tool is waiting on a person. Leans in, eyes wide, taps its foot, and
    /// wears the colour that already means "your turn" everywhere else.
    case waiting
    /// It worked. One big jump, a stretch at the top, sparks, then a settle.
    case ok
    /// It failed. A hard shake, then the whole thing gives up and melts into
    /// a puddle that drips.
    case failed
    /// Out cold. Flat, slow, closed, with z's.
    case sleeping
    /// Reading the paper. Eyes scan a line at a time and it turns the page
    /// every so often.
    case reading
    /// Playing something handheld. Rocks with the action, wins occasionally.
    case gaming
    /// Walking the floor and thinking about it. Leans into the direction it
    /// is going and turns around at the edges.
    case pacing

    // MARK: - Forces

    /// The forces for this instant. `clock` is seconds since the mood began.
    func drive(clock: CGFloat, traits: PersonaTraits) -> PersonaDrive {
        var drive = PersonaDrive()
        drive.damping = 3.4 * traits.firmness
        drive.ringStiffness = 210 * traits.firmness
        drive.shapeStiffness = 150 * traits.firmness
        drive.pressure = 44 * traits.firmness

        switch self {
        case .idle:
            let breathe = sin(clock * 2 * .pi / 2.8)
            let drift = sin(clock * 2 * .pi / 6.7)
            drive.stretch = CGSize(width: 1 + breathe * 0.032, height: 1 - breathe * 0.030)
            drive.anchorX = PersonaStage.centreX + drift * 0.014
            drive.lean = drift * 0.05
            drive.wobble = 0.05
            drive.wobblePhase = clock * 0.36
            drive.gravity = 0.9

        case .bouncing:
            drive.gravity = 2.9
            drive.restitution = 0.58
            drive.friction = 0.94
            drive.damping = 1.5 * traits.firmness
            drive.pressure = 56 * traits.firmness
            drive.anchorPull = 2.4
            // A little smaller in the air, which buys the headroom the hop
            // needs without the resting character being smaller than it was.
            drive.radius = PersonaStage.restRadius * 0.90
            drive.stretch = CGSize(width: 1, height: 1)

        case .thinking:
            drive.gravity = 0.85
            drive.damping = 4.0 * traits.firmness
            drive.swirl = 0.16 * sin(clock * 2 * .pi / 1.7)
            drive.wobble = 0.24
            drive.wobblePhase = clock * 0.62
            drive.lean = -0.07 + sin(clock * 2 * .pi / 2.3) * 0.05
            let breathe = sin(clock * 2 * .pi / 1.9)
            drive.stretch = CGSize(width: 1 - breathe * 0.018, height: 1 + breathe * 0.022)

        case .working:
            drive.gravity = 2.2
            drive.restitution = 0.10
            drive.damping = 4.6 * traits.firmness
            drive.pressure = 50 * traits.firmness
            drive.radius = PersonaStage.restRadius * 0.96
            drive.lean = sin(clock * 2 * .pi / 0.34) * 0.05
            drive.wobble = 0.10
            drive.wobblePhase = clock * 1.6

        case .speaking:
            let syllable = PersonaMood.speechEnvelope(clock)
            drive.gravity = 0.95
            drive.damping = 3.8 * traits.firmness
            drive.stretch = CGSize(width: 1 - syllable * 0.030, height: 1 + syllable * 0.040)
            drive.lean = sin(clock * 2 * .pi / 1.4) * 0.06
            drive.wobble = 0.06 + syllable * 0.10
            drive.wobblePhase = clock * 1.1

        case .juggling:
            let swing = sin(clock * 2 * .pi / (2 * PersonaMood.rallyPeriod))
            drive.gravity = 1.0
            drive.damping = 3.0 * traits.firmness
            drive.anchorX = PersonaStage.centreX + swing * 0.095
            drive.lean = swing * 0.30
            drive.anchorPull = 9

        case .dancing:
            let beat = clock / PersonaMood.beatPeriod
            let pump = sin(beat * 2 * .pi)
            let sway = sin(beat * .pi)
            drive.gravity = 1.35
            drive.restitution = 0.30
            drive.damping = 2.9 * traits.firmness
            drive.stretch = CGSize(width: 1 + pump * 0.075, height: 1 - pump * 0.070)
            drive.anchorX = PersonaStage.centreX + sway * 0.055
            drive.radius = PersonaStage.restRadius * 0.93
            drive.lean = sway * 0.20
            drive.anchorPull = 11

        case .waiting:
            let tap = max(0, sin(clock * 2 * .pi / 1.5))
            drive.gravity = 1.0
            drive.damping = 3.6 * traits.firmness
            drive.lean = 0.15 + sin(clock * 2 * .pi / 3.1) * 0.07
            drive.stretch = CGSize(width: 1 + tap * 0.030, height: 1 - tap * 0.028)
            drive.anchorX = PersonaStage.centreX + 0.012

        case .ok:
            drive.gravity = 2.7
            drive.restitution = 0.42
            drive.damping = 2.4 * traits.firmness
            drive.radius = PersonaStage.restRadius * 0.92
            let rise = max(0, 1 - clock / 0.45)
            drive.stretch = CGSize(width: 1 - rise * 0.14, height: 1 + rise * 0.20)

        case .failed:
            // Three phases in one expression: a shake it cannot absorb, a
            // collapse, then a puddle that is still very slightly alive.
            let melt = min(max((clock - 0.34) / 0.85, 0), 1)
            let eased = melt * melt * (3 - 2 * melt)
            drive.gravity = 1.1 + eased * 1.5
            drive.restitution = 0.30 * (1 - eased)
            drive.damping = (3.0 + eased * 1.4) * traits.firmness
            drive.pressure = (44 - eased * 18) * traits.firmness
            drive.shapeStiffness = (150 - eased * 88) * traits.firmness
            // A puddle is allowed to feel its own weight. That is the point.
            drive.support = 1 - eased * 0.7
            drive.stretch = CGSize(
                width: 1 + eased * 0.34,
                height: 1 - eased * 0.42 + sin(clock * 2 * .pi / 3.4) * 0.012
            )
            drive.lean = sin(clock * 2 * .pi / 4.1) * 0.03 * eased

        case .reading:
            let sway = sin(clock * 2 * .pi / 5.3)
            drive.gravity = 0.9
            drive.damping = 3.9 * traits.firmness
            drive.lean = 0.07 + sway * 0.035
            drive.anchorX = PersonaStage.centreX - 0.012 + sway * 0.008
            drive.stretch = CGSize(width: 1 + sway * 0.016, height: 1 - sway * 0.014)

        case .gaming:
            // Rocking, not swaying: two rates beating against each other, so
            // the lean never settles into a metronome.
            let rock = sin(clock * 2 * .pi * 1.15) * 0.65 + sin(clock * 2 * .pi * 0.43) * 0.35
            drive.gravity = 1.15
            drive.damping = 3.2 * traits.firmness
            drive.lean = rock * 0.26
            drive.anchorX = PersonaStage.centreX + rock * 0.030
            drive.anchorPull = 9

        case .pacing:
            let walk = PersonaMood.pacingWalk(clock)
            drive.gravity = 1.5
            drive.restitution = 0.14
            drive.damping = 3.4 * traits.firmness
            drive.anchorX = walk.x
            drive.radius = PersonaStage.restRadius * 0.88
            // Leaning into the direction of travel, and standing up straight
            // at the turns, which is where the lean crosses zero anyway.
            drive.lean = walk.direction * 0.20
            drive.anchorPull = 13

        case .sleeping:
            let breathe = sin(clock * 2 * .pi / 4.6)
            drive.gravity = 1.0
            drive.damping = 4.6 * traits.firmness
            drive.pressure = 34 * traits.firmness
            drive.stretch = CGSize(
                width: 1.17 + breathe * 0.035,
                height: 0.74 - breathe * 0.038
            )
            drive.wobble = 0.03
            drive.wobblePhase = clock * 0.12
        }
        return drive
    }

    // MARK: - Face

    /// Where the face is, before the body's own motion pushes it around.
    func face(clock: CGFloat, traits: PersonaTraits) -> PersonaFacePose {
        var face = PersonaFacePose()
        switch self {
        case .idle:
            face.gaze = CGPoint(
                x: sin(clock * 2 * .pi / 7.3) * 0.22,
                y: sin(clock * 2 * .pi / 9.1) * 0.10
            )
            face.mouthCurve = traits.mouth == .frown ? -0.30 : 0.45

        case .bouncing:
            face.openness = 1.06
            face.mouthCurve = 0.5
            face.mouthOpen = 0.30
            face.gaze = CGPoint(x: 0, y: -0.12)

        case .thinking:
            let orbit = clock * 2 * .pi / 2.4
            face.lift = 0.10
            face.gaze = CGPoint(x: 0.42 + cos(orbit) * 0.22, y: -0.55 + sin(orbit) * 0.16)
            face.openness = 0.86
            face.squint = 0.24
            face.brow = 0.30
            face.mouthCurve = -0.05
            face.mouthWidth = 0.70

        case .working:
            face.openness = 0.52
            face.squint = 0.42
            face.brow = 0.55
            face.gaze = CGPoint(x: 0, y: 0.42)
            face.lift = -0.02
            face.mouthCurve = -0.1
            face.mouthWidth = 0.75
            face.blinks = false

        case .speaking:
            let syllable = PersonaMood.speechEnvelope(clock)
            face.mouthOpen = 0.32 + syllable * 0.72
            face.mouthCurve = 0.30
            face.mouthWidth = 1.25 + syllable * 0.30
            face.gaze = CGPoint(x: sin(clock * 2 * .pi / 3.7) * 0.16, y: -0.06)

        case .juggling:
            let ball = PersonaMood.rallyBall(clock: clock)
            face.gaze = CGPoint(
                x: (ball.x - PersonaStage.centreX) * 3.4,
                y: (ball.y - 0.42) * 2.6
            )
            face.openness = 1.12
            face.mouthCurve = 0.45
            face.mouthOpen = 0.22
            face.blinks = false

        case .dancing:
            let beat = clock / PersonaMood.beatPeriod
            face.openness = 0.10
            face.squint = 0
            face.forceArcEyes = true
            face.mouthCurve = 0.85
            face.mouthOpen = 0.30 + max(0, sin(beat * 2 * .pi)) * 0.35
            face.gaze = CGPoint(x: sin(beat * .pi) * 0.3, y: 0)
            face.blinks = false

        case .waiting:
            face.openness = 1.34
            face.brow = -0.45
            face.lift = 0.05
            face.spread = 1.06
            face.gaze = CGPoint(x: 0, y: 0.08)
            face.mouthCurve = 0
            face.mouthOpen = 0.32
            face.mouthWidth = 0.64

        case .ok:
            face.forceArcEyes = true
            face.openness = 0.24
            face.mouthCurve = 1
            face.mouthOpen = 0.45
            face.blinks = false

        case .failed:
            let melt = min(max((clock - 0.34) / 0.85, 0), 1)
            face.openness = 1 - melt * 0.66
            face.brow = 0.35 + melt * 0.35
            face.gaze = CGPoint(x: 0, y: 0.30 + melt * 0.25)
            face.lift = -melt * 0.05
            face.mouthCurve = -0.8
            face.mouthWidth = 0.9
            face.blinks = false

        case .reading:
            // A saccade, not a sweep: eyes jump along a line, drop to the
            // next one, and jump back. Reading is what that looks like.
            let line = clock / 2.1
            let across = line - floor(line)
            face.gaze = CGPoint(
                x: -0.55 + floor(across * 5) / 4 * 1.10,
                y: 0.30 + (Int(floor(line)) % 3 == 2 ? 0.10 : 0)
            )
            face.openness = 0.86
            face.squint = 0.22
            face.brow = 0.16
            // Eyes up on the body, so they clear the top edge of the paper.
            face.lift = 0.07
            face.mouthCurve = 0.10
            face.mouthWidth = 0.7

        case .gaming:
            let win = PersonaMood.gamingWin(clock)
            face.openness = 1.06 - win * 0.9
            face.forceArcEyes = win > 0.5
            face.squint = 0.14
            face.brow = 0.34 - win * 0.8
            face.gaze = CGPoint(x: 0, y: 0.58)
            face.lift = -0.02
            face.mouthCurve = -0.05 + win * 1.0
            face.mouthOpen = 0.20 + win * 0.45
            face.mouthWidth = 0.68 + win * 0.4

        case .pacing:
            let walk = PersonaMood.pacingWalk(clock)
            face.gaze = CGPoint(x: walk.direction * 0.55, y: -0.10)
            face.openness = 0.92
            face.squint = 0.18
            face.brow = 0.28
            face.mouthCurve = -0.08
            face.mouthWidth = 0.72

        case .sleeping:
            face.openness = 0.05
            face.forceArcEyes = true
            face.arcFlipped = true
            face.lift = -0.02
            face.mouthCurve = 0.15
            face.mouthOpen = 0.18 + max(0, sin(clock * 2 * .pi / 4.6)) * 0.22
            face.mouthWidth = 0.5
            face.blinks = false
        }
        return face
    }

    // MARK: - What is in the air

    /// Everything that is not the creature: a thought, a ball, sparks, notes,
    /// z's, a drip. Written into a buffer the engine owns, so a frame of
    /// motion allocates nothing.
    func motes(clock: CGFloat, traits: PersonaTraits, at anchors: PersonaAnchors, into motes: inout [PersonaMote]) {
        let crown = anchors.crown
        switch self {
        case .thinking:
            let orbit = clock * 2 * .pi / 2.4
            let centre = CGPoint(x: crown.x + 0.17, y: crown.y - 0.10)
            motes.append(PersonaMote(
                kind: .dot,
                position: CGPoint(x: centre.x + cos(orbit) * 0.075, y: centre.y + sin(orbit) * 0.045),
                scale: 0.9,
                opacity: 0.85
            ))
            motes.append(PersonaMote(
                kind: .dot,
                position: CGPoint(x: centre.x + cos(orbit + 2.2) * 0.052, y: centre.y + sin(orbit + 2.2) * 0.031),
                scale: 0.55,
                opacity: 0.5
            ))

        case .juggling:
            motes.append(PersonaMote(
                kind: .ball,
                position: PersonaMood.rallyBall(clock: clock),
                scale: 1,
                opacity: 1
            ))

        case .working:
            // Dust from the last two landings, so a hop leaves a trace.
            let period = PersonaMood.workPeriod
            for step in 0..<2 {
                let age = clock.truncatingRemainder(dividingBy: period) + CGFloat(step) * period
                guard age < 0.42 else { continue }
                let life = age / 0.42
                let side: CGFloat = step == 0 ? -1 : 1
                motes.append(PersonaMote(
                    kind: .puff,
                    position: CGPoint(
                        x: crown.x + side * (0.09 + life * 0.10),
                        y: PersonaStage.floor - life * 0.045
                    ),
                    scale: 0.5 + life * 0.7,
                    opacity: (1 - life) * 0.4
                ))
            }

        case .ok:
            for index in 0..<7 {
                let angle = CGFloat(index) * (2 * .pi / 7) - .pi / 2
                let life = min(max(clock / 0.85, 0), 1)
                guard life < 1 else { break }
                let reach = 0.06 + life * 0.20
                motes.append(PersonaMote(
                    kind: .spark,
                    position: CGPoint(
                        x: crown.x + cos(angle) * reach,
                        y: crown.y - 0.02 + sin(angle) * reach * 0.85
                    ),
                    scale: 1 - life * 0.5,
                    opacity: (1 - life) * (1 - life),
                    angle: angle
                ))
            }

        case .dancing:
            let period = PersonaMood.beatPeriod * 2
            for step in 0..<2 {
                let age = clock.truncatingRemainder(dividingBy: period) + CGFloat(step) * period
                guard age < 1.6 else { continue }
                let life = age / 1.6
                let side: CGFloat = step == 0 ? 1 : -1
                motes.append(PersonaMote(
                    kind: .note,
                    position: CGPoint(
                        x: crown.x + side * (0.15 + sin(life * .pi * 1.5) * 0.05),
                        y: crown.y - 0.02 - life * 0.30
                    ),
                    scale: 0.8 + life * 0.3,
                    opacity: (1 - life) * 0.9,
                    angle: side * 0.25
                ))
            }

        case .sleeping:
            let period: CGFloat = 1.7
            for step in 0..<3 {
                let age = clock.truncatingRemainder(dividingBy: period) + CGFloat(step) * period
                guard age < 3.4 else { continue }
                let life = age / 3.4
                motes.append(PersonaMote(
                    kind: .zed,
                    position: CGPoint(
                        x: crown.x + 0.12 + sin(life * .pi * 2) * 0.035 + life * 0.06,
                        y: crown.y - 0.02 - life * 0.34
                    ),
                    scale: 0.55 + life * 0.75,
                    opacity: min(life * 4, 1) * (1 - life)
                ))
            }

        case .failed:
            let period: CGFloat = 2.6
            let age = clock.truncatingRemainder(dividingBy: period)
            guard clock > 1.0, age < 1.2 else { return }
            let life = age / 1.2
            motes.append(PersonaMote(
                kind: .drop,
                position: CGPoint(
                    x: crown.x + 0.17,
                    y: PersonaStage.floor - 0.075 + life * life * 0.085
                ),
                scale: 1 - life * 0.35,
                opacity: min(life * 5, 1) * (1 - life * life)
            ))

        case .reading:
            // One sheet, held, drifting. There was a page turn here and it
            // was not worth it: the interesting part of somebody reading is
            // that they are absorbed and barely moving, and an event every few
            // seconds argues with that.
            let sway = sin(clock * 2 * .pi / 5.3)
            motes.append(PersonaMote(
                kind: .paper,
                position: CGPoint(
                    x: anchors.raised.x + sway * 0.014,
                    y: anchors.raised.y + sin(clock * 2 * .pi / 3.7) * 0.006
                ),
                scale: anchors.bounds.width / (PersonaStage.restRadius * 2),
                opacity: 1,
                angle: sway * 0.055
            ))

        case .gaming:
            let win = PersonaMood.gamingWin(clock)
            // The screen faces him, so what reaches us is the light off it.
            // Drawn under the face rather than over the body, which is what
            // makes it read as a screen rather than a lamp.
            motes.append(PersonaMote(
                kind: .glow,
                position: CGPoint(x: anchors.hands.x, y: anchors.hands.y - 0.03),
                scale: 1 + win * 0.7,
                opacity: 0.55 + win * 0.45
            ))
            motes.append(PersonaMote(
                kind: .console,
                position: anchors.hands,
                scale: 1,
                opacity: 1,
                // Three rates: a rock, a lean, and the small fast jitter of
                // somebody actually working the buttons.
                angle: sin(clock * 2 * .pi * 1.15) * 0.15
                    + sin(clock * 2 * .pi * 0.43) * 0.10
                    + sin(clock * 2 * .pi * 6.3) * 0.028
            ))
            guard win > 0.1 else { return }
            for index in 0..<4 {
                let angle = -CGFloat.pi / 2 + (CGFloat(index) - 1.5) * 0.42
                motes.append(PersonaMote(
                    kind: .spark,
                    position: CGPoint(
                        x: anchors.hands.x + cos(angle) * (0.06 + (1 - win) * 0.10),
                        y: anchors.hands.y - 0.04 + sin(angle) * (0.05 + (1 - win) * 0.08)
                    ),
                    scale: win,
                    opacity: win,
                    angle: angle
                ))
            }

        case .pacing:
            let orbit = clock * 2 * .pi / 2.9
            motes.append(PersonaMote(
                kind: .dot,
                position: CGPoint(
                    x: crown.x + 0.15 + cos(orbit) * 0.045,
                    y: crown.y - 0.10 + sin(orbit) * 0.030
                ),
                scale: 0.75,
                opacity: 0.7
            ))

        case .idle, .bouncing, .speaking, .waiting:
            break
        }
    }

    // MARK: - Meaning

    /// An outline and ink colour that overrides the persona's own, for the two
    /// states that carry a meaning the app already has a colour for.
    var tint: Color? {
        switch self {
        case .waiting: return Theme.warning
        case .failed: return Theme.danger
        default: return nil
        }
    }

    /// Frames per second worth spending. Half rate is invisible on a slow
    /// breathe and halves the cost of a transcript full of faces.
    var frameRate: Double {
        switch self {
        case .idle, .sleeping, .waiting, .reading: return 30
        default: return 60
        }
    }

    var label: String {
        switch self {
        case .idle: return "Idle"
        case .bouncing: return "Bouncing"
        case .thinking: return "Thinking"
        case .working: return "Working"
        case .speaking: return "Replying"
        case .juggling: return "Juggling"
        case .dancing: return "Dancing"
        case .waiting: return "Waiting"
        case .ok: return "Done"
        case .failed: return "Failed"
        case .sleeping: return "Asleep"
        case .reading: return "Reading"
        case .gaming: return "Playing"
        case .pacing: return "Thinking"
        }
    }

    // MARK: - Shared timing

    /// One hit to the next, in the rally.
    static let rallyPeriod: CGFloat = 0.78
    /// 125bpm. Fast enough to read as a beat at 26pt, slow enough not to buzz.
    static let beatPeriod: CGFloat = 0.48
    /// One hammer blow to the next.
    static let workPeriod: CGFloat = 0.36

    /// One length of the floor, there or back.
    static let stridePeriod: CGFloat = 2.6

    /// Where a pacing character is and which way it is going.
    ///
    /// A cosine rather than a triangle wave, so it slows into each turn and
    /// speeds up across the middle, which is what walking a floor looks like.
    static func pacingWalk(_ clock: CGFloat) -> (x: CGFloat, direction: CGFloat) {
        let turn = clock * .pi / stridePeriod
        return (
            x: PersonaStage.centreX - cos(turn) * 0.175,
            direction: sin(turn) > 0 ? 1 : -1
        )
    }

    /// Nought most of the time, one for a moment every few seconds. Something
    /// went right in the game.
    static func gamingWin(_ clock: CGFloat) -> CGFloat {
        let period: CGFloat = 4.3
        // Offset, so picking the thing up is not immediately winning at it.
        let since = (clock + 2.6).truncatingRemainder(dividingBy: period)
        guard since < 0.75 else { return 0 }
        return sin(since / 0.75 * .pi)
    }

    /// Speech as an envelope rather than a metronome: a fast syllable rate
    /// under a slow phrase rate, so it pauses for breath on its own.
    static func speechEnvelope(_ clock: CGFloat) -> CGFloat {
        let syllable = sin(clock * 2 * .pi * 5.1)
        let phrase = 0.55 + 0.45 * sin(clock * 2 * .pi * 0.41)
        return max(0, syllable) * phrase
    }

    /// The ball's parabola. Launched off the crown, apex alternating sides, so
    /// the body has a reason to lean one way and then the other.
    static func rallyBall(clock: CGFloat) -> CGPoint {
        let period = rallyPeriod
        let index = floor(clock / period)
        let t = clock / period - index
        let side: CGFloat = index.truncatingRemainder(dividingBy: 2) == 0 ? 1 : -1
        let from = PersonaStage.centreX - side * 0.17
        let to = PersonaStage.centreX + side * 0.17
        let x = from + (to - from) * t
        // A parabola between the two crowns, apex near the top of the frame.
        let top: CGFloat = 0.06
        let launch: CGFloat = 0.22
        let y = launch - 4 * (launch - top) * t * (1 - t)
        return CGPoint(x: x, y: y)
    }
}

/// Where the face is and what it is doing, independent of where the body is.
///
/// Every field is a number rather than a case, so the engine can ease one pose
/// into the next and a mood change reads as an expression changing rather than
/// a mask being swapped.
struct PersonaFacePose {
    /// Eyelid. Zero is shut, one is normal, above one is wide.
    var openness: CGFloat = 1
    /// Lower lid. Concentration, not sleep.
    var squint: CGFloat = 0
    /// Where it is looking, in eye-radii.
    var gaze = CGPoint(x: 0, y: 0)
    /// Eyes higher or lower on the body than usual.
    var lift: CGFloat = 0
    /// Eye separation multiplier.
    var spread: CGFloat = 1
    /// Negative raises the brows, positive lowers the inner ends.
    var brow: CGFloat = 0
    /// Minus one is a frown, plus one a smile.
    var mouthCurve: CGFloat = 0
    var mouthOpen: CGFloat = 0
    var mouthWidth: CGFloat = 1
    var blinks = true
    /// Happy eyes: two arcs rather than two pupils. Not interpolated, because
    /// half an arc is not an expression.
    var forceArcEyes = false
    /// The arc, upside down. Closed and content rather than closed and pleased.
    var arcFlipped = false

    /// One expression part way into another. Used while a mood is changing,
    /// so the face is crossfading at the same time as the body rather than
    /// chasing a target that has already jumped.
    static func blend(_ from: PersonaFacePose, _ to: PersonaFacePose, by amount: CGFloat) -> PersonaFacePose {
        let t = max(0, min(1, amount))
        let k = t * t * (3 - 2 * t)
        func mix(_ a: CGFloat, _ b: CGFloat) -> CGFloat { a + (b - a) * k }
        var out = to
        out.openness = mix(from.openness, to.openness)
        out.squint = mix(from.squint, to.squint)
        out.gaze = CGPoint(x: mix(from.gaze.x, to.gaze.x), y: mix(from.gaze.y, to.gaze.y))
        out.lift = mix(from.lift, to.lift)
        out.spread = mix(from.spread, to.spread)
        out.brow = mix(from.brow, to.brow)
        out.mouthCurve = mix(from.mouthCurve, to.mouthCurve)
        out.mouthOpen = mix(from.mouthOpen, to.mouthOpen)
        out.mouthWidth = mix(from.mouthWidth, to.mouthWidth)
        // Eye shape is a decision, not a quantity. Half an arc is not an
        // expression, so it changes at the midpoint, under the blink.
        out.forceArcEyes = k < 0.5 ? from.forceArcEyes : to.forceArcEyes
        out.arcFlipped = k < 0.5 ? from.arcFlipped : to.arcFlipped
        return out
    }

    /// Component-wise ease toward a target. Runs every step with a time
    /// constant, so a face never snaps and never lags noticeably either.
    mutating func ease(towards target: PersonaFacePose, rate: CGFloat) {
        let k = min(rate, 1)
        openness += (target.openness - openness) * k
        squint += (target.squint - squint) * k
        gaze.x += (target.gaze.x - gaze.x) * k
        gaze.y += (target.gaze.y - gaze.y) * k
        lift += (target.lift - lift) * k
        spread += (target.spread - spread) * k
        brow += (target.brow - brow) * k
        mouthCurve += (target.mouthCurve - mouthCurve) * k
        mouthOpen += (target.mouthOpen - mouthOpen) * k
        mouthWidth += (target.mouthWidth - mouthWidth) * k
        blinks = target.blinks
        forceArcEyes = target.forceArcEyes
        arcFlipped = target.arcFlipped
    }
}

/// One thing in the air. Positions are in the same unit space as the body.
struct PersonaMote {
    enum Kind {
        case dot
        case ball
        case spark
        case note
        case zed
        case drop
        case puff
        /// An open newspaper, held.
        case paper
        /// The back of something handheld. The screen faces the character,
        /// not us.
        case console
        /// The light that screen throws back onto its face.
        case glow
    }

    var kind: Kind
    var position: CGPoint
    var scale: CGFloat = 1
    var opacity: CGFloat = 1
    var angle: CGFloat = 0
}
