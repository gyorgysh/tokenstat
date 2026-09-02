// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
//
// Source-available for review, NOT open source. See LICENSE: no rights to
// redistribute, publish, or ship a build are granted. Read it, study it, run
// your own build of it.
// "tokenstat" is a trademark of pueev OU. See TRADEMARK.md.

import SwiftUI

/// Everything a persona looks like, drawn in one pass.
///
/// One `Canvas`, not a stack of shape views. The previous mark layered a
/// shadow, two strokes, a fill and a canvas, which is five things for SwiftUI
/// to lay out and rasterise on every frame of a sixty-frame animation. Here
/// the whole character is a sequence of fills on one context, so a transcript
/// full of faces costs one draw each.
///
/// Nothing in here decides anything. It reads the engine and paints it, which
/// is why a new mood needs no drawing code: it moves the body, and the body is
/// what this file draws.
enum PersonaRenderer {
    static func draw(_ engine: PersonaEngine, in context: inout GraphicsContext, rect: CGRect) {
        let unit = min(rect.width, rect.height)
        guard unit > 1 else { return }

        let traits = engine.traits
        let body = engine.body
        let bounds = body.bounds
        let hue = traits.hue
        let ink = engine.mood.tint ?? hue
        let outline = Path(body.outline(in: rect))

        drawShadow(in: &context, rect: rect, bounds: bounds, unit: unit, hue: hue)

        if traits.hasAntenna, unit >= 18 {
            drawAntenna(in: &context, rect: rect, body: body, unit: unit, tint: hue)
        }

        let top = rect.minY + bounds.minY * rect.height
        let base = rect.minY + bounds.maxY * rect.height
        context.fill(
            outline,
            with: .linearGradient(
                Gradient(colors: [hue.opacity(0.20), hue.opacity(0.38)]),
                startPoint: CGPoint(x: rect.midX, y: top),
                endPoint: CGPoint(x: rect.midX, y: base)
            )
        )
        context.stroke(outline, with: .color(hue.opacity(0.92)), lineWidth: max(1, unit * 0.036))
        if let tint = engine.mood.tint {
            context.stroke(outline, with: .color(tint), lineWidth: max(1.5, unit * 0.055))
        }

        // Both clipped to the body, so a heavy squash or a melt pushes them
        // around inside the creature rather than letting an eye escape it.
        // Screen light is clipped there too: it falls on the face, and light
        // spilling past the silhouette would be a lamp, not a screen.
        context.drawLayer { layer in
            layer.clip(to: outline)
            drawHighlight(in: &layer, rect: rect, bounds: bounds)
            drawFace(engine, in: &layer, rect: rect, unit: unit, ink: ink)
            for mote in engine.motes where mote.kind == .glow {
                drawGlow(in: &layer, mote: mote, rect: rect, unit: unit, hue: hue)
            }
        }

        if unit >= 20 {
            drawMotes(engine, in: &context, rect: rect, unit: unit, hue: hue, ink: ink)
        }
    }

    // MARK: - Body

    private static func drawShadow(
        in context: inout GraphicsContext,
        rect: CGRect,
        bounds: CGRect,
        unit: CGFloat,
        hue: Color
    ) {
        // Contact shadow: it shrinks and fades as the body leaves the ground,
        // which is most of what sells a jump as a jump.
        let air = max(0, PersonaStage.floor - bounds.maxY)
        let closeness = max(0.30, 1 - air * 2.6)
        let width = bounds.width * rect.width * 0.80 * closeness
        let height = unit * 0.052 * closeness
        let y = rect.minY + PersonaStage.floor * rect.height - height * 0.35
        context.fill(
            Path(ellipseIn: CGRect(x: rect.midX - width / 2, y: y, width: width, height: height)),
            with: .color(hue.opacity(0.20 * closeness))
        )
    }

    private static func drawHighlight(in context: inout GraphicsContext, rect: CGRect, bounds: CGRect) {
        // Placed off the middle rather than off the bounding box, so a squash
        // slides it across the body instead of pinning it to a corner.
        let width = bounds.width * rect.width * 0.155
        let height = bounds.height * rect.height * 0.085
        let frame = CGRect(
            x: rect.minX + bounds.midX * rect.width - width * 1.55,
            y: rect.minY + (bounds.minY + bounds.height * 0.17) * rect.height,
            width: width,
            height: height
        )
        // A soft gradient rather than a flat ellipse: at 20% white a hard
        // edge reads as a scuff on the surface instead of light on it.
        context.fill(
            Path(ellipseIn: frame).applying(
                CGAffineTransform(translationX: frame.midX, y: frame.midY)
                    .rotated(by: -0.5)
                    .translatedBy(x: -frame.midX, y: -frame.midY)
            ),
            with: .radialGradient(
                Gradient(colors: [.white.opacity(0.26), .white.opacity(0)]),
                center: CGPoint(x: frame.midX, y: frame.midY),
                startRadius: 0,
                endRadius: max(frame.width, frame.height) * 0.62
            )
        )
    }

    private static func drawAntenna(
        in context: inout GraphicsContext,
        rect: CGRect,
        body: PersonaSoftBody,
        unit: CGFloat,
        tint: Color
    ) {
        // Rooted in the crown node, so it whips with the squash instead of
        // floating over a rectangle the body no longer fills.
        let crown = body.crown
        let root = CGPoint(x: rect.minX + crown.x * rect.width, y: rect.minY + crown.y * rect.height)
        let lean = (crown.x - body.centroid.x) * rect.width
        let tip = CGPoint(x: root.x + unit * 0.06 + lean * 1.6, y: root.y - unit * 0.15)
        var stalk = Path()
        stalk.move(to: CGPoint(x: root.x, y: root.y + unit * 0.02))
        stalk.addQuadCurve(to: tip, control: CGPoint(x: root.x + unit * 0.09 + lean, y: root.y - unit * 0.05))
        context.stroke(stalk, with: .color(tint.opacity(0.75)), lineWidth: max(1, unit * 0.032))
        context.fill(
            Path(ellipseIn: CGRect(
                x: tip.x - unit * 0.045,
                y: tip.y - unit * 0.045,
                width: unit * 0.09,
                height: unit * 0.09
            )),
            with: .color(tint)
        )
    }

    // MARK: - Face

