// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
//
// Source-available: source sharing and own builds are permitted.
// Store and commercial distribution of builds is reserved. See LICENSE.
// "tokenstat" is a trademark of pueev OU. See TRADEMARK.md.

import SwiftUI

enum PersonaMood: Hashable, CaseIterable {
    case idle
    case bouncing
    case thinking
    case working
    case speaking
    case juggling
    case dancing
    case waiting
    case ok
    case failed
    case sleeping
    case reading
    case gaming
    case pacing
    case typing
    case sipping
    case sketching
    case stargazing
    case gardening
    case bubbling
    case snacking


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
            let yawn = PersonaMood.beat(PersonaMood.phase(clock, 11.5), 0.62, 0.76)
            drive.stretch = CGSize(
                width: 1 + breathe * 0.032 - yawn * 0.13,
                height: 1 - breathe * 0.030 + yawn * 0.22
            )
            drive.anchorX = PersonaStage.centreX + drift * 0.014
            drive.lean = drift * 0.05 - yawn * 0.05
            drive.wobble = 0.05
            drive.wobblePhase = clock * 0.36
            drive.gravity = 0.9 - yawn * 0.35

        case .bouncing:
            drive.gravity = 3.1
            drive.restitution = 0.62
            drive.friction = 0.94
            drive.damping = 1.25 * traits.firmness
            drive.pressure = 58 * traits.firmness
            drive.shapeStiffness = 118 * traits.firmness
            drive.anchorPull = 2.4
            drive.radius = PersonaStage.restRadius * 0.90
            drive.stretch = CGSize(width: 1, height: 1)

        case .thinking:
            let idea = PersonaMood.thinkingIdea(clock)
            drive.gravity = 0.85 - idea * 0.55
            drive.damping = (4.0 - idea * 1.4) * traits.firmness
            drive.swirl = 0.16 * sin(clock * 2 * .pi / 1.7) * (1 - idea)
            drive.wobble = 0.24 * (1 - idea * 0.6)
            drive.wobblePhase = clock * 0.62
            drive.lean = (-0.07 + sin(clock * 2 * .pi / 2.3) * 0.05) * (1 - idea)
            let breathe = sin(clock * 2 * .pi / 1.9)
            drive.stretch = CGSize(
                width: 1 - breathe * 0.018 - idea * 0.13,
                height: 1 + breathe * 0.022 + idea * 0.20
            )

        case .working:
            let job = PersonaMood.hammering(clock)
            drive.gravity = 2.0
            drive.restitution = 0.10
            drive.damping = 4.4 * traits.firmness
            drive.pressure = 50 * traits.firmness
            drive.radius = PersonaStage.restRadius * 0.96
            drive.anchorX = PersonaStage.centreX - 0.06
            drive.anchorPull = 12
            drive.lean = 0.10 + job.strike * 0.30 - job.lift * 0.16 - job.admire * 0.34
            drive.stretch = CGSize(
                width: 1 + job.strike * 0.10 - job.admire * 0.05,
                height: 1 - job.strike * 0.09 + job.admire * 0.08
            )
            drive.wobble = 0.06
            drive.wobblePhase = clock * 1.2

        case .speaking:
            let syllable = PersonaMood.speechEnvelope(clock)
            drive.gravity = 0.95
            drive.damping = 3.1 * traits.firmness
            drive.stretch = CGSize(width: 1 - syllable * 0.085, height: 1 + syllable * 0.120)
            drive.lean = sin(clock * 2 * .pi / 1.4) * (0.10 + syllable * 0.08)
            drive.wobble = 0.10 + syllable * 0.24
            drive.wobblePhase = clock * 1.9

        case .juggling:
            let ball = PersonaMood.rallyBall(clock: clock)
            let swing = (ball.point.x - PersonaStage.centreX)
            drive.gravity = 1.0
            drive.damping = (3.0 - ball.panic * 0.9) * traits.firmness
            drive.anchorX = PersonaStage.centreX + swing * (0.55 + ball.panic * 0.55)
            drive.lean = swing * (1.5 + ball.panic * 1.4)
            drive.anchorPull = 9 + ball.panic * 7
            drive.stretch = CGSize(width: 1 - ball.panic * 0.06, height: 1 + ball.panic * 0.09)

        case .dancing:
            let beat = clock / PersonaMood.beatPeriod
            let pump = sin(beat * 2 * .pi)
            let sway = sin(beat * .pi)
            drive.gravity = 1.35
            drive.restitution = 0.30
            drive.damping = 3.0 * traits.firmness
            drive.stretch = CGSize(width: 1 + pump * 0.045, height: 1 - pump * 0.042)
            drive.anchorX = PersonaStage.centreX + sway * 0.075
            drive.radius = PersonaStage.restRadius * 0.95
            drive.lean = sway * 0.22
            drive.anchorPull = 9

        case .waiting:
            let tap = max(0, sin(clock * 2 * .pi / 1.2))
            let sigh = PersonaMood.waitingSigh(clock)
            drive.gravity = 1.0
            drive.damping = 3.6 * traits.firmness
            drive.lean = 0.15 + sin(clock * 2 * .pi / 3.1) * 0.07
            drive.stretch = CGSize(
                width: 1 + tap * 0.030 + sigh * 0.10,
                height: 1 - tap * 0.028 - sigh * 0.13
            )
            drive.anchorX = PersonaStage.centreX + 0.012

        case .ok:
            drive.gravity = 2.7
            drive.restitution = 0.42
            drive.damping = 2.1 * traits.firmness
            drive.shapeStiffness = 124 * traits.firmness
            drive.radius = PersonaStage.restRadius * 0.92
            let rise = max(0, 1 - clock / 0.45)
            drive.stretch = CGSize(width: 1 - rise * 0.20, height: 1 + rise * 0.28)

        case .failed:
            let melt = min(max((clock - 0.34) / 0.85, 0), 1)
            let eased = melt * melt * (3 - 2 * melt)
            let retry = PersonaMood.failedRetry(clock)
            drive.gravity = 1.1 + eased * 1.5
            drive.restitution = 0.30 * (1 - eased)
            drive.damping = (3.0 + eased * 1.4) * traits.firmness
            drive.pressure = (44 - eased * 18) * traits.firmness
            drive.shapeStiffness = (150 - eased * 88) * traits.firmness
            drive.support = 1 - eased * 0.7
            drive.stretch = CGSize(
                width: 1 + eased * 0.34 - retry * 0.22,
                height: 1 - eased * 0.42 + retry * 0.30 + sin(clock * 2 * .pi / 3.4) * 0.012
            )
            drive.lean = sin(clock * 2 * .pi / 4.1) * 0.03 * eased

        case .reading:
            let sway = sin(clock * 2 * .pi / 5.3)
            let gag = PersonaMood.readingGag(clock)
            drive.gravity = 0.9
            drive.damping = (3.9 - gag.laugh * 1.6) * traits.firmness
            drive.lean = 0.07 + sway * 0.035 - gag.shock * 0.20
            drive.anchorX = PersonaStage.centreX - 0.012 + sway * 0.008
            let chuckle = gag.laugh * sin(clock * 2 * .pi * 7.5)
            drive.stretch = CGSize(
                width: 1 + sway * 0.016 - gag.shock * 0.08 - chuckle * 0.05,
                height: 1 - sway * 0.014 + gag.shock * 0.13 + chuckle * 0.06
            )

        case .gaming:
            let rock = sin(clock * 2 * .pi * 1.15) * 0.65 + sin(clock * 2 * .pi * 0.43) * 0.35
            let round = PersonaMood.gamingRound(clock)
            drive.gravity = 1.15
            drive.damping = 3.2 * traits.firmness
            drive.lean = rock * 0.26 * (1 - round.loss) + round.loss * 0.14
            drive.anchorX = PersonaStage.centreX + rock * 0.030
            drive.anchorPull = 9
            drive.support = 1 - round.loss * 0.35
            drive.stretch = CGSize(
                width: 1 + round.loss * 0.16 - round.win * 0.10,
                height: 1 - round.loss * 0.20 + round.win * 0.15
            )

