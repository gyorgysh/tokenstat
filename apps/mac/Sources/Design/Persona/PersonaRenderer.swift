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
        let radius = unit * (count == 1 ? 0.115 : count == 2 ? 0.082 : 0.065) * lod
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
            if face.forceArcEyes {
                drawArcEye(in: &context, frame: frame, unit: unit, ink: ink, flipped: face.arcFlipped)
            } else {
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

private func clamp(_ value: CGFloat, _ lower: CGFloat, _ upper: CGFloat) -> CGFloat {
    min(upper, max(lower, value))
}