    private static func drawFace(
        _ engine: PersonaEngine,
        in context: inout GraphicsContext,
        rect: CGRect,
        unit: CGFloat,
        ink: Color
    ) {
        let traits = engine.traits
        let face = engine.face
        let body = engine.body
        let bounds = body.bounds
        let centroid = body.centroid
        let crown = body.crown

        // The face borrows the body's own squash rather than being animated
        // separately. Wide and flat means narrow eyes further apart, tall and
        // thin means round eyes closer together. It costs one divide and it
        // is the single biggest reason the character reads as one material.
        let aspect = clamp(bounds.height / max(bounds.width, 1e-4), 0.45, 1.7)

        // Lean, taken from where the crown sits relative to the middle. The
        // face tilts with the body for free, in every mood.
        let tilt = atan2(crown.x - centroid.x, max(centroid.y - crown.y, 1e-4)) * 0.75

        let heightPoints = bounds.height * rect.height
        let anchorHeight = heightPoints * (0.10 + face.lift)
        let origin = CGPoint(
            x: rect.minX + centroid.x * rect.width,
            y: rect.minY + centroid.y * rect.height
        )
        func place(_ dx: CGFloat, _ dy: CGFloat) -> CGPoint {
            CGPoint(
                x: origin.x + dx * cos(tilt) - dy * sin(tilt),
                y: origin.y + dx * sin(tilt) + dy * cos(tilt)
            )
        }

        let count = traits.eyeCount
        // Small marks need proportionally bigger features or the face turns
        // into two specks. Three fixed steps, not a curve, so the 26pt seat
        // beside a message and the 30pt header look like the same creature.
        let lod: CGFloat = unit < 24 ? 1.35 : unit < 34 ? 1.15 : 1.0
        let radius = unit * (count == 1 ? 0.115 : count == 2 ? 0.082 : 0.065)
            * lod * clamp(face.eyeScale, 0.4, 2.2)
        let spread = radius * (count == 2 ? 2.9 : 2.6) * face.spread / max(sqrt(aspect), 0.6)
        let openness = max(0.02, face.openness * (1 - engine.blink * 0.96) * aspect)

        for index in 0..<count {
            let offset = CGFloat(index) - CGFloat(count - 1) / 2
            let centre = place(
                offset * spread + face.gaze.x * radius * 0.34,
                -anchorHeight + face.gaze.y * radius * 0.30
            )
            // The lower lid takes a bite out of the bottom of the eye.
            // Concentration reads as a lid: shrinking the whole eye instead
            // just makes the creature look further away.
            let lid = radius * 2 * openness * min(max(face.squint, 0), 0.8)
            let frame = CGRect(
                x: centre.x - radius,
                y: centre.y - radius * openness,
                width: radius * 2,
                height: max(radius * 0.10, radius * 2 * openness - lid)
            )
            switch face.eyes {
            case .happyArc:
                drawArcEye(in: &context, frame: frame, unit: unit, ink: ink, flipped: false)
            case .contentArc:
                drawArcEye(in: &context, frame: frame, unit: unit, ink: ink, flipped: true)
            case .normal:
                switch traits.eyeShape {
                case .pixel:
                    context.fill(Path(roundedRect: frame, cornerRadius: radius * 0.32), with: .color(ink))
                case .oval:
                    context.fill(Path(ellipseIn: frame.insetBy(dx: radius * 0.22, dy: 0)), with: .color(ink))
                case .round:
                    context.fill(Path(ellipseIn: frame), with: .color(ink))
                }
            }

            if unit >= 30, abs(face.brow) > 0.06 {
                drawBrow(
                    in: &context,
                    over: centre,
                    radius: radius,
                    unit: unit,
                    ink: ink,
                    amount: face.brow,
                    side: offset
                )
            }
        }

        if face.blush > 0.02, unit >= 26 {
            drawBlush(
                in: &context,
                place: place,
                anchorHeight: anchorHeight,
                radius: radius,
                spread: spread,
                unit: unit,
                amount: face.blush
            )
        }

        guard unit >= 21 else { return }
        drawMouth(
            in: &context,
            place: place,
            anchorHeight: anchorHeight,
            radius: radius,
            unit: unit,
            ink: ink,
            face: face,
            traits: traits
        )
    }

    private static func drawArcEye(
        in context: inout GraphicsContext,
        frame: CGRect,
        unit: CGFloat,
        ink: Color,
        flipped: Bool
    ) {
        var arc = Path()
        let lift = frame.width * 0.55
        if flipped {
            arc.move(to: CGPoint(x: frame.minX, y: frame.midY - lift * 0.3))
            arc.addQuadCurve(
                to: CGPoint(x: frame.maxX, y: frame.midY - lift * 0.3),
                control: CGPoint(x: frame.midX, y: frame.midY + lift * 0.9)
            )
        } else {
            arc.move(to: CGPoint(x: frame.minX, y: frame.midY + lift * 0.3))
            arc.addQuadCurve(
                to: CGPoint(x: frame.maxX, y: frame.midY + lift * 0.3),
                control: CGPoint(x: frame.midX, y: frame.midY - lift * 1.5)
            )
        }
        context.stroke(arc, with: .color(ink), lineWidth: max(1, unit * 0.05))
    }

    /// Two soft patches on the cheeks, drawn under the eyes and outside them.
    private static func drawBlush(
        in context: inout GraphicsContext,
        place: (CGFloat, CGFloat) -> CGPoint,
        anchorHeight: CGFloat,
        radius: CGFloat,
        spread: CGFloat,
        unit: CGFloat,
        amount: CGFloat
    ) {
        let strength = min(max(amount, 0), 1)
        for side: CGFloat in [-1, 1] {
            let centre = place(side * (spread * 0.62 + radius * 0.9), -anchorHeight + radius * 1.25)
            let width = radius * 1.5
            let height = radius * 0.78
            context.fill(
                Path(ellipseIn: CGRect(
                    x: centre.x - width / 2,
                    y: centre.y - height / 2,
                    width: width,
                    height: height
                )),
                with: .radialGradient(
                    Gradient(colors: [Theme.danger.opacity(0.42 * strength), Theme.danger.opacity(0)]),
                    center: centre,
                    startRadius: 0,
                    endRadius: width * 0.62
                )
            )
        }
    }

    private static func drawBrow(
        in context: inout GraphicsContext,
        over centre: CGPoint,
        radius: CGFloat,
        unit: CGFloat,
        ink: Color,
        amount: CGFloat,
        side: CGFloat
    ) {
        // The inner end drops for strain and rises for surprise. Which end is
        // inner depends on which eye this is, so one number does both brows.
        let inner: CGFloat = side <= 0 ? 1 : -1
        let width = radius * 1.5
        let lift = radius * (1.55 + max(0, -amount) * 0.5)
        let drop = radius * amount * 0.55
        var path = Path()
        let a = CGPoint(x: centre.x - width / 2 * inner, y: centre.y - lift + drop)
        let b = CGPoint(x: centre.x + width / 2 * inner, y: centre.y - lift - drop * 0.4)
        path.move(to: a)
        path.addQuadCurve(
            to: b,
            control: CGPoint(x: (a.x + b.x) / 2, y: (a.y + b.y) / 2 - radius * 0.18)
        )
        context.stroke(path, with: .color(ink.opacity(0.72)), lineWidth: max(1, unit * 0.036))
    }