        case .pacing:
            let walk = PersonaMood.pacingWalk(PersonaMood.pacingClock(clock))
            let idea = PersonaMood.pacingIdea(clock)
            drive.gravity = 1.5
            drive.restitution = 0.14
            drive.damping = 3.4 * traits.firmness
            drive.anchorX = walk.x
            drive.radius = PersonaStage.restRadius * 0.88
            drive.lean = walk.direction * 0.20 * (1 - idea) - idea * 0.10
            drive.anchorPull = 13
            drive.stretch = CGSize(width: 1 - idea * 0.12, height: 1 + idea * 0.18)

        case .typing:
            let keys = PersonaMood.typing(clock)
            drive.gravity = 1.35
            drive.damping = 3.4 * traits.firmness
            drive.pressure = 42 * traits.firmness
            drive.anchorX = PersonaStage.centreX - 0.055
            drive.anchorPull = 12
            drive.lean = 0.24 * (1 - keys.pause) - keys.pause * 0.12 + keys.nod * 0.10
            drive.stretch = CGSize(
                width: 1 + keys.tap * 0.035 - keys.pause * 0.04,
                height: 1 - keys.tap * 0.040 + keys.pause * 0.06 + keys.nod * 0.05
            )
            drive.wobble = keys.pause * 0.14
            drive.wobblePhase = clock * 0.8

        case .sipping:
            let tea = PersonaMood.tea(clock)
            drive.gravity = 0.95
            drive.damping = 4.2 * traits.firmness
            let breathe = sin(clock * 2 * .pi / 5.2)
            drive.lean = breathe * 0.020 - tea.lift * 0.16
            drive.anchorX = PersonaStage.centreX - 0.020 * tea.lift
            drive.stretch = CGSize(
                width: 1 + breathe * 0.014 - tea.lift * 0.020,
                height: 1 - breathe * 0.013 + tea.lift * 0.026
            )

        case .sketching:
            let work = PersonaMood.sketch(clock)
            drive.gravity = 1.55
            drive.damping = 3.6 * traits.firmness
            drive.lean = 0.20 + work.sweep * 0.12 - work.look * 0.30
            drive.anchorX = PersonaStage.centreX - 0.09 + work.sweep * 0.030 - work.look * 0.045
            drive.anchorPull = 11
            drive.stretch = CGSize(
                width: 1 + abs(work.sweep) * 0.030 - work.look * 0.04,
                height: 1 - abs(work.sweep) * 0.026 + work.look * 0.06
            )

        case .stargazing:
            let sky = PersonaMood.sky(clock)
            drive.gravity = 0.82 - sky.gasp * 0.30
            drive.damping = 4.0 * traits.firmness
            drive.lean = sin(clock * 2 * .pi / 4.8) * 0.05 - sky.gasp * 0.10
            drive.stretch = CGSize(
                width: 0.99 - sky.gasp * 0.07 - sky.wish * 0.03,
                height: 1.01 + sky.gasp * 0.11 + sky.wish * 0.04
            )

        case .gardening:
            let plot = PersonaMood.garden(clock)
            let pat = max(0, sin(clock * 2 * .pi / 1.15)) * (1 - plot.joy)
            drive.gravity = 1.35
            drive.damping = 3.8 * traits.firmness
            drive.lean = (0.16 + pat * 0.08) * (1 - plot.joy) - plot.joy * 0.10
            drive.stretch = CGSize(
                width: 1 + pat * 0.025 - plot.joy * 0.10,
                height: 1 - pat * 0.020 + plot.joy * 0.16
            )
            drive.anchorX = PersonaStage.centreX - 0.055

        case .bubbling:
            let bubble = PersonaMood.bubble(clock)
            drive.gravity = 1.0
            drive.damping = (3.4 - bubble.blow * 0.8) * traits.firmness
            drive.pressure = (44 + bubble.blow * 16 - bubble.pop * 22) * traits.firmness
            drive.shapeStiffness = (150 - bubble.pop * 70) * traits.firmness
            drive.stretch = CGSize(
                width: 1 + bubble.blow * 0.10 - bubble.pop * 0.04,
                height: 1 + bubble.blow * 0.04 - bubble.pop * 0.10
            )
            drive.lean = 0.06 + bubble.blow * 0.08 - bubble.pop * 0.22
            drive.wobble = bubble.pop * 0.40
            drive.wobblePhase = clock * 4.2

        case .snacking:
            let snack = PersonaMood.snack(clock)
            drive.gravity = 1.2
            drive.damping = 3.5 * traits.firmness
            drive.lean = -0.10 - snack.bite * 0.30 + snack.chew * 0.05
            drive.anchorX = PersonaStage.centreX - 0.02
            let jaw = snack.chew * sin(clock * 2 * .pi * 4.6)
            drive.stretch = CGSize(
                width: 1 + snack.bite * 0.09 + jaw * 0.045 + snack.happy * 0.06,
                height: 1 - snack.bite * 0.07 - jaw * 0.050 - snack.happy * 0.04
            )
            drive.wobble = snack.happy * 0.22
            drive.wobblePhase = clock * 2.6

