// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
//
// Source-available: source sharing and own builds are permitted.
// Store and commercial distribution of builds is reserved. See LICENSE.
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
        let ink = traits.faceInk
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
                Gradient(colors: [traits.bodyHighlight, hue]),
                startPoint: CGPoint(x: rect.midX, y: top),
                endPoint: CGPoint(x: rect.midX, y: base)
            )
        )
        context.stroke(outline, with: .color(hue.opacity(0.65)), lineWidth: max(0.5, unit * 0.012))
        if let tint = engine.mood.tint {
            context.stroke(outline, with: .color(tint), lineWidth: max(1, unit * 0.020))
        }

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


    private static func drawShadow(
        in context: inout GraphicsContext,
        rect: CGRect,
        bounds: CGRect,
        unit: CGFloat,
        hue: Color
    ) {
        let air = max(0, PersonaStage.floor - bounds.maxY)
        let closeness = max(0.30, 1 - air * 2.6)
        let width = bounds.width * rect.width * 0.80 * closeness
        let height = unit * 0.052 * closeness
        let y = rect.minY + PersonaStage.floor * rect.height - height * 0.35
        context.fill(
            Path(ellipseIn: CGRect(x: rect.minX + bounds.midX * rect.width - width / 2, y: y, width: width, height: height)),
            with: .color(hue.opacity(0.20 * closeness))
        )
    }

    private static func drawHighlight(in context: inout GraphicsContext, rect: CGRect, bounds: CGRect) {
        let width = bounds.width * rect.width * 0.155
        let height = bounds.height * rect.height * 0.085
        let frame = CGRect(
            x: rect.minX + bounds.midX * rect.width - width * 1.55,
            y: rect.minY + (bounds.minY + bounds.height * 0.17) * rect.height,
            width: width,
            height: height
        )
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


    private static func drawFace(
        _ engine: PersonaEngine,
        in context: inout GraphicsContext,
        rect: CGRect,
        unit: CGFloat,
        ink: Color
    ) {
        var context = context
        let traits = engine.traits
        let face = engine.face
        let body = engine.body
        let bounds = body.bounds
        let centroid = body.centroid
        let crown = body.crown

        let aspect = clamp(bounds.height / max(bounds.width, 1e-4), 0.45, 1.7)

        let lean = clamp(atan2(crown.x - centroid.x, max(centroid.y - crown.y, 1e-4)) * 0.25, -0.12, 0.12)
        let tilt = lean + engine.headTilt

        let heightPoints = bounds.height * rect.height
        let anchorHeight = heightPoints * (0.05 + face.lift)
        let origin = CGPoint(
            x: rect.minX + centroid.x * rect.width,
            y: rect.minY + centroid.y * rect.height
        )

        let sphereX = max(1, bounds.width * rect.width * 0.5)
        let sphereY = max(1, heightPoints * 0.5)
        let gazeX = clamp(face.gaze.x + engine.look.x, -1.3, 1.3)
        let gazeY = clamp(face.gaze.y + engine.look.y, -1.3, 1.3)
        let turn = engine.yaw + gazeX * 0.30
        let nod = gazeY * 0.20
        func project(_ dx: CGFloat, _ dy: CGFloat) -> (point: CGPoint, width: CGFloat, height: CGFloat, facing: CGFloat) {
            let theta = asin(clamp(dx / sphereX, -0.98, 0.98)) + turn
            let phi = asin(clamp(dy / sphereY, -0.98, 0.98)) + nod
            return (CGPoint(x: sphereX * sin(theta), y: sphereY * sin(phi)), max(0, cos(theta)), max(0.2, cos(phi)), cos(theta))
        }
        func place(_ offset: CGPoint) -> CGPoint {
            CGPoint(
                x: origin.x + offset.x * cos(tilt) - offset.y * sin(tilt),
                y: origin.y + offset.x * sin(tilt) + offset.y * cos(tilt)
            )
        }
        func onFace(_ dx: CGFloat, _ dy: CGFloat) -> CGPoint { place(project(dx, dy).point) }

        context.translateBy(x: origin.x, y: origin.y)
        context.rotate(by: .radians(Double(engine.roll)))
        context.translateBy(x: -origin.x, y: -origin.y)

        let count = traits.eyeCount
        let lod: CGFloat = unit < 24 ? 1.28 : unit < 34 ? 1.12 : 1.0
        let radius = unit * 0.060 * lod * clamp(face.eyeScale, 0.8, 1.25)
        let spread = unit * 0.25 * clamp(face.spread, 0.85, 1.15) / max(sqrt(aspect), 0.6)
        let tall = clamp(sqrt(aspect), 0.75, 1.3)

        for index in 0..<count {
            let offset = CGFloat(index) - CGFloat(count - 1) / 2
            let side: CGFloat = offset < 0 ? -1 : 1
            let spot = project(offset * spread, -anchorHeight)
            guard spot.facing > 0.02 else { continue }
            let centre = place(spot.point)
            let winked = engine.winkSide == side ? engine.wink : 0
            drawEye(
                in: &context,
                centre: centre,
                radius: radius,
                width: spot.width,
                height: spot.height * tall,
                side: side,
                face: face,
                blink: winked > 0 ? max(winked, engine.blink) : engine.blink,
                cheer: max(face.cheer, winked),
                tilt: tilt,
                unit: unit,
                ink: ink,
                shape: traits.eyeShape,
                opacity: min(1, spot.facing * 4)
            )

            if unit >= 40, abs(face.brow) > 0.45 {
                drawBrow(
                    in: &context,
                    over: centre,
                    radius: radius,
                    unit: unit,
                    ink: ink,
                    amount: face.brow * 0.45,
                    side: offset
                )
            }
        }

        let facing = min(1, max(0, cos(turn)) * 4)
        guard facing > 0.01 else { return }
        context.opacity *= facing

        if unit >= 22 {
            drawBlush(
                in: &context,
                place: onFace,
                anchorHeight: anchorHeight,
                radius: radius,
                spread: spread,
                unit: unit,
                amount: max(0.32, face.blush)
            )
        }

        guard unit >= 21 else { return }
        drawMouth(
            in: &context,
            place: onFace,
            anchorHeight: anchorHeight,
            radius: radius,
            unit: unit,
            ink: ink,
            face: face,
            traits: traits
        )
    }

    private static func drawEye(
        in context: inout GraphicsContext,
        centre: CGPoint,
        radius: CGFloat,
        width widthScale: CGFloat,
        height heightScale: CGFloat,
        side: CGFloat,
        face: PersonaFacePose,
        blink: CGFloat,
        cheer: CGFloat,
        tilt: CGFloat,
        unit: CGFloat,
        ink: Color,
        shape: PersonaTraits.EyeShape,
        opacity: CGFloat
    ) {
        let wide = clamp(face.openness, 0, 1.3)
        let closing = clamp(blink, 0, 1)
        let width = radius * 2 * (shape == .oval ? 0.86 : 1) * widthScale * (1 + closing * 0.10)
        let height = radius * 2 * (shape == .oval ? 1.14 : 1)
            * min(1.4, heightScale * max(1, wide)) * (1 - min(0, blink) * 0.9)
        let open = clamp(min(wide, 1) * (1 - closing), 0, 1)
        let squint = clamp(face.squint, 0, 0.8)
        let smile = clamp(max(cheer, squint * 0.45), 0, 1)
        let focus = clamp((face.brow - 0.15) / 0.85, 0, 1) * (1 - clamp(face.droop, 0, 1)) * 0.55
        let droop = clamp(face.droop, 0, 1)

        context.drawLayer { layer in
            layer.opacity = opacity
            layer.translateBy(x: centre.x, y: centre.y)
            layer.rotate(by: .radians(Double(tilt)))
            let frame = CGRect(x: -width / 2, y: -height / 2, width: width, height: height)
            let eye: Path = shape == .pixel
                ? Path(roundedRect: frame, cornerRadius: min(width, height) * 0.32)
                : Path(ellipseIn: frame)
            layer.fill(eye, with: .color(ink))

            if unit >= 22, open > 0.3 {
                let size = min(width, height)
                let big = size * 0.30
                layer.fill(Path(ellipseIn: CGRect(
                    x: -width * 0.22 - big / 2, y: frame.minY + height * 0.30 - big / 2,
                    width: big, height: big)), with: .color(.white.opacity(0.92)))
                let small = size * 0.13
                layer.fill(Path(ellipseIn: CGRect(
                    x: width * 0.16 - small / 2, y: frame.minY + height * 0.64 - small / 2,
                    width: small, height: small)), with: .color(.white.opacity(0.62)))
            }

            let meet = frame.minY + height * 0.68
            let shut = 1 - open
            let upper = frame.minY + (meet - frame.minY) * shut
            let innerX = side < 0 ? frame.maxX : frame.minX
            let outerX = side < 0 ? frame.minX : frame.maxX
            let innerY = upper + height * 0.30 * focus
            let outerY = upper + height * 0.40 * droop
            func lidY(_ x: CGFloat) -> CGFloat {
                innerY + (outerY - innerY) * (x - innerX) / (outerX - innerX)
            }
            let left = frame.minX - width
            let right = frame.maxX + width
            var upperLid = Path()
            upperLid.move(to: CGPoint(x: left, y: frame.minY - height))
            upperLid.addLine(to: CGPoint(x: right, y: frame.minY - height))
            upperLid.addLine(to: CGPoint(x: right, y: lidY(right)))
            upperLid.addQuadCurve(
                to: CGPoint(x: left, y: lidY(left)),
                control: CGPoint(x: 0, y: lidY(0) - height * (1.6 * shut * (1 - shut) + 0.26 * min(1, focus + droop)))
            )
            upperLid.closeSubpath()

            let base = frame.maxY - (frame.maxY - meet) * shut
                - height * 0.30 * squint
            var lowerLid = Path()
            lowerLid.move(to: CGPoint(x: left, y: base - height * 0.10 * smile))
            lowerLid.addQuadCurve(
                to: CGPoint(x: right, y: base - height * 0.10 * smile),
                control: CGPoint(x: 0, y: base - height * 1.35 * smile)
            )
            lowerLid.addLine(to: CGPoint(x: right, y: frame.maxY + height))
            lowerLid.addLine(to: CGPoint(x: left, y: frame.maxY + height))
            lowerLid.closeSubpath()

            layer.blendMode = .destinationOut
            layer.fill(upperLid, with: .color(.black))
            layer.fill(lowerLid, with: .color(.black))
            layer.blendMode = .normal

            let line = clamp((0.24 - open) / 0.18, 0, 1)
            if line > 0 {
                let sag = height * 0.22 * (smile > 0.5 ? -1 : 1) - height * 0.10 * droop
                var arc = Path()
                arc.move(to: CGPoint(x: frame.minX, y: meet - sag * 0.25))
                arc.addQuadCurve(
                    to: CGPoint(x: frame.maxX, y: meet - sag * 0.25),
                    control: CGPoint(x: 0, y: meet + sag)
                )
                layer.stroke(
                    arc,
                    with: .color(ink.opacity(Double(line))),
                    style: StrokeStyle(lineWidth: max(1, unit * 0.024), lineCap: .round)
                )
            }
        }
    }

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
        context.stroke(path, with: .color(ink.opacity(0.72)), lineWidth: max(1, unit * 0.018))
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
        let resting: CGFloat = switch traits.mouth {
        case .smile: 0.34
        case .frown: -0.34
        case .flat: -0.10
        case .dot, .none: 0
        }
        let curve = min(max(face.mouthCurve + resting, -1.1), 1.1)
        let half = unit * 0.052 * min(face.mouthWidth, 1.2) * traits.mouthWidth
            * (1 + min(max(face.mouthOpen, 0), 1.2) * 0.22)
        let open = min(max(0, face.mouthOpen), 0.8) * unit * 0.065
        let baseY = -anchorHeight + unit * 0.12

        let left = place(-half, baseY)
        let right = place(half, baseY)
        let bow = place(0, baseY + curve * unit * 0.080)
        let sag = place(0, baseY + curve * unit * 0.080 + open * 2)

        if open < unit * 0.006 {
            var path = Path()
            path.move(to: left)
            path.addQuadCurve(to: right, control: bow)
            context.stroke(path, with: .color(ink.opacity(0.78)), lineWidth: max(1, unit * 0.020))
            return
        }

        var path = Path()
        path.move(to: left)
        path.addQuadCurve(to: right, control: bow)
        path.addQuadCurve(to: left, control: sag)
        path.closeSubpath()
        context.fill(path, with: .color(ink.opacity(0.72)))

        guard face.tongue > 0.02 else { return }
        context.drawLayer { inner in
            inner.clip(to: path)
            let reach = min(max(face.tongue, 0), 1)
            let tip = place(0, baseY + curve * unit * 0.080 + open * 2 * (1 - reach * 0.55))
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
                var propContext = context
                propContext.opacity *= mote.opacity
                drawPaper(
                    in: &propContext,
                    at: point,
                    unit: unit,
                    tilt: mote.angle,
                    scale: mote.scale,
                    hue: hue
                )

            case .console:
                var propContext = context
                propContext.opacity *= mote.opacity
                drawConsole(in: &propContext, at: point, unit: unit * mote.scale, tilt: mote.angle, hue: hue)

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

        layer.drawLayer { inked in
            inked.clip(to: sheet)

            var fold = Path()
            fold.move(to: CGPoint(x: frame.midX, y: frame.minY + height * 0.16))
            fold.addQuadCurve(
                to: CGPoint(x: frame.midX, y: frame.maxY - height * 0.05),
                control: CGPoint(x: frame.midX - width * 0.02, y: frame.midY)
            )
            inked.stroke(fold, with: .color(hue.opacity(0.35)), lineWidth: max(1, unit * 0.016))

            guard unit >= 44 else { return }
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

        layer.stroke(sheet, with: .color(hue.opacity(0.95)), lineWidth: max(1, unit * 0.024))
    }
}

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


private func drawFlower(
    in context: inout GraphicsContext,
    at point: CGPoint,
    unit: CGFloat,
    scale: CGFloat,
    hue: Color,
    opacity: CGFloat
) {
    let reach = unit * 0.105 * scale
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
        layer.scaleBy(x: 1, y: max(0.15, abs(cos(tilt * 1.7))))
        layer.fill(
            Path(roundedRect: CGRect(x: -size * 0.5, y: -size * 0.85, width: size, height: size * 1.7), cornerRadius: size * 0.22),
            with: .color(colour.opacity(opacity))
        )
    }
}

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
    context.fill(biscuit, with: .color(hue.opacity(0.62 * opacity)))
    context.stroke(biscuit, with: .color(hue.opacity(0.95 * opacity)), lineWidth: max(1, unit * 0.014))
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