    private static func drawMouth(
        in context: inout GraphicsContext,
        place: (CGFloat, CGFloat) -> CGPoint,
        anchorHeight: CGFloat,
        radius: CGFloat,
        unit: CGFloat,
        ink: Color,
        face: PersonaFacePose,
        traits: PersonaTraits
    ) {
        // A mouth is one closed path with two curved edges: the top edge
        // carries the smile, the gap between the edges carries the speech.
        // Interpolating those two numbers covers a line, a grin, a frown and
        // an open vowel without a case for each.
        // The persona's own mouth is a bias on the mood's, not a replacement
        // for it: a naturally glum character still smiles when it wins, it
        // just does not smile as widely as a naturally cheerful one.
        let resting: CGFloat = switch traits.mouth {
        case .smile: 0.34
        case .frown: -0.34
        case .flat: -0.10
        case .dot, .none: 0
        }
        let curve = min(max(face.mouthCurve + resting, -1.1), 1.1)
        // An open mouth widens as it opens. Without it a loud syllable is a
        // tall narrow wedge rather than a vowel.
        let half = unit * 0.078 * face.mouthWidth * traits.mouthWidth
            * (1 + min(max(face.mouthOpen, 0), 1.2) * 0.22)
        let open = max(0, face.mouthOpen) * unit * 0.140
        let baseY = -anchorHeight + radius * 2.15

        let left = place(-half, baseY)
        let right = place(half, baseY)
        // A quadratic reaches half its control offset, so the gap between the
        // two edges is half of `open`. Doubled here rather than in the moods,
        // where "one" should mean a wide open mouth and not half of one.
        let bow = place(0, baseY + curve * unit * 0.142)
        let sag = place(0, baseY + curve * unit * 0.142 + open * 2)

        if open < unit * 0.006 {
            var path = Path()
            path.move(to: left)
            path.addQuadCurve(to: right, control: bow)
            context.stroke(path, with: .color(ink.opacity(0.78)), lineWidth: max(1, unit * 0.038))
            return
        }

        var path = Path()
        path.move(to: left)
        path.addQuadCurve(to: right, control: bow)
        path.addQuadCurve(to: left, control: sag)
        path.closeSubpath()
        context.fill(path, with: .color(ink.opacity(0.72)))

        guard face.tongue > 0.02 else { return }
        // Clipped to the mouth, so a tongue never escapes the face however
        // wide the mood asked for it. It hangs from the lower edge, which is
        // where the bottom curve already is.
        context.drawLayer { inner in
            inner.clip(to: path)
            let reach = min(max(face.tongue, 0), 1)
            let tip = place(0, baseY + curve * unit * 0.142 + open * 2 * (1 - reach * 0.55))
            let width = half * 0.86
            inner.fill(
                Path(ellipseIn: CGRect(
                    x: tip.x - width / 2,
                    y: tip.y - open * 0.60,
                    width: width,
                    height: open * 1.5 + unit * 0.02
                )),
                with: .color(Theme.danger.opacity(0.62))
            )
        }
    }

    // MARK: - What is in the air

    private static func drawMotes(
        _ engine: PersonaEngine,
        in context: inout GraphicsContext,
        rect: CGRect,
        unit: CGFloat,
        hue: Color,
        ink: Color
    ) {
        for mote in engine.motes where mote.kind != .glow {
            let point = CGPoint(
                x: rect.minX + mote.position.x * rect.width,
                y: rect.minY + mote.position.y * rect.height
            )
            switch mote.kind {
            case .dot:
                let size = unit * 0.052 * mote.scale
                context.fill(
                    Path(ellipseIn: CGRect(x: point.x - size, y: point.y - size, width: size * 2, height: size * 2)),
                    with: .color(hue.opacity(mote.opacity * 0.85))
                )

            case .ball:
                let size = unit * 0.062
                let frame = CGRect(x: point.x - size, y: point.y - size, width: size * 2, height: size * 2)
                context.fill(Path(ellipseIn: frame), with: .color(Theme.secondary.opacity(mote.opacity)))
                context.fill(
                    Path(ellipseIn: CGRect(
                        x: frame.minX + size * 0.35,
                        y: frame.minY + size * 0.30,
                        width: size * 0.7,
                        height: size * 0.6
                    )),
                    with: .color(.white.opacity(0.5 * mote.opacity))
                )

            case .spark:
                let reach = unit * 0.062 * mote.scale
                var path = Path()
                for step in 0..<2 {
                    let angle = mote.angle + CGFloat(step) * .pi / 2
                    path.move(to: CGPoint(x: point.x - cos(angle) * reach, y: point.y - sin(angle) * reach))
                    path.addLine(to: CGPoint(x: point.x + cos(angle) * reach, y: point.y + sin(angle) * reach))
                }
                context.stroke(
                    path,
                    with: .color(hue.opacity(mote.opacity)),
                    style: StrokeStyle(lineWidth: max(1, unit * 0.032), lineCap: .round)
                )

            case .note:
                let size = unit * 0.055 * mote.scale
                let head = CGRect(x: point.x - size, y: point.y - size * 0.72, width: size * 1.7, height: size * 1.3)
                context.fill(Path(ellipseIn: head), with: .color(hue.opacity(mote.opacity)))
                var stem = Path()
                stem.move(to: CGPoint(x: head.maxX - size * 0.12, y: head.midY))
                stem.addLine(to: CGPoint(x: head.maxX - size * 0.12, y: head.minY - size * 1.5))
                stem.addQuadCurve(
                    to: CGPoint(x: head.maxX + size * 0.75, y: head.minY - size * 0.55),
                    control: CGPoint(x: head.maxX + size * 0.85, y: head.minY - size * 1.5)
                )
                context.stroke(
                    stem,
                    with: .color(hue.opacity(mote.opacity)),
                    style: StrokeStyle(lineWidth: max(1, unit * 0.030), lineCap: .round)
                )

            case .zed:
                let size = unit * 0.062 * mote.scale
                var path = Path()
                path.move(to: CGPoint(x: point.x - size * 0.5, y: point.y - size * 0.5))
                path.addLine(to: CGPoint(x: point.x + size * 0.5, y: point.y - size * 0.5))
                path.addLine(to: CGPoint(x: point.x - size * 0.5, y: point.y + size * 0.5))
                path.addLine(to: CGPoint(x: point.x + size * 0.5, y: point.y + size * 0.5))
                context.stroke(
                    path,
                    with: .color(hue.opacity(mote.opacity * 0.9)),
                    style: StrokeStyle(lineWidth: max(1, unit * 0.030), lineCap: .round, lineJoin: .round)
                )

            case .drop:
                let size = unit * 0.045 * mote.scale
                var path = Path()
                path.move(to: CGPoint(x: point.x, y: point.y - size * 1.6))
                path.addQuadCurve(
                    to: CGPoint(x: point.x + size, y: point.y + size * 0.2),
                    control: CGPoint(x: point.x + size * 0.75, y: point.y - size * 0.6)
                )
                path.addArc(
                    center: CGPoint(x: point.x, y: point.y + size * 0.2),
                    radius: size,
                    startAngle: .zero,
                    endAngle: .radians(.pi),
                    clockwise: false
                )
                path.addQuadCurve(
                    to: CGPoint(x: point.x, y: point.y - size * 1.6),
                    control: CGPoint(x: point.x - size * 0.75, y: point.y - size * 0.6)
                )
                context.fill(path, with: .color(ink.opacity(mote.opacity * 0.85)))

            case .puff:
                let size = unit * 0.055 * mote.scale
                context.fill(
                    Path(ellipseIn: CGRect(
                        x: point.x - size,
                        y: point.y - size * 0.55,
                        width: size * 2,
                        height: size * 1.1
                    )),
                    with: .color(hue.opacity(mote.opacity))
                )

            case .paper:
                drawPaper(
                    in: &context,
                    at: point,
                    unit: unit,
                    tilt: mote.angle,
                    scale: mote.scale,
                    hue: hue
                )

            case .console:
                drawConsole(in: &context, at: point, unit: unit, tilt: mote.angle, hue: hue)

            case .keyboard:
                drawKeyboard(in: &context, at: point, unit: unit, hue: hue, opacity: mote.opacity)

            case .sheet:
                drawSheet(in: &context, at: point, unit: unit, scale: mote.scale, hue: hue, opacity: mote.opacity)

            case .mug:
                drawMug(in: &context, at: point, unit: unit, tilt: mote.angle, hue: hue, opacity: mote.opacity)

            case .sprout:
                drawSprout(in: &context, at: point, unit: unit, scale: mote.scale, hue: hue, opacity: mote.opacity)

            case .hammer:
                drawHammer(in: &context, at: point, unit: unit, tilt: mote.angle, hue: hue, opacity: mote.opacity)

            case .nail:
                drawNail(in: &context, at: point, unit: unit, showing: mote.scale, hue: hue, opacity: mote.opacity)

            case .brush:
                drawPaintBrush(in: &context, at: point, unit: unit, tilt: mote.angle, hue: hue, opacity: mote.opacity)

            case .flower:
                drawFlower(in: &context, at: point, unit: unit, scale: mote.scale, hue: hue, opacity: mote.opacity)

            case .mark:
                drawMark(in: &context, at: point, unit: unit, scale: mote.scale, question: mote.angle != 0, ink: ink, opacity: mote.opacity)

            case .sweat:
                drawSweat(in: &context, at: point, unit: unit, scale: mote.scale, tilt: mote.angle, opacity: mote.opacity)

            case .heart:
                drawHeart(in: &context, at: point, unit: unit, scale: mote.scale, tilt: mote.angle, opacity: mote.opacity)

            case .shootingStar:
                drawShootingStar(in: &context, at: point, unit: unit, scale: mote.scale, tilt: mote.angle, opacity: mote.opacity)

            case .confetti:
                drawConfetti(in: &context, at: point, unit: unit, scale: mote.scale, tilt: mote.angle, hue: hue, opacity: mote.opacity)

            case .stroke:
                drawStroke(in: &context, at: point, unit: unit, scale: mote.scale, tilt: mote.angle, hue: hue, opacity: mote.opacity)

            case .bubble:
                drawBubble(in: &context, at: point, unit: unit, scale: mote.scale, hue: hue, opacity: mote.opacity)

            case .cookie:
                drawCookie(in: &context, at: point, unit: unit, scale: mote.scale, tilt: mote.angle, hue: hue, opacity: mote.opacity)

            case .glow:
                break
            }
        }
    }
}