        case .sleeping:
            let snore = PersonaMood.snore(clock)
            drive.gravity = 1.0
            drive.damping = 4.6 * traits.firmness
            drive.pressure = (34 + snore.breath * 8) * traits.firmness
            drive.stretch = CGSize(
                width: 1.17 + snore.breath * 0.055,
                height: 0.74 - snore.breath * 0.058 + snore.dream * 0.05
            )
            drive.wobble = 0.03
            drive.wobblePhase = clock * 0.12
        }
        drive.stretch.width = min(max(drive.stretch.width, 0.88), 1.12)
        drive.stretch.height = min(max(drive.stretch.height, 0.88), 1.12)
        drive.shapeStiffness = max(drive.shapeStiffness, 145 * traits.firmness)
        drive.damping = max(drive.damping, 3.2 * traits.firmness)
        drive.pressure = max(drive.pressure, 40 * traits.firmness)
        drive.support = max(drive.support, 0.9)
        return drive
    }


    func face(clock: CGFloat, traits: PersonaTraits) -> PersonaFacePose {
        var face = PersonaFacePose()
        switch self {
        case .idle:
            let yawn = PersonaMood.beat(PersonaMood.phase(clock, 11.5), 0.62, 0.76)
            face.gaze = CGPoint(
                x: sin(clock * 2 * .pi / 7.3) * 0.22,
                y: sin(clock * 2 * .pi / 9.1) * 0.10
            )
            face.mouthCurve = traits.mouth == .frown ? -0.30 : 0.45
            if yawn > 0.08 {
                face.eyes = .contentArc
                face.brow = -0.30 * yawn
                face.mouthCurve = 0.10
                face.mouthOpen = yawn * 1.15
                face.mouthWidth = 0.72
                face.tongue = yawn * 0.35
                face.blinks = false
            }

        case .bouncing:
            face.openness = 1.10
            face.eyeScale = 1.14
            face.mouthCurve = 0.55
            face.mouthOpen = 0.55
            face.mouthWidth = 0.80
            face.tongue = 0.40
            face.gaze = CGPoint(x: 0, y: -0.12)
            face.blinks = false

        case .thinking:
            let idea = PersonaMood.thinkingIdea(clock)
            let orbit = clock * 2 * .pi / 2.4
            face.lift = 0.10
            face.gaze = CGPoint(x: 0.42 + cos(orbit) * 0.22, y: -0.55 + sin(orbit) * 0.16)
            face.openness = 0.86
            face.squint = 0.24 * (1 - idea)
            face.brow = 0.30 - idea * 0.75
            face.mouthCurve = -0.05 + idea * 1.0
            face.mouthWidth = 0.70 + idea * 0.35
            face.mouthOpen = idea * 0.55
            if idea > 0.45 {
                face.openness = 1.15
                face.squint = 0
                face.eyeScale = 1.10
            }

        case .working:
            let job = PersonaMood.hammering(clock)
            face.openness = 0.62 + job.admire * 0.30
            face.squint = 0.32 * (1 - job.admire)
            face.brow = 0.40 - job.admire * 0.55
            face.gaze = CGPoint(x: 0.45 - job.admire * 0.20, y: 0.60 - job.admire * 0.85)
            face.lift = -0.02
            face.mouthCurve = -0.1 + job.admire * 1.0 + job.strike * 0.2
            face.mouthWidth = 0.75
            face.mouthOpen = job.strike * 0.30
            face.blinks = false
            if job.admire > 0.55 { face.eyes = .happyArc }

        case .speaking:
            let syllable = PersonaMood.speechEnvelope(clock)
            face.openness = 1.0 + syllable * 0.16
            face.brow = -0.16 - syllable * 0.10
            face.mouthOpen = 0.24 + syllable * 0.62
            face.mouthCurve = 0.38
            face.mouthWidth = 1.05 + syllable * 0.30
            face.gaze = CGPoint(x: sin(clock * 2 * .pi / 3.7) * 0.25, y: -0.10)

        case .juggling:
            let ball = PersonaMood.rallyBall(clock: clock)
            face.gaze = CGPoint(
                x: (ball.point.x - PersonaStage.centreX) * 3.4,
                y: (ball.point.y - 0.42) * 2.6
            )
            face.openness = 1.12
            face.mouthCurve = 0.45 - ball.panic * 0.9
            face.mouthOpen = 0.22 + ball.panic * 0.7
            face.blinks = false
            if ball.panic > 0.35 {
                face.openness = 1.12 + ball.panic * 0.45
                face.eyeScale = 1 + ball.panic * 0.40
                face.brow = -0.4
            }

        case .dancing:
            let beat = clock / PersonaMood.beatPeriod
            face.openness = 0.10
            face.squint = 0
            face.eyes = .happyArc
            face.mouthCurve = 0.85
            face.mouthOpen = 0.20 + max(0, sin(beat * 2 * .pi)) * 0.22
            face.blush = 0.22
            face.gaze = CGPoint(x: sin(beat * .pi) * 0.3, y: 0)
            face.blinks = false

        case .waiting:
            let sigh = PersonaMood.waitingSigh(clock)
            face.openness = 1.12
            face.eyeScale = 1.06
            face.brow = -0.08 + sigh * 0.40
            face.lift = 0.02
            face.spread = 0.86
            face.gaze = CGPoint(x: sin(clock * 2 * .pi / 3.1) * 0.10, y: 0.04 + sigh * 0.25)
            face.mouthCurve = 0.34 - sigh * 0.70
            face.mouthOpen = 0.10 + sigh * 0.30
            face.mouthWidth = 0.58
            face.droop = sigh * 0.45
            if sigh > 0.55 { face.eyes = .contentArc }

        case .ok:
            face.eyes = .happyArc
            face.openness = 0.24
            face.mouthCurve = 1
            face.mouthOpen = 0.55
            face.mouthWidth = 1.10
            face.blush = 0.35
            face.blinks = false

        case .failed:
            let melt = min(max((clock - 0.34) / 0.85, 0), 1)
            let retry = PersonaMood.failedRetry(clock)
            face.openness = 1 - melt * 0.66
            face.brow = 0.35 + melt * 0.35
            face.droop = 0.35 + melt * 0.55
            face.gaze = CGPoint(x: 0, y: 0.30 + melt * 0.25)
            face.lift = -melt * 0.05
            face.mouthCurve = -0.8
            face.mouthWidth = 0.9
            face.mouthOpen = retry * 0.35
            face.blinks = false

        case .reading:
            let gag = PersonaMood.readingGag(clock)
            let line = clock / 2.1
            let across = line - floor(line)
            face.gaze = CGPoint(
                x: -0.55 + floor(across * 5) / 4 * 1.10,
                y: 0.30 + (Int(floor(line)) % 3 == 2 ? 0.10 : 0)
            )
            face.openness = 0.86
            face.squint = 0.22
            face.brow = 0.16
            face.lift = 0.07
            face.mouthCurve = 0.10
            face.mouthWidth = 0.7
            if gag.shock > 0.25 {
                face.openness = 0.86 + gag.shock * 0.60
                face.eyeScale = 1 + gag.shock * 0.35
                face.squint = 0
                face.gaze = CGPoint(x: 0, y: 0.20)
                face.brow = -0.5
                face.mouthOpen = gag.shock * 0.55
                face.mouthCurve = -0.3
            } else if gag.laugh > 0.25 {
                face.eyes = .happyArc
                face.mouthCurve = 0.9
                face.mouthOpen = gag.laugh * 0.75
                face.mouthWidth = 1.0
                face.tongue = gag.laugh * 0.30
                face.blush = gag.laugh * 0.35
            }

        case .gaming:
            let round = PersonaMood.gamingRound(clock)
            face.openness = 1.06 - round.win * 0.9
            face.squint = 0.14
            face.brow = 0.34 - round.win * 0.8 + round.loss * 0.5
            face.gaze = CGPoint(x: 0, y: 0.58)
            face.lift = -0.02
            face.mouthCurve = -0.05 + round.win * 1.1 - round.loss * 1.0
            face.mouthOpen = 0.20 + round.win * 0.55 + round.loss * 0.25
            face.mouthWidth = 0.68 + round.win * 0.45
            face.tongue = round.win * 0.40
            face.blush = round.win * 0.35
            if round.win > 0.45 {
                face.eyes = .happyArc
            } else if round.loss > 0.3 {
                face.openness = 0.55
                face.squint = 0.45
            }

        case .pacing:
            let walk = PersonaMood.pacingWalk(PersonaMood.pacingClock(clock))
            let idea = PersonaMood.pacingIdea(clock)
            face.gaze = CGPoint(x: walk.direction * 0.55 * (1 - idea), y: -0.10 - idea * 0.55)
            face.openness = 0.92
            face.squint = 0.18 * (1 - idea)
            face.brow = 0.28 - idea * 0.70
            face.mouthCurve = -0.08 + idea * 1.0
            face.mouthWidth = 0.72
            face.mouthOpen = idea * 0.45
            if idea > 0.45 {
                face.openness = 1.10
                face.squint = 0
                face.brow = -0.45
            }

        case .typing:
            let keys = PersonaMood.typing(clock)
            face.openness = 0.90 + keys.pause * 0.10
            face.squint = 0.22 * (1 - keys.pause)
            face.brow = 0.18 - keys.pause * 0.45
            face.gaze = CGPoint(x: 0.40 * (1 - keys.pause), y: 0.62 - keys.pause * 1.30)
            face.lift = -0.03
            face.mouthCurve = 0.10 - keys.pause * 0.28 + keys.nod * 0.80
            face.mouthWidth = 0.66
            face.blinks = false
            if keys.nod > 0.5 { face.eyes = .happyArc }

        case .sipping:
            let tea = PersonaMood.tea(clock)
            face.openness = 0.72 - tea.lift * 0.28
            face.squint = 0.20 + tea.lift * 0.25
            face.gaze = CGPoint(x: 0.12 * tea.lift, y: 0.40 - tea.lift * 0.10)
            face.lift = -0.02
            face.mouthCurve = 0.30 + tea.warm * 0.45
            face.mouthOpen = tea.lift * 0.10
            face.mouthWidth = 0.60
            face.blush = tea.warm * 0.30
            if tea.warm > 0.45 { face.eyes = .contentArc }

        case .sketching:
            let work = PersonaMood.sketch(clock)
            face.openness = 0.70
            face.squint = 0.30 * (1 - work.look)
            face.brow = 0.24 - work.look * 0.45
            face.gaze = CGPoint(x: 0.30 + work.sweep * 0.22, y: 0.62 - work.look * 0.34)
            face.lift = -0.04
            face.mouthCurve = 0.08 + work.look * 0.60
            face.mouthWidth = 0.66
            face.blinks = false
            if work.look > 0.5 {
                face.eyes = .happyArc
                face.blush = 0.25
            }

        case .stargazing:
            let sky = PersonaMood.sky(clock)
            let orbit = clock * 2 * .pi / 5.2
            face.openness = 1.05
            face.squint = 0.08
            face.brow = -0.12
            face.gaze = CGPoint(x: cos(orbit) * 0.40, y: -0.68 + sin(orbit) * 0.10)
            face.lift = 0.12
            face.mouthCurve = 0.45
            face.mouthWidth = 0.68
            if sky.gasp > 0.2 {
                face.eyeScale = 1 + sky.gasp * 0.35
                face.gaze = CGPoint(x: sky.starX * 2.2, y: -0.85)
                face.mouthOpen = sky.gasp * 0.60
                face.mouthWidth = 0.55
                face.brow = -0.45
            } else if sky.wish > 0.2 {
                face.eyes = .contentArc
                face.mouthCurve = 0.85
                face.blush = sky.wish * 0.45
            }

        case .gardening:
            let plot = PersonaMood.garden(clock)
            face.openness = 0.68
            face.squint = 0.22 * (1 - plot.joy)
            face.brow = 0.18 - plot.joy * 0.55
            face.gaze = CGPoint(x: 0.34, y: 0.56 - plot.joy * 0.40)
            face.lift = -0.04
            face.mouthCurve = 0.30 + plot.joy * 0.75
            face.mouthWidth = 0.66 + plot.joy * 0.30
            face.mouthOpen = plot.joy * 0.40
            face.blinks = false
            if plot.joy > 0.4 {
                face.eyes = .happyArc
                face.blush = 0.45
            }

        case .bubbling:
            let bubble = PersonaMood.bubble(clock)
            face.openness = 0.80
            face.squint = 0.30 * bubble.blow
            face.brow = 0.20 * bubble.blow
            face.gaze = CGPoint(x: 0, y: 0.45 + bubble.blow * 0.10)
            face.mouthCurve = 0.10
            face.mouthOpen = 0.22 + bubble.blow * 0.12
            face.mouthWidth = 0.42
            face.blush = bubble.blow * 0.25 + bubble.sheepish * 0.60
            if bubble.pop > 0.15 {
                face.openness = 0.80 + bubble.pop * 0.70
                face.eyeScale = 1 + bubble.pop * 0.45
                face.squint = 0
                face.brow = -0.6
                face.mouthOpen = 0.55
                face.mouthWidth = 0.80
                face.blinks = false
            } else if bubble.sheepish > 0.3 {
                face.eyes = .happyArc
                face.mouthCurve = 0.55
            }

        case .snacking:
            let snack = PersonaMood.snack(clock)
            face.openness = 0.80
            face.squint = 0.20 + snack.chew * 0.35
            face.gaze = CGPoint(x: -0.10, y: 0.42 - snack.bite * 0.20)
            face.mouthCurve = 0.35 + snack.happy * 0.60
            face.mouthWidth = 0.60 + snack.bite * 0.35
            face.mouthOpen = snack.bite * 1.10 + snack.chew * 0.16
            face.tongue = snack.bite * 0.35
            face.blush = snack.happy * 0.55
            if snack.chew > 0.4 || snack.happy > 0.4 { face.eyes = .contentArc }

        case .sleeping:
            let snore = PersonaMood.snore(clock)
            face.eyes = .contentArc
            face.openness = 0.05
            face.lift = -0.02
            face.mouthCurve = 0.15 + snore.dream * 0.5
            face.mouthOpen = 0.18 + max(0, snore.breath) * 0.34
            face.mouthWidth = 0.5
            face.blush = snore.dream * 0.40
            face.blinks = false
        }
        return face
    }


    func motes(clock: CGFloat, traits: PersonaTraits, at anchors: PersonaAnchors, into motes: inout [PersonaMote]) {
        let crown = anchors.crown
        switch self {
        case .idle:
            let yawn = PersonaMood.beat(PersonaMood.phase(clock, 11.5), 0.62, 0.76)
            guard yawn > 0.35 else { break }
            motes.append(PersonaMote(
                kind: .puff,
                position: CGPoint(x: anchors.mouth.x + 0.10, y: anchors.mouth.y - (yawn - 0.35) * 0.10),
                scale: 0.34 + (1 - yawn) * 0.30,
                opacity: (yawn - 0.35) * 0.34
            ))

        case .thinking:
            let idea = PersonaMood.thinkingIdea(clock)
            let orbit = clock * 2 * .pi / 2.4
            let centre = CGPoint(x: crown.x + 0.17, y: crown.y - 0.10)
            motes.append(PersonaMote(
                kind: .dot,
                position: CGPoint(x: centre.x + cos(orbit) * 0.075, y: centre.y + sin(orbit) * 0.045),
                scale: 0.9,
                opacity: 0.85 * (1 - idea)
            ))
            motes.append(PersonaMote(
                kind: .dot,
                position: CGPoint(x: centre.x + cos(orbit + 2.2) * 0.052, y: centre.y + sin(orbit + 2.2) * 0.031),
                scale: 0.55,
                opacity: 0.5 * (1 - idea)
            ))
            guard idea > 0.55 else { break }
            for index in 0..<4 {
                let angle = CGFloat(index) * (.pi / 2) - .pi / 4
                let burst = (idea - 0.55) / 0.45
                motes.append(PersonaMote(
                    kind: .dot,
                    position: CGPoint(
                        x: centre.x + cos(angle) * (0.03 + burst * 0.075),
                        y: max(0.06, centre.y) + sin(angle) * (0.02 + burst * 0.055)
                    ),
                    scale: 0.55 * (1 - burst * 0.5),
                    opacity: (1 - burst) * 0.8
                ))
            }

        case .juggling:
            let ball = PersonaMood.rallyBall(clock: clock)
            motes.append(PersonaMote(kind: .ball, position: ball.point, scale: 1, opacity: 1))
            guard ball.panic > 0.3 else { break }
            motes.append(PersonaMote(
                kind: .sweat,
                position: CGPoint(x: crown.x - 0.12, y: crown.y + 0.02 - ball.panic * 0.05),
                scale: 0.9,
                opacity: ball.panic,
                angle: -0.5
            ))

        case .working:
            let job = PersonaMood.hammering(clock)
            let nail = CGPoint(x: 0.77, y: PersonaStage.floor)
            let showing = max(1 - job.sunk * 0.78, 0.12)
            let head = CGPoint(x: nail.x, y: PersonaStage.floor - 0.10 * showing)
            motes.append(PersonaMote(kind: .nail, position: nail, scale: showing, opacity: 1))
            let grip = CGPoint(x: anchors.hands.x + 0.01, y: anchors.hands.y - 0.02)
            let aim = atan2(head.y - grip.y, max(head.x - grip.x, 0.01))
            motes.append(PersonaMote(
                kind: .hammer,
                position: grip,
                scale: 1,
                opacity: 1 - job.admire * 0.7,
                angle: aim - job.lift * 1.30
            ))
            if job.strike > 0.25 {
                motes.append(PersonaMote(
                    kind: .puff,
                    position: CGPoint(x: nail.x - 0.03, y: PersonaStage.floor - 0.02),
                    scale: 0.30 + job.strike * 0.30,
                    opacity: job.strike * 0.45
                ))
            }
            guard job.admire > 0.35 else { break }
            for index in 0..<3 {
                let angle = -CGFloat.pi / 2 + (CGFloat(index) - 1) * 0.6
                motes.append(PersonaMote(
                    kind: .spark,
                    position: CGPoint(
                        x: nail.x + cos(angle) * 0.08,
                        y: PersonaStage.floor - 0.05 + sin(angle) * 0.05
                    ),
                    scale: (job.admire - 0.35) * 0.9,
                    opacity: (job.admire - 0.35) * 1.5,
                    angle: angle
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
            for index in 0..<9 {
                let seed = CGFloat(index)
                let life = min(max((clock - seed * 0.045) / 2.4, 0), 1)
                guard life > 0, life < 1 else { continue }
                let drift = sin(seed * 2.4)
                motes.append(PersonaMote(
                    kind: .confetti,
                    position: CGPoint(
                        x: min(0.94, max(0.06, crown.x + drift * (0.10 + life * 0.24))),
                        y: crown.y - 0.16 + life * life * 0.72 + sin(seed) * 0.05
                    ),
                    scale: 0.85 + sin(seed * 5.1) * 0.25,
                    opacity: 1 - life * life,
                    angle: seed * 1.7 + clock * (3.0 + drift * 2)
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
                        x: min(0.86, max(0.14, crown.x + side * (0.13 + sin(life * .pi * 1.5) * 0.04))),
                        y: max(0.16, crown.y - 0.01 - life * 0.18)
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
            let snore = PersonaMood.snore(clock)
            if snore.breath < -0.4 {
                motes.append(PersonaMote(
                    kind: .puff,
                    position: CGPoint(x: anchors.mouth.x + 0.11, y: anchors.mouth.y),
                    scale: 0.30 + (-snore.breath - 0.4) * 0.9,
                    opacity: (-snore.breath - 0.4) * 0.42
                ))
            }
            guard snore.dream > 0.05 else { break }
            motes.append(PersonaMote(
                kind: .heart,
                position: CGPoint(x: crown.x - 0.14, y: crown.y - 0.04 - snore.dream * 0.16),
                scale: 0.75,
                opacity: snore.dream * 0.85,
                angle: -0.25
            ))

        case .failed:
            let retry = PersonaMood.failedRetry(clock)
            if retry > 0.25 {
                motes.append(PersonaMote(
                    kind: .sweat,
                    position: CGPoint(x: crown.x + 0.15, y: crown.y - 0.03 - retry * 0.05),
                    scale: 0.9,
                    opacity: (retry - 0.25) * 1.6,
                    angle: 0.5
                ))
            }
            let period: CGFloat = 2.6
            let age = clock.truncatingRemainder(dividingBy: period)
            guard clock > 1.0, age < 1.2 else { break }
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
            let gag = PersonaMood.readingGag(clock)
            let sway = sin(clock * 2 * .pi / 5.3)
            motes.append(PersonaMote(
                kind: .paper,
                position: CGPoint(
                    x: anchors.raised.x + sway * 0.014 + gag.shock * sin(clock * 44) * 0.012,
                    y: anchors.raised.y + sin(clock * 2 * .pi / 3.7) * 0.006 - gag.shock * 0.02
                ),
                scale: anchors.bounds.width / (PersonaStage.restRadius * 2),
                opacity: 1,
                angle: sway * 0.055 + gag.laugh * sin(clock * 26) * 0.05
            ))
            guard gag.shock > 0.25 else { break }
            motes.append(PersonaMote(
                kind: .mark,
                position: CGPoint(x: crown.x + 0.17, y: crown.y - 0.06 - gag.shock * 0.05),
                scale: 0.8 + gag.shock * 0.5,
                opacity: min(1, (gag.shock - 0.25) * 2.6)
            ))

        case .gaming:
            let round = PersonaMood.gamingRound(clock)
            motes.append(PersonaMote(
                kind: .glow,
                position: CGPoint(x: anchors.hands.x, y: anchors.hands.y - 0.03),
                scale: 1 + round.win * 0.7,
                opacity: 0.55 + round.win * 0.45 - round.loss * 0.30
            ))
            motes.append(PersonaMote(
                kind: .console,
                position: anchors.hands,
                scale: 1,
                opacity: 1,
                angle: sin(clock * 2 * .pi * 1.15) * 0.15
                    + sin(clock * 2 * .pi * 0.43) * 0.10
                    + sin(clock * 2 * .pi * 6.3) * 0.028
                    + round.loss * 0.5
            ))
            if round.loss > 0.2 {
                motes.append(PersonaMote(
                    kind: .mark,
                    position: CGPoint(x: crown.x + 0.16, y: crown.y - 0.05),
                    scale: 0.75,
                    opacity: min(1, (round.loss - 0.2) * 2.4),
                    angle: 1
                ))
                motes.append(PersonaMote(
                    kind: .sweat,
                    position: CGPoint(x: crown.x - 0.13, y: crown.y + 0.01),
                    scale: 0.8,
                    opacity: min(1, (round.loss - 0.2) * 2.0),
                    angle: -0.6
                ))
            }
            guard round.win > 0.1 else { break }
            for index in 0..<4 {
                let angle = -CGFloat.pi / 2 + (CGFloat(index) - 1.5) * 0.42
                motes.append(PersonaMote(
                    kind: .spark,
                    position: CGPoint(
                        x: anchors.hands.x + cos(angle) * (0.06 + (1 - round.win) * 0.10),
                        y: anchors.hands.y - 0.04 + sin(angle) * (0.05 + (1 - round.win) * 0.08)
                    ),
                    scale: round.win,
                    opacity: round.win,
                    angle: angle
                ))
            }
            for index in 0..<6 {
                let seed = CGFloat(index)
                motes.append(PersonaMote(
                    kind: .confetti,
                    position: CGPoint(
                        x: min(0.94, max(0.06, crown.x + sin(seed * 2.1) * 0.22)),
                        y: max(0.06, crown.y - 0.10 + (1 - round.win) * 0.30 + sin(seed) * 0.04)
                    ),
                    scale: 0.8,
                    opacity: round.win,
                    angle: seed * 1.9 + clock * 4
                ))
            }

        case .pacing:
            let idea = PersonaMood.pacingIdea(clock)
            let orbit = clock * 2 * .pi / 2.9
            motes.append(PersonaMote(
                kind: .dot,
                position: CGPoint(
                    x: crown.x + 0.15 + cos(orbit) * 0.045,
                    y: crown.y - 0.10 + sin(orbit) * 0.030
                ),
                scale: 0.75,
                opacity: 0.7 * (1 - idea)
            ))
            guard idea > 0.5 else { break }
            let burst = (idea - 0.5) / 0.5
            for index in 0..<3 {
                let angle = -CGFloat.pi / 2 + (CGFloat(index) - 1) * 0.8
                motes.append(PersonaMote(
                    kind: .dot,
                    position: CGPoint(
                        x: crown.x + 0.15 + cos(angle) * (0.02 + burst * 0.065),
                        y: max(0.07, crown.y - 0.10) + sin(angle) * (0.02 + burst * 0.05)
                    ),
                    scale: 0.5 * (1 - burst * 0.4),
                    opacity: (1 - burst) * 0.75
                ))
            }

        case .typing:
            let keys = PersonaMood.typing(clock)
            let keyboard = CGPoint(x: 0.66, y: PersonaStage.floor)
            motes.append(PersonaMote(
                kind: .keyboard,
                position: keyboard,
                scale: 1,
                opacity: 1,
                angle: keys.lit
            ))
            if keys.pause > 0.25 {
                motes.append(PersonaMote(
                    kind: .mark,
                    position: CGPoint(x: crown.x + 0.16, y: max(0.12, crown.y - 0.07)),
                    scale: 0.8,
                    opacity: min(1, (keys.pause - 0.25) * 2.4),
                    angle: 1
                ))
            }
            guard keys.tap > 0.55 else { break }
            motes.append(PersonaMote(
                kind: .spark,
                position: CGPoint(x: keyboard.x + keys.lit * 0.14 - 0.07, y: keyboard.y - 0.085),
                scale: 0.30,
                opacity: (keys.tap - 0.55) * 1.5,
                angle: .pi / 4
            ))

        case .sipping:
            let tea = PersonaMood.tea(clock)
            let mouth = anchors.mouth
            let rest = anchors.hands
            motes.append(PersonaMote(
                kind: .mug,
                position: CGPoint(
                    x: rest.x + 0.080 - tea.lift * 0.062,
                    y: rest.y + (mouth.y + 0.020 - rest.y) * tea.lift
                ),
                scale: 1,
                opacity: 1,
                angle: -tea.lift * 0.80
            ))
            for step in 0..<2 {
                let life = (clock + CGFloat(step) * 1.1).truncatingRemainder(dividingBy: 2.2) / 2.2
                motes.append(PersonaMote(
                    kind: .puff,
                    position: CGPoint(
                        x: rest.x + 0.09 + sin(life * .pi * 2) * 0.018,
                        y: rest.y - 0.16 - life * 0.14 - tea.lift * 0.10
                    ),
                    scale: 0.34 + life * 0.28,
                    opacity: (1 - life) * 0.30 * (1 - tea.lift)
                ))
            }
            guard tea.warm > 0.4 else { break }
            motes.append(PersonaMote(
                kind: .heart,
                position: CGPoint(x: crown.x + 0.15, y: crown.y - 0.03 - tea.warm * 0.12),
                scale: 0.65,
                opacity: (tea.warm - 0.4) * 1.3,
                angle: 0.2
            ))

        case .sketching:
            let work = PersonaMood.sketch(clock)
            let sheet = CGPoint(x: 0.66, y: PersonaStage.floor)
            motes.append(PersonaMote(kind: .sheet, position: sheet, scale: 1, opacity: 1))
            let tip = CGPoint(x: sheet.x + work.sweep * 0.10, y: sheet.y - 0.055)
            for step in 0..<3 {
                let age = CGFloat(step) * 0.13
                let trail = PersonaMood.sketchSweep(work.clock - age)
                motes.append(PersonaMote(
                    kind: .stroke,
                    position: CGPoint(x: sheet.x + trail * 0.10, y: sheet.y - 0.052),
                    scale: 0.5,
                    opacity: (1 - CGFloat(step) / 3) * 0.5 * (1 - work.look),
                    angle: 0
                ))
            }
            guard work.look < 0.5 else { break }
            motes.append(PersonaMote(
                kind: .brush,
                position: CGPoint(x: tip.x, y: tip.y - 0.085),
                scale: 1,
                opacity: 1 - work.look * 2,
                angle: 1.15 - work.sweep * 0.30
            ))

        case .speaking:
            break

        case .stargazing:
            let sky = PersonaMood.sky(clock)
            let orbit = clock * 2 * .pi / 5.2
            for index in 0..<3 {
                let angle = orbit + CGFloat(index) * 2.1
                motes.append(PersonaMote(
                    kind: .spark,
                    position: CGPoint(x: crown.x + cos(angle) * (0.12 + CGFloat(index) * 0.035), y: crown.y - 0.18 + sin(angle) * 0.055),
                    scale: 0.35 + CGFloat(index) * 0.12,
                    opacity: 0.50 + CGFloat(index) * 0.12,
                    angle: angle
                ))
            }
            if sky.crossing > 0 {
                motes.append(PersonaMote(
                    kind: .shootingStar,
                    position: CGPoint(x: sky.starX + PersonaStage.centreX, y: 0.10 + sky.crossing * 0.06),
                    scale: 1,
                    opacity: min(1, min(sky.crossing, 1 - sky.crossing) * 5),
                    angle: 0.32
                ))
            }
            guard sky.wish > 0.2 else { break }
            for side: CGFloat in [-1, 1] {
                motes.append(PersonaMote(
                    kind: .heart,
                    position: CGPoint(x: crown.x + side * 0.16, y: crown.y - 0.02 - sky.wish * 0.13),
                    scale: 0.7,
                    opacity: (sky.wish - 0.2) * 1.2,
                    angle: side * 0.25
                ))
            }

        case .gardening:
            let plot = PersonaMood.garden(clock)
            let root = CGPoint(x: 0.72, y: PersonaStage.floor)
            if plot.bloom < 0.5 {
                motes.append(PersonaMote(
                    kind: .sprout,
                    position: root,
                    scale: 0.45 + plot.growth * 0.85 + sin(clock * 2 * .pi / 3.4) * 0.05,
                    opacity: 1 - plot.bloom * 2
                ))
            }
            if plot.bloom > 0.02 {
                motes.append(PersonaMote(
                    kind: .flower,
                    position: CGPoint(x: root.x, y: root.y - 0.03 - 0.14 * plot.bloom),
                    scale: plot.bloom * 1.05,
                    opacity: min(1, plot.bloom * 2)
                ))
            }
            if plot.joy > 0.2 {
                for index in 0..<3 {
                    let angle = -CGFloat.pi / 2 + (CGFloat(index) - 1) * 0.72
                    motes.append(PersonaMote(
                        kind: .spark,
                        position: CGPoint(
                            x: root.x + cos(angle) * (0.08 + plot.joy * 0.05),
                            y: root.y - 0.19 + sin(angle) * (0.06 + plot.joy * 0.04)
                        ),
                        scale: plot.joy * 0.45,
                        opacity: plot.joy * 0.8,
                        angle: angle
                    ))
                }
            }
            let pat = max(0, sin(clock * 2 * .pi / 1.15))
            guard pat > 0.72, plot.joy < 0.2 else { break }
            motes.append(PersonaMote(
                kind: .puff,
                position: CGPoint(x: root.x - 0.05, y: PersonaStage.floor - 0.012),
                scale: 0.38,
                opacity: (pat - 0.72) / 0.28 * 0.35
            ))

        case .bubbling:
            let bubble = PersonaMood.bubble(clock)
            if bubble.size > 0.02 {
                motes.append(PersonaMote(
                    kind: .bubble,
                    position: CGPoint(
                        x: anchors.mouth.x + 0.10 + bubble.size * 0.10,
                        y: anchors.mouth.y - bubble.size * 0.02
                    ),
                    scale: 0.28 + bubble.size * 1.15,
                    opacity: 1
                ))
            }
            guard bubble.pop > 0.02 else { break }
            for index in 0..<6 {
                let angle = CGFloat(index) * (2 * .pi / 6)
                let reach = 0.04 + (1 - bubble.pop) * 0.16
                motes.append(PersonaMote(
                    kind: .puff,
                    position: CGPoint(
                        x: anchors.mouth.x + 0.16 + cos(angle) * reach,
                        y: anchors.mouth.y - 0.02 + sin(angle) * reach
                    ),
                    scale: 0.28 + (1 - bubble.pop) * 0.34,
                    opacity: bubble.pop * 0.55
                ))
            }

        case .snacking:
            let snack = PersonaMood.snack(clock)
            if snack.left > 0.02 {
                motes.append(PersonaMote(
                    kind: .cookie,
                    position: CGPoint(
                        x: anchors.hands.x + 0.10 - snack.bite * 0.045,
                        y: anchors.hands.y - 0.02 - snack.bite * 0.02
                    ),
                    scale: 1,
                    opacity: snack.left,
                    angle: snack.bites
                ))
            }
            if snack.bite > 0.4 {
                for index in 0..<3 {
                    let seed = CGFloat(index)
                    motes.append(PersonaMote(
                        kind: .dot,
                        position: CGPoint(
                            x: anchors.mouth.x + 0.06 + sin(seed * 3.1) * 0.05,
                            y: anchors.mouth.y + 0.02 + (snack.bite - 0.4) * (0.10 + seed * 0.04)
                        ),
                        scale: 0.24 + seed * 0.05,
                        opacity: (snack.bite - 0.4) * 1.2
                    ))
                }
            }
            guard snack.happy > 0.25 else { break }
            motes.append(PersonaMote(
                kind: .heart,
                position: CGPoint(x: crown.x + 0.14, y: crown.y - 0.03 - snack.happy * 0.12),
                scale: 0.7,
                opacity: (snack.happy - 0.25) * 1.4,
                angle: 0.2
            ))

        case .bouncing, .waiting:
            break
        }
    }


    var tint: Color? {
        switch self {
        case .waiting: return Theme.warning
        case .failed: return Theme.danger
        default: return nil
        }
    }

    var frameRate: Double {
        switch self {
        case .idle, .sleeping, .waiting, .stargazing, .gardening: return 30
        default: return 60
        }
    }

    var storyLength: Double {
        switch self {
        case .idle: return 11.5
        case .bouncing: return 3.0
        case .thinking: return 7.2
        case .working: return 4.2
        case .juggling: return 3.12
        case .dancing: return 3.84
        case .waiting: return 5.6
        case .sleeping: return 13.0
        case .reading: return 16.8
        case .gaming: return Double(Self.gamePeriod)
        case .pacing: return 9.1
        case .typing: return 6.4
        case .sipping: return Double(Self.teaPeriod)
        case .sketching: return 8.6
        case .stargazing: return 9.4
        case .gardening: return 11.2
        case .bubbling: return 5.4
        case .snacking: return 7.6
        case .speaking, .ok, .failed: return 0
        }
    }

    var label: String {
        switch self {
        case .idle: return L10n.text("common.idle")
        case .bouncing: return L10n.text("apple.personamood.bouncing.640dcae5")
        case .thinking: return L10n.text("apple.personamood.thinking.a20d12c5")
        case .working: return L10n.text("common.working")
        case .speaking: return L10n.text("apple.personamood.replying.b2663dd7")
        case .juggling: return L10n.text("apple.personamood.juggling.126aab73")
        case .dancing: return L10n.text("apple.personamood.dancing.9879cda2")
        case .waiting: return L10n.text("common.waiting")
        case .ok: return L10n.text("common.done")
        case .failed: return L10n.text("common.failed")
        case .sleeping: return L10n.text("apple.personamood.asleep.60135e8f")
        case .reading: return L10n.text("apple.personamood.reading.463816d0")
        case .gaming: return L10n.text("apple.personamood.playing.deaf6f9d")
        case .pacing: return L10n.text("apple.personamood.thinking.a20d12c5")
        case .typing: return L10n.text("apple.personamood.typing.25dfb9b4")
        case .sipping: return L10n.text("apple.personamood.tea_break.08af9306")
        case .sketching: return L10n.text("apple.personamood.sketching.edf49874")
        case .stargazing: return L10n.text("apple.personamood.stargazing.94665327")
        case .gardening: return L10n.text("apple.personamood.gardening.0fe4b0b9")
        case .bubbling: return L10n.text("apple.personamood.blowing_bubbles.8f2744ed")
        case .snacking: return L10n.text("apple.personamood.snack_break.5d92c6d3")
        }
    }


    static func phase(_ clock: CGFloat, _ period: CGFloat) -> CGFloat {
        clock.truncatingRemainder(dividingBy: period) / period
    }

    static func beat(_ phase: CGFloat, _ from: CGFloat, _ to: CGFloat) -> CGFloat {
        guard phase > from, phase < to else { return 0 }
        return sin((phase - from) / (to - from) * .pi)
    }

    static func ramp(_ phase: CGFloat, _ from: CGFloat, _ to: CGFloat) -> CGFloat {
        let t = min(max((phase - from) / max(to - from, 1e-4), 0), 1)
        return t * t * (3 - 2 * t)
    }

    static func stalledClock(_ clock: CGFloat, period: CGFloat, from: CGFloat, to: CGFloat) -> CGFloat {
        let cycles = floor(clock / period)
        let inside = clock - cycles * period
        let start = from * period
        let stop = to * period
        let held = stop - start
        return cycles * (period - held) + min(inside, start) + max(0, inside - stop)
    }


    static let rallyPeriod: CGFloat = 0.78
    static let beatPeriod: CGFloat = 0.48
    static let stridePeriod: CGFloat = 2.6

    static func pacingWalk(_ clock: CGFloat) -> (x: CGFloat, direction: CGFloat) {
        let turn = clock * .pi / stridePeriod
        return (
            x: PersonaStage.centreX - cos(turn) * 0.175,
            direction: sin(turn) > 0 ? 1 : -1
        )
    }

    static let paceThinkPeriod: CGFloat = 9.1
    static func pacingClock(_ clock: CGFloat) -> CGFloat {
        stalledClock(clock, period: paceThinkPeriod, from: 0.72, to: 0.88)
    }

    static func pacingIdea(_ clock: CGFloat) -> CGFloat {
        beat(phase(clock, paceThinkPeriod), 0.72, 0.90)
    }

    static let nailPeriod: CGFloat = 4.2
    static let blowPeriod: CGFloat = 0.66

    static func hammering(_ clock: CGFloat) -> (lift: CGFloat, strike: CGFloat, sunk: CGFloat, admire: CGFloat) {
        let cycle = phase(clock, nailPeriod)
        let admire = beat(cycle, 0.66, 0.94)
        guard admire < 0.02 else {
            return (lift: 0, strike: 0, sunk: 1, admire: admire)
        }
        let blows = floor(cycle * nailPeriod / blowPeriod)
        let swing = phase(clock, blowPeriod)
        let lift = swing < 0.74 ? ramp(swing, 0, 0.74) : 1 - ramp(swing, 0.74, 1)
        return (
            lift: lift,
            strike: beat(swing, 0.86, 1.0),
            sunk: min(1, blows / 4),
            admire: 0
        )
    }

    static func workAdmire(_ clock: CGFloat) -> CGFloat {
        hammering(clock).admire
    }

    static func thinkingIdea(_ clock: CGFloat) -> CGFloat {
        beat(phase(clock, 7.2), 0.80, 0.97)
    }

    static func waitingSigh(_ clock: CGFloat) -> CGFloat {
        beat(phase(clock, 5.6), 0.70, 0.92)
    }

    static func failedRetry(_ clock: CGFloat) -> CGFloat {
        guard clock > 1.5 else { return 0 }
        return beat(phase(clock - 1.5, 4.4), 0.55, 0.80)
    }

    static let typePeriod: CGFloat = 6.4

    static func typing(_ clock: CGFloat) -> (tap: CGFloat, lit: CGFloat, pause: CGFloat, nod: CGFloat) {
        let cycle = phase(clock, typePeriod)
        let pause = ramp(cycle, 0.62, 0.70) * (1 - ramp(cycle, 0.84, 0.90))
        let nod = beat(cycle, 0.88, 0.99)
        let patter = max(0, sin(clock * 2 * .pi * 6.4)) * (0.7 + 0.3 * sin(clock * 2 * .pi * 1.7))
        return (
            tap: patter * (1 - pause) * (1 - nod),
            lit: phase(clock, 0.37),
            pause: pause,
            nod: nod
        )
    }

    static let teaPeriod: CGFloat = 7.4

    static func tea(_ clock: CGFloat) -> (lift: CGFloat, warm: CGFloat) {
        let phase = phase(clock, teaPeriod)
        return (
            lift: max(beat(phase, 0.10, 0.30), beat(phase, 0.40, 0.60)),
            warm: beat(phase, 0.62, 0.98)
        )
    }

    static let gamePeriod: CGFloat = 10.4

    static func gamingRound(_ clock: CGFloat) -> (win: CGFloat, loss: CGFloat) {
        let period = gamePeriod / 2
        let round = Int(floor((clock + 2.6) / period))
        let event = beat(phase(clock + 2.6, period), 0.55, 0.76)
        return round.isMultiple(of: 2) ? (event, 0) : (0, event)
    }

    static let sketchPeriod: CGFloat = 8.6

    static func sketchSweep(_ clock: CGFloat) -> CGFloat {
        -cos(clock * 2 * .pi / 1.45)
    }

    static func sketch(_ clock: CGFloat) -> (clock: CGFloat, sweep: CGFloat, look: CGFloat) {
        let cycle = phase(clock, sketchPeriod)
        let held = stalledClock(clock, period: sketchPeriod, from: 0.74, to: 0.94)
        return (
            clock: held,
            sweep: sketchSweep(held),
            look: beat(cycle, 0.74, 0.96)
        )
    }

    static func sky(_ clock: CGFloat) -> (crossing: CGFloat, starX: CGFloat, gasp: CGFloat, wish: CGFloat) {
        let period: CGFloat = 9.4
        let phase = phase(clock, period)
        let crossing = phase > 0.30 && phase < 0.52 ? (phase - 0.30) / 0.22 : 0
        return (
            crossing: crossing,
            starX: -0.34 + crossing * 0.68,
            gasp: beat(phase, 0.34, 0.56),
            wish: beat(phase, 0.62, 0.94)
        )
    }

    static func garden(_ clock: CGFloat) -> (growth: CGFloat, bloom: CGFloat, joy: CGFloat) {
        let period: CGFloat = 11.2
        let phase = phase(clock, period)
        return (
            growth: ramp(phase, 0.04, 0.62),
            bloom: ramp(phase, 0.64, 0.74) * (1 - ramp(phase, 0.94, 0.99)),
            joy: beat(phase, 0.66, 0.92)
        )
    }

    static func bubble(_ clock: CGFloat) -> (size: CGFloat, blow: CGFloat, pop: CGFloat, sheepish: CGFloat) {
        let period: CGFloat = 5.4
        let phase = phase(clock, period)
        let growing = ramp(phase, 0.12, 0.60)
        return (
            size: growing * (1 - ramp(phase, 0.60, 0.615)),
            blow: beat(phase, 0.08, 0.62),
            pop: beat(phase, 0.60, 0.78),
            sheepish: beat(phase, 0.76, 0.99)
        )
    }

    static func snack(_ clock: CGFloat) -> (bite: CGFloat, chew: CGFloat, happy: CGFloat, left: CGFloat, bites: CGFloat) {
        let period: CGFloat = 7.6
        let phase = phase(clock, period)
        let starts: [CGFloat] = [0.10, 0.32, 0.54]
        var bite: CGFloat = 0
        var taken: CGFloat = 0
        for (index, start) in starts.enumerated() {
            bite = max(bite, beat(phase, start, start + 0.09))
            taken += ramp(phase, start + 0.04, start + 0.09) * CGFloat(index >= 0 ? 1 : 0)
        }
        let chew = max(
            max(beat(phase, 0.19, 0.30), beat(phase, 0.41, 0.52)),
            beat(phase, 0.63, 0.74)
        )
        return (
            bite: bite,
            chew: chew,
            happy: beat(phase, 0.74, 0.96),
            left: 1 - ramp(phase, 0.58, 0.64) + ramp(phase, 0.96, 0.99),
            bites: floor(taken)
        )
    }

    static func readingGag(_ clock: CGFloat) -> (shock: CGFloat, laugh: CGFloat) {
        let period: CGFloat = 8.4
        let round = Int(floor(clock / period))
        let event = beat(phase(clock, period), 0.62, 0.84)
        return round.isMultiple(of: 2) ? (event, 0) : (0, event)
    }

    static func snore(_ clock: CGFloat) -> (breath: CGFloat, dream: CGFloat) {
        (
            breath: sin(clock * 2 * .pi / 4.6),
            dream: beat(phase(clock, 13.0), 0.55, 0.80)
        )
    }

    static func speechEnvelope(_ clock: CGFloat) -> CGFloat {
        let syllable = sin(clock * 2 * .pi * 5.1)
        let phrase = 0.55 + 0.45 * sin(clock * 2 * .pi * 0.41)
        return max(0, syllable) * phrase
    }

    static func rallyBall(clock: CGFloat) -> (point: CGPoint, panic: CGFloat) {
        let period = rallyPeriod
        let index = floor(clock / period)
        let t = clock / period - index
        let side: CGFloat = index.truncatingRemainder(dividingBy: 2) == 0 ? 1 : -1
        let wild = index.truncatingRemainder(dividingBy: 4) == 3
        let reach: CGFloat = wild ? 0.30 : 0.17
        let from = PersonaStage.centreX - side * (wild ? 0.17 : reach)
        let to = PersonaStage.centreX + side * reach
        let x = from + (to - from) * t
        let top: CGFloat = wild ? 0.03 : 0.06
        let launch: CGFloat = 0.22
        let y = launch - 4 * (launch - top) * t * (1 - t)
        return (CGPoint(x: x, y: y), wild ? sin(t * .pi) : 0)
    }
}

struct PersonaFacePose {
    enum Eyes {
        case normal
        case happyArc
        case contentArc
    }


    var eyes: Eyes = .normal
    var openness: CGFloat = 1
    var squint: CGFloat = 0
    var gaze = CGPoint(x: 0, y: 0)
    var lift: CGFloat = 0
    var spread: CGFloat = 1
    var brow: CGFloat = 0
    var mouthCurve: CGFloat = 0
    var mouthOpen: CGFloat = 0
    var mouthWidth: CGFloat = 1
    var blinks = true
    var eyeScale: CGFloat = 1
    var blush: CGFloat = 0
    var tongue: CGFloat = 0
    var cheer: CGFloat = 0
    var droop: CGFloat = 0

    func expressed() -> PersonaFacePose {
        var out = self
        switch eyes {
        case .normal: break
        case .happyArc:
            out.cheer = 1
            out.squint = 0
            out.openness = 1
        case .contentArc:
            out.openness = 0
            out.cheer = 0
            out.blinks = false
        }
        out.eyes = .normal
        return out
    }

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
        out.eyeScale = mix(from.eyeScale, to.eyeScale)
        out.blush = mix(from.blush, to.blush)
        out.tongue = mix(from.tongue, to.tongue)
        out.cheer = mix(from.cheer, to.cheer)
        out.droop = mix(from.droop, to.droop)
        out.eyes = k < 0.5 ? from.eyes : to.eyes
        return out
    }

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
        eyeScale += (target.eyeScale - eyeScale) * k
        blush += (target.blush - blush) * k
        tongue += (target.tongue - tongue) * k
        cheer += (target.cheer - cheer) * k
        droop += (target.droop - droop) * k
        blinks = target.blinks
        eyes = target.eyes
    }
}

struct PersonaMote {
    enum Kind {
        case dot
        case ball
        case spark
        case note
        case zed
        case drop
        case puff
        case paper
        case console
        case glow
        case keyboard
        case sheet
        case mug
        case sprout
        case flower
        case mark
        case sweat
        case heart
        case shootingStar
        case confetti
        case stroke
        case bubble
        case cookie
        case hammer
        case nail
        case brush
    }

    var kind: Kind
    var position: CGPoint
    var scale: CGFloat = 1
    var opacity: CGFloat = 1
    var angle: CGFloat = 0
}