// MARK: - Held things

/// The newspaper, from our side of it.
///
/// We are looking at the back. The print faces the character, which is the
/// only arrangement that makes sense and also the one everybody draws: a wide
/// blank sheet held up, a fold down the middle, and two eyes over the top
/// edge. Column rules on our side would mean he was reading it backwards.
///
/// It is held and it drifts, and that is all it does. Reading is somebody
/// absorbed and barely moving, so the sheet has no events on it.
private func drawPaper(
    in context: inout GraphicsContext,
    at point: CGPoint,
    unit: CGFloat,
    tilt: CGFloat,
    scale: CGFloat,
    hue: Color
) {
    let width = unit * 0.58 * scale
    let height = unit * 0.32 * scale
    let frame = CGRect(x: point.x - width / 2, y: point.y - height / 2, width: width, height: height)
    context.drawLayer { layer in
        layer.translateBy(x: frame.midX, y: frame.midY)
        layer.rotate(by: .radians(tilt))
        layer.translateBy(x: -frame.midX, y: -frame.midY)

        // The top edge dips at the fold and lifts at the corners, because a
        // sheet held at two points hangs, and a straight edge reads as card.
        var sheet = Path()
        sheet.move(to: CGPoint(x: frame.minX, y: frame.minY + height * 0.06))
        sheet.addQuadCurve(
            to: CGPoint(x: frame.midX, y: frame.minY + height * 0.16),
            control: CGPoint(x: frame.minX + width * 0.26, y: frame.minY)
        )
        sheet.addQuadCurve(
            to: CGPoint(x: frame.maxX, y: frame.minY + height * 0.06),
            control: CGPoint(x: frame.maxX - width * 0.26, y: frame.minY)
        )
        sheet.addLine(to: CGPoint(x: frame.maxX - width * 0.03, y: frame.maxY))
        sheet.addQuadCurve(
            to: CGPoint(x: frame.midX, y: frame.maxY - height * 0.05),
            control: CGPoint(x: frame.midX + width * 0.24, y: frame.maxY + height * 0.03)
        )
        sheet.addQuadCurve(
            to: CGPoint(x: frame.minX + width * 0.03, y: frame.maxY),
            control: CGPoint(x: frame.midX - width * 0.24, y: frame.maxY + height * 0.03)
        )
        sheet.closeSubpath()
        layer.fill(sheet, with: .color(.white.opacity(0.90)))

        // Everything that happens on the paper happens inside the paper.
        layer.drawLayer { inked in
            inked.clip(to: sheet)

            // The fold: what turns two flat halves into one sheet with a
            // crease in it.
            var fold = Path()
            fold.move(to: CGPoint(x: frame.midX, y: frame.minY + height * 0.16))
            fold.addQuadCurve(
                to: CGPoint(x: frame.midX, y: frame.maxY - height * 0.05),
                control: CGPoint(x: frame.midX - width * 0.02, y: frame.midY)
            )
            inked.stroke(fold, with: .color(hue.opacity(0.35)), lineWidth: max(1, unit * 0.016))

            guard unit >= 44 else { return }
            // The print, showing faintly through the paper. Enough to say
            // there is something on the other side, not enough to read.
            var bleed = Path()
            for line in 0..<4 {
                let y = frame.minY + height * (0.34 + CGFloat(line) * 0.16)
                bleed.move(to: CGPoint(x: frame.minX + width * 0.09, y: y))
                bleed.addLine(to: CGPoint(x: frame.midX - width * 0.06, y: y))
                bleed.move(to: CGPoint(x: frame.midX + width * 0.06, y: y))
                bleed.addLine(to: CGPoint(x: frame.maxX - width * 0.09, y: y))
            }
            inked.stroke(
                bleed,
                with: .color(hue.opacity(0.13)),
                lineWidth: max(0.5, unit * 0.011)
            )
        }

        // The outline last, so nothing drawn on the sheet can sit on top of
        // its own edge.
        layer.stroke(sheet, with: .color(hue.opacity(0.95)), lineWidth: max(1, unit * 0.024))
    }
}

/// The light a screen throws back at whoever is looking into it.
///
/// This is how the game is shown. The screen faces the character, so the only
/// honest way to put it on our side of the picture is the glow on his face.
private func drawGlow(
    in context: inout GraphicsContext,
    mote: PersonaMote,
    rect: CGRect,
    unit: CGFloat,
    hue: Color
) {
    let centre = CGPoint(
        x: rect.minX + mote.position.x * rect.width,
        y: rect.minY + mote.position.y * rect.height
    )
    let reach = unit * 0.42 * mote.scale
    context.fill(
        Path(ellipseIn: CGRect(
            x: centre.x - reach,
            y: centre.y - reach,
            width: reach * 2,
            height: reach * 2
        )),
        with: .radialGradient(
            Gradient(colors: [.white.opacity(0.42 * mote.opacity), .white.opacity(0)]),
            center: centre,
            startRadius: 0,
            endRadius: reach
        )
    )
}

/// The back of something handheld.
///
/// No screen and no buttons on this side: they face the character. What we
/// get is the shape, the tilt, and the fact that it never stops moving, which
/// is what somebody playing actually looks like from across a room.
private func drawConsole(
    in context: inout GraphicsContext,
    at point: CGPoint,
    unit: CGFloat,
    tilt: CGFloat,
    hue: Color
) {
    let width = unit * 0.34
    let height = unit * 0.20
    let frame = CGRect(x: point.x - width / 2, y: point.y - height / 2, width: width, height: height)
    context.drawLayer { layer in
        layer.translateBy(x: frame.midX, y: frame.midY)
        layer.rotate(by: .radians(tilt))
        layer.translateBy(x: -frame.midX, y: -frame.midY)

        let shell = Path(roundedRect: frame, cornerRadius: height * 0.36, style: .continuous)
        layer.fill(
            shell,
            with: .linearGradient(
                Gradient(colors: [hue.opacity(0.95), hue.opacity(0.72)]),
                startPoint: CGPoint(x: frame.midX, y: frame.minY),
                endPoint: CGPoint(x: frame.midX, y: frame.maxY)
            )
        )
        layer.stroke(shell, with: .color(.white.opacity(0.30)), lineWidth: max(1, unit * 0.014))

        guard unit >= 44 else { return }
        // One moulding line across the back. It is what stops a rounded
        // rectangle reading as a card, and it is all the detail this side has.
        var seam = Path()
        seam.move(to: CGPoint(x: frame.minX + width * 0.16, y: frame.midY + height * 0.16))
        seam.addLine(to: CGPoint(x: frame.maxX - width * 0.16, y: frame.midY + height * 0.16))
        layer.stroke(
            seam,
            with: .color(.white.opacity(0.22)),
            style: StrokeStyle(lineWidth: max(0.5, unit * 0.012), lineCap: .round)
        )
    }
}

/// A keyboard lying on the floor, seen from slightly above and in front.
///
/// `point` is the middle of its front edge, and that edge sits exactly on the
/// floor line. It was drawn as a flat rounded rectangle centred on its point,
/// which is a keyboard photographed from directly overhead and pasted into a
/// side view: it hung in the air with nothing holding it up. A near edge, a
/// narrower far edge and a front lip is the whole trick.
private func drawKeyboard(
    in context: inout GraphicsContext,
    at point: CGPoint,
    unit: CGFloat,
    hue: Color,
    opacity: CGFloat
) {
    let front = unit * 0.46
    let back = unit * 0.37
    let depth = unit * 0.085
    let thickness = unit * 0.030
    let topY = point.y - thickness
    let backY = topY - depth

    // The lip. It is the only part with any height, and it is what says the
    // thing is resting on something rather than floating over it.
    var lip = Path()
    lip.move(to: CGPoint(x: point.x - front / 2, y: topY))
    lip.addLine(to: CGPoint(x: point.x + front / 2, y: topY))
    lip.addLine(to: CGPoint(x: point.x + front / 2 - unit * 0.008, y: point.y))
    lip.addLine(to: CGPoint(x: point.x - front / 2 + unit * 0.008, y: point.y))
    lip.closeSubpath()
    context.fill(lip, with: .color(hue.opacity(0.34 * opacity)))

    var top = Path()
    top.move(to: CGPoint(x: point.x - front / 2, y: topY))
    top.addLine(to: CGPoint(x: point.x - back / 2, y: backY))
    top.addLine(to: CGPoint(x: point.x + back / 2, y: backY))
    top.addLine(to: CGPoint(x: point.x + front / 2, y: topY))
    top.closeSubpath()
    context.fill(top, with: .color(hue.opacity(0.18 * opacity)))
    context.stroke(top, with: .color(hue.opacity(0.85 * opacity)), lineWidth: max(1, unit * 0.016))
    context.stroke(lip, with: .color(hue.opacity(0.85 * opacity)), lineWidth: max(1, unit * 0.016))

    guard unit >= 32 else { return }
    // Three rows, each narrower and shorter than the one in front of it,
    // because that is what rows going away from you do.
    for row in 0..<3 {
        let along = CGFloat(row) / 3
        let rowWidth = front + (back - front) * along
        let rowY = topY + (backY - topY) * (along + 0.14)
        let keyWidth = rowWidth * 0.115
        let keyHeight = depth * (0.22 - along * 0.04)
        for column in 0..<6 {
            let x = point.x - rowWidth / 2 + rowWidth * 0.075
                + CGFloat(column) * rowWidth * 0.17
                + (row == 1 ? rowWidth * 0.03 : 0)
            let key = Path(roundedRect: CGRect(x: x, y: rowY, width: keyWidth, height: keyHeight), cornerRadius: keyHeight * 0.34)
            context.fill(key, with: .color(hue.opacity((column + row * 2).isMultiple(of: 5) ? 0.62 * opacity : 0.30 * opacity)))
        }
    }
}

/// A sheet of paper lying on the floor, in the same shallow perspective as the
/// keyboard: near edge wide and on the floor line, far edge narrower.
private func drawSheet(
    in context: inout GraphicsContext,
    at point: CGPoint,
    unit: CGFloat,
    scale: CGFloat,
    hue: Color,
    opacity: CGFloat
) {
    let front = unit * 0.44 * scale
    let back = unit * 0.34 * scale
    let depth = unit * 0.11 * scale
    var sheet = Path()
    sheet.move(to: CGPoint(x: point.x - front / 2, y: point.y))
    sheet.addLine(to: CGPoint(x: point.x - back / 2, y: point.y - depth))
    sheet.addLine(to: CGPoint(x: point.x + back / 2, y: point.y - depth))
    sheet.addLine(to: CGPoint(x: point.x + front / 2, y: point.y))
    sheet.closeSubpath()
    context.fill(sheet, with: .color(.white.opacity(0.82 * opacity)))
    context.stroke(sheet, with: .color(hue.opacity(0.55 * opacity)), lineWidth: max(1, unit * 0.014))
}

private func drawMug(
    in context: inout GraphicsContext,
    at point: CGPoint,
    unit: CGFloat,
    tilt: CGFloat,
    hue: Color,
    opacity: CGFloat
) {
    let width = unit * 0.20
    let height = unit * 0.23
    let frame = CGRect(x: point.x - width / 2, y: point.y - height / 2, width: width, height: height)
    context.drawLayer { layer in
        layer.translateBy(x: frame.midX, y: frame.midY)
        layer.rotate(by: .radians(tilt))
        layer.translateBy(x: -frame.midX, y: -frame.midY)
        let cup = Path(roundedRect: frame, cornerRadius: width * 0.22, style: .continuous)
        layer.fill(cup, with: .color(hue.opacity(0.82 * opacity)))
        layer.stroke(cup, with: .color(.white.opacity(0.38 * opacity)), lineWidth: max(1, unit * 0.016))
        let handle = Path(ellipseIn: CGRect(x: frame.maxX - width * 0.05, y: frame.minY + height * 0.25, width: width * 0.55, height: height * 0.46))
        layer.stroke(handle, with: .color(hue.opacity(opacity)), lineWidth: max(1, unit * 0.036))
    }
}

private func drawSprout(
    in context: inout GraphicsContext,
    at point: CGPoint,
    unit: CGFloat,
    scale: CGFloat,
    hue: Color,
    opacity: CGFloat
) {
    let reach = unit * 0.13 * scale
    // A little mound of soil first. Without it a stem meeting the floor line
    // reads as a plant stuck onto the picture rather than growing out of it.
    drawSoil(in: &context, at: point, unit: unit, width: reach * 1.5, opacity: opacity)
    var stem = Path()
    stem.move(to: point)
    stem.addQuadCurve(to: CGPoint(x: point.x + reach * 0.08, y: point.y - reach * 1.45), control: CGPoint(x: point.x - reach * 0.12, y: point.y - reach * 0.72))
    context.stroke(stem, with: .color(hue.opacity(opacity)), style: StrokeStyle(lineWidth: max(1, unit * 0.022), lineCap: .round))
    for side: CGFloat in [-1, 1] {
        let leaf = CGRect(
            x: point.x + side * reach * 0.34 - reach * 0.44,
            y: point.y - reach * (side < 0 ? 1.42 : 1.72),
            width: reach * 0.88,
            height: reach * 0.48
        )
        context.fill(Path(ellipseIn: leaf), with: .color(hue.opacity(0.72 * opacity)))
    }
}

/// A brush, held handle-up with the bristles down on the paper.
///
/// Drawn along +x, so the caller's angle points the working end. The bristles
/// are a splayed bundle of separate tapered hairs rather than one rounded
/// blob: a blob at this size reads as a rubber tip, and the whole point of a
/// brush is that the end of it is soft and comes apart.
private func drawPaintBrush(
    in context: inout GraphicsContext,
    at point: CGPoint,
    unit: CGFloat,
    tilt: CGFloat,
    hue: Color,
    opacity: CGFloat
) {
    let handle = unit * 0.30
    let width = unit * 0.044
    context.drawLayer { layer in
        layer.translateBy(x: point.x, y: point.y)
        layer.rotate(by: .radians(tilt))

        // A tapered handle: thick where it is held, thinner at the ferrule.
        var shaft = Path()
        shaft.move(to: CGPoint(x: -handle * 0.58, y: -width * 0.42))
        shaft.addLine(to: CGPoint(x: handle * 0.24, y: -width * 0.26))
        shaft.addLine(to: CGPoint(x: handle * 0.24, y: width * 0.26))
        shaft.addLine(to: CGPoint(x: -handle * 0.58, y: width * 0.42))
        shaft.closeSubpath()
        layer.fill(shaft, with: .color(hue.opacity(0.95 * opacity)))

        let ferrule = Path(roundedRect: CGRect(
            x: handle * 0.22,
            y: -width * 0.42,
            width: handle * 0.14,
            height: width * 0.84
        ), cornerRadius: width * 0.16)
        layer.fill(ferrule, with: .color(.white.opacity(0.62 * opacity)))

        // Five hairs, splayed and bent. They fan wider than the ferrule and
        // each comes to a point, which is what makes the end look loaded and
        // soft rather than moulded.
        let root = handle * 0.34
        let tip = handle * 0.62
        for index in 0..<5 {
            let spread = (CGFloat(index) - 2) / 2
            let start = spread * width * 0.30
            let end = spread * width * 1.10
            var hair = Path()
            hair.move(to: CGPoint(x: root, y: start - width * 0.12))
            hair.addQuadCurve(
                to: CGPoint(x: tip, y: end),
                control: CGPoint(x: (root + tip) * 0.5, y: start + (end - start) * 0.2)
            )
            hair.addQuadCurve(
                to: CGPoint(x: root, y: start + width * 0.12),
                control: CGPoint(x: (root + tip) * 0.5, y: start + (end - start) * 0.8)
            )
            hair.closeSubpath()
            layer.fill(hair, with: .color(Theme.secondary.opacity((0.92 - abs(spread) * 0.18) * opacity)))
        }
    }
}

private func clamp(_ value: CGFloat, _ lower: CGFloat, _ upper: CGFloat) -> CGFloat {
    min(upper, max(lower, value))
}

// MARK: - The small props

/// What the sprout becomes. Five petals and a middle, because four reads as a
/// propeller and six reads as a snowflake.
private func drawFlower(
    in context: inout GraphicsContext,
    at point: CGPoint,
    unit: CGFloat,
    scale: CGFloat,
    hue: Color,
    opacity: CGFloat
) {
    let reach = unit * 0.105 * scale
    // The same patch of soil the sprout came out of, and the stalk it kept.
    let root = CGPoint(x: point.x, y: point.y + reach * 1.9)
    drawSoil(in: &context, at: root, unit: unit, width: reach * 1.5, opacity: opacity)
    var stalk = Path()
    stalk.move(to: root)
    stalk.addQuadCurve(to: point, control: CGPoint(x: point.x - reach * 0.30, y: point.y + reach))
    context.stroke(
        stalk,
        with: .color(hue.opacity(0.85 * opacity)),
        style: StrokeStyle(lineWidth: max(1, unit * 0.022), lineCap: .round)
    )
    for step in 0..<5 {
        let angle = -CGFloat.pi / 2 + CGFloat(step) * 2 * .pi / 5
        let centre = CGPoint(x: point.x + cos(angle) * reach * 0.72, y: point.y + sin(angle) * reach * 0.72)
        context.fill(
            Path(ellipseIn: CGRect(
                x: centre.x - reach * 0.52,
                y: centre.y - reach * 0.52,
                width: reach * 1.04,
                height: reach * 1.04
            )),
            with: .color(Theme.secondary.opacity(0.88 * opacity))
        )
    }
    context.fill(
        Path(ellipseIn: CGRect(x: point.x - reach * 0.34, y: point.y - reach * 0.34, width: reach * 0.68, height: reach * 0.68)),
        with: .color(Theme.warning.opacity(opacity))
    )
}

/// One piece of punctuation, floating. The only text this cast is allowed.
private func drawMark(
    in context: inout GraphicsContext,
    at point: CGPoint,
    unit: CGFloat,
    scale: CGFloat,
    question: Bool,
    ink: Color,
    opacity: CGFloat
) {
    let height = unit * 0.20 * scale
    let width = max(1.5, unit * 0.045 * scale)
    if question {
        var hook = Path()
        hook.move(to: CGPoint(x: point.x - height * 0.24, y: point.y - height * 0.40))
        hook.addQuadCurve(
            to: CGPoint(x: point.x, y: point.y + height * 0.10),
            control: CGPoint(x: point.x + height * 0.42, y: point.y - height * 0.46)
        )
        context.stroke(hook, with: .color(ink.opacity(opacity)), style: StrokeStyle(lineWidth: width, lineCap: .round))
    } else {
        var stem = Path()
        stem.move(to: CGPoint(x: point.x, y: point.y - height * 0.50))
        stem.addLine(to: CGPoint(x: point.x, y: point.y + height * 0.10))
        context.stroke(stem, with: .color(ink.opacity(opacity)), style: StrokeStyle(lineWidth: width, lineCap: .round))
    }
    context.fill(
        Path(ellipseIn: CGRect(x: point.x - width * 0.6, y: point.y + height * 0.28, width: width * 1.2, height: width * 1.2)),
        with: .color(ink.opacity(opacity))
    )
}

/// The bead of sweat. It flies off the head rather than running down it, which
/// is the cartoon version and the one that reads at this size.
private func drawSweat(
    in context: inout GraphicsContext,
    at point: CGPoint,
    unit: CGFloat,
    scale: CGFloat,
    tilt: CGFloat,
    opacity: CGFloat
) {
    let size = unit * 0.048 * scale
    context.drawLayer { layer in
        layer.translateBy(x: point.x, y: point.y)
        layer.rotate(by: .radians(tilt))
        var drop = Path()
        drop.move(to: CGPoint(x: 0, y: -size * 1.5))
        drop.addQuadCurve(to: CGPoint(x: size, y: size * 0.2), control: CGPoint(x: size * 0.8, y: -size * 0.5))
        drop.addArc(center: CGPoint(x: 0, y: size * 0.2), radius: size, startAngle: .zero, endAngle: .radians(.pi), clockwise: false)
        drop.addQuadCurve(to: CGPoint(x: 0, y: -size * 1.5), control: CGPoint(x: -size * 0.8, y: -size * 0.5))
        layer.fill(drop, with: .color(Theme.secondary.opacity(0.80 * opacity)))
        layer.fill(
            Path(ellipseIn: CGRect(x: -size * 0.55, y: -size * 0.30, width: size * 0.45, height: size * 0.55)),
            with: .color(.white.opacity(0.55 * opacity))
        )
    }
}

private func drawHeart(
    in context: inout GraphicsContext,
    at point: CGPoint,
    unit: CGFloat,
    scale: CGFloat,
    tilt: CGFloat,
    opacity: CGFloat
) {
    let size = unit * 0.060 * scale
    context.drawLayer { layer in
        layer.translateBy(x: point.x, y: point.y)
        layer.rotate(by: .radians(tilt))
        var heart = Path()
        heart.move(to: CGPoint(x: 0, y: size * 0.95))
        heart.addCurve(
            to: CGPoint(x: -size, y: -size * 0.30),
            control1: CGPoint(x: -size * 0.62, y: size * 0.42),
            control2: CGPoint(x: -size, y: size * 0.16)
        )
        heart.addArc(
            center: CGPoint(x: -size * 0.50, y: -size * 0.34),
            radius: size * 0.52,
            startAngle: .radians(.pi),
            endAngle: .zero,
            clockwise: false
        )
        heart.addArc(
            center: CGPoint(x: size * 0.50, y: -size * 0.34),
            radius: size * 0.52,
            startAngle: .radians(.pi),
            endAngle: .zero,
            clockwise: false
        )
        heart.addCurve(
            to: CGPoint(x: 0, y: size * 0.95),
            control1: CGPoint(x: size, y: size * 0.16),
            control2: CGPoint(x: size * 0.62, y: size * 0.42)
        )
        heart.closeSubpath()
        layer.fill(heart, with: .color(Theme.danger.opacity(0.80 * opacity)))
    }
}

/// A star with a tail behind it. `tilt` is the direction it is travelling, so
/// the tail always trails rather than pointing wherever it was drawn.
private func drawShootingStar(
    in context: inout GraphicsContext,
    at point: CGPoint,
    unit: CGFloat,
    scale: CGFloat,
    tilt: CGFloat,
    opacity: CGFloat
) {
    let reach = unit * 0.040 * scale
    var tail = Path()
    tail.move(to: point)
    tail.addLine(to: CGPoint(x: point.x - cos(tilt) * reach * 7, y: point.y - sin(tilt) * reach * 7))
    context.stroke(
        tail,
        with: .linearGradient(
            Gradient(colors: [Theme.warning.opacity(0.85 * opacity), Theme.warning.opacity(0)]),
            startPoint: point,
            endPoint: CGPoint(x: point.x - cos(tilt) * reach * 7, y: point.y - sin(tilt) * reach * 7)
        ),
        style: StrokeStyle(lineWidth: max(1, reach * 0.75), lineCap: .round)
    )
    var star = Path()
    for step in 0..<8 {
        let angle = CGFloat(step) * .pi / 4
        let out = step.isMultiple(of: 2) ? reach * 1.5 : reach * 0.5
        let corner = CGPoint(x: point.x + cos(angle) * out, y: point.y + sin(angle) * out)
        if step == 0 { star.move(to: corner) } else { star.addLine(to: corner) }
    }
    star.closeSubpath()
    context.fill(star, with: .color(Theme.warning.opacity(opacity)))
}

/// One scrap, tumbling. Colour comes off the brand arc rather than the party
/// shop, so a celebration still looks like this app celebrating.
private func drawConfetti(
    in context: inout GraphicsContext,
    at point: CGPoint,
    unit: CGFloat,
    scale: CGFloat,
    tilt: CGFloat,
    hue: Color,
    opacity: CGFloat
) {
    let size = unit * 0.042 * scale
    let palette = [Theme.accent, Theme.secondary, Theme.warning, hue]
    let colour = palette[abs(Int(tilt * 7)) % palette.count]
    context.drawLayer { layer in
        layer.translateBy(x: point.x, y: point.y)
        layer.rotate(by: .radians(tilt))
        // Squashed by its own spin, so a flat scrap turns edge-on to us
        // halfway round instead of sliding sideways.
        layer.scaleBy(x: 1, y: max(0.15, abs(cos(tilt * 1.7))))
        layer.fill(
            Path(roundedRect: CGRect(x: -size * 0.5, y: -size * 0.85, width: size, height: size * 1.7), cornerRadius: size * 0.22),
            with: .color(colour.opacity(opacity))
        )
    }
}

/// A wet stroke of paint. Fat in the middle and tapered at both ends, because
/// that is what a brush pressed and lifted leaves behind.
private func drawStroke(
    in context: inout GraphicsContext,
    at point: CGPoint,
    unit: CGFloat,
    scale: CGFloat,
    tilt: CGFloat,
    hue: Color,
    opacity: CGFloat
) {
    let length = unit * 0.13 * scale
    let width = unit * 0.040 * scale
    context.drawLayer { layer in
        layer.translateBy(x: point.x, y: point.y)
        layer.rotate(by: .radians(tilt))
        var mark = Path()
        mark.move(to: CGPoint(x: -length, y: 0))
        mark.addQuadCurve(to: CGPoint(x: length, y: 0), control: CGPoint(x: 0, y: -width * 1.5))
        mark.addQuadCurve(to: CGPoint(x: -length, y: 0), control: CGPoint(x: 0, y: width * 1.5))
        mark.closeSubpath()
        layer.fill(mark, with: .color(Theme.secondary.opacity(0.85 * opacity)))
    }
}

/// A soap bubble: mostly nothing, with a rim and one highlight. It has to be
/// see-through or it is a ball, and a ball is a different mood entirely.
private func drawBubble(
    in context: inout GraphicsContext,
    at point: CGPoint,
    unit: CGFloat,
    scale: CGFloat,
    hue: Color,
    opacity: CGFloat
) {
    let reach = unit * 0.10 * scale
    let frame = CGRect(x: point.x - reach, y: point.y - reach, width: reach * 2, height: reach * 2)
    context.fill(
        Path(ellipseIn: frame),
        with: .radialGradient(
            Gradient(colors: [.white.opacity(0.02 * opacity), Theme.secondary.opacity(0.26 * opacity)]),
            center: point,
            startRadius: reach * 0.2,
            endRadius: reach
        )
    )
    context.stroke(Path(ellipseIn: frame), with: .color(.white.opacity(0.62 * opacity)), lineWidth: max(1, unit * 0.014))
    context.fill(
        Path(ellipseIn: CGRect(
            x: frame.minX + reach * 0.34,
            y: frame.minY + reach * 0.28,
            width: reach * 0.44,
            height: reach * 0.32
        )),
        with: .color(.white.opacity(0.72 * opacity))
    )
}

/// A biscuit, with bites taken out of it. `tilt` counts the bites, so the same
/// prop covers the whole snack from whole to nearly gone.
private func drawCookie(
    in context: inout GraphicsContext,
    at point: CGPoint,
    unit: CGFloat,
    scale: CGFloat,
    tilt: CGFloat,
    hue: Color,
    opacity: CGFloat
) {
    let reach = unit * 0.105 * scale
    let bites = max(0, min(3, Int(tilt)))
    var biscuit = Path(ellipseIn: CGRect(x: point.x - reach, y: point.y - reach, width: reach * 2, height: reach * 2))
    for bite in 0..<bites {
        let angle = -CGFloat.pi * 0.75 + CGFloat(bite) * 0.62
        let centre = CGPoint(x: point.x + cos(angle) * reach * 0.92, y: point.y + sin(angle) * reach * 0.92)
        biscuit = Path(
            biscuit.cgPath.subtracting(
                Path(ellipseIn: CGRect(x: centre.x - reach * 0.46, y: centre.y - reach * 0.46, width: reach * 0.92, height: reach * 0.92)).cgPath
            )
        )
    }
    // The persona's own colour, like every other prop it holds. It was the
    // warning amber, which in an app that uses that colour to mean "your turn"
    // made a snack look like a fault.
    context.fill(biscuit, with: .color(hue.opacity(0.62 * opacity)))
    context.stroke(biscuit, with: .color(hue.opacity(0.95 * opacity)), lineWidth: max(1, unit * 0.014))
    // The chips. Fixed offsets rather than random ones, so a biscuit does not
    // reshuffle itself every frame.
    for offset in [CGPoint(x: -0.34, y: 0.18), CGPoint(x: 0.22, y: 0.36), CGPoint(x: 0.05, y: -0.30)] {
        context.fill(
            Path(ellipseIn: CGRect(
                x: point.x + offset.x * reach - reach * 0.15,
                y: point.y + offset.y * reach - reach * 0.15,
                width: reach * 0.30,
                height: reach * 0.30
            )),
            with: .color(hue.opacity(0.95 * opacity))
        )
    }
}

/// The patch of ground a plant is in. Small, dark, and flat on the floor line,
/// which is all it takes for a stem to read as rooted rather than stuck on.
private func drawSoil(
    in context: inout GraphicsContext,
    at point: CGPoint,
    unit: CGFloat,
    width: CGFloat,
    opacity: CGFloat
) {
    var mound = Path()
    mound.move(to: CGPoint(x: point.x - width, y: point.y))
    mound.addQuadCurve(
        to: CGPoint(x: point.x + width, y: point.y),
        control: CGPoint(x: point.x, y: point.y - width * 0.62)
    )
    mound.closeSubpath()
    context.fill(mound, with: .color(.black.opacity(0.30 * opacity)))
}

/// The hammer, pivoting where the character holds it. `tilt` is the swing, so
/// the head is drawn at the far end of a handle that rotates around the grip.
private func drawHammer(
    in context: inout GraphicsContext,
    at point: CGPoint,
    unit: CGFloat,
    tilt: CGFloat,
    hue: Color,
    opacity: CGFloat
) {
    let handle = unit * 0.30
    context.drawLayer { layer in
        layer.translateBy(x: point.x, y: point.y)
        layer.rotate(by: .radians(tilt))
        var shaft = Path()
        shaft.move(to: .zero)
        shaft.addLine(to: CGPoint(x: handle, y: 0))
        layer.stroke(
            shaft,
            with: .color(hue.opacity(0.95 * opacity)),
            style: StrokeStyle(lineWidth: max(2, unit * 0.042), lineCap: .round)
        )
        // The head is deliberately heavy. A light one swings like a stick, and
        // the whole point of this mood is that the thing has weight.
        let head = CGRect(
            x: handle - unit * 0.030,
            y: -unit * 0.075,
            width: unit * 0.105,
            height: unit * 0.15
        )
        layer.fill(
            Path(roundedRect: head, cornerRadius: unit * 0.022, style: .continuous),
            with: .color(Theme.secondary.opacity(0.95 * opacity))
        )
        layer.fill(
            Path(roundedRect: CGRect(x: head.minX - unit * 0.045, y: head.midY - unit * 0.030, width: unit * 0.055, height: unit * 0.060), cornerRadius: unit * 0.014),
            with: .color(Theme.secondary.opacity(0.72 * opacity))
        )
    }
}

/// A nail in the floor, most of the way in by the end of a cycle. `showing` is
/// how much of the shank is still above the boards.
private func drawNail(
    in context: inout GraphicsContext,
    at point: CGPoint,
    unit: CGFloat,
    showing: CGFloat,
    hue: Color,
    opacity: CGFloat
) {
    let length = unit * 0.11 * max(showing, 0.10)
    var shank = Path()
    shank.move(to: point)
    shank.addLine(to: CGPoint(x: point.x, y: point.y - length))
    context.stroke(
        shank,
        with: .color(Theme.secondary.opacity(0.90 * opacity)),
        style: StrokeStyle(lineWidth: max(1.5, unit * 0.026), lineCap: .butt)
    )
    context.fill(
        Path(ellipseIn: CGRect(
            x: point.x - unit * 0.032,
            y: point.y - length - unit * 0.016,
            width: unit * 0.064,
            height: unit * 0.028
        )),
        with: .color(Theme.secondary.opacity(opacity))
    )
}
