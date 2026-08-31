// SPDX-License-Identifier: LicenseRef-tokenstat-source-available

import SwiftUI

/// The face of a conversation.
///
/// Drawn, not drawn-by-someone: every persona gets a character built from one
/// number, so a new persona has a face the moment it is named and there is no
/// asset to ship, scale, or theme. It works at 16pt beside a message and at
/// 96pt in the wizard from the same source, on Mac and phone alike.
///
/// It is one creature in different moods rather than six icons. Motion stays
/// inside a fixed frame: a slow breathe at rest, a gel morph while thinking,
/// a one-shot hop or tilt for events. The outer size never changes, which is
/// why a streaming transcript can pin to this seat without the character
/// appearing to travel.
///
/// **Colour stays inside the brand.** Hues are sampled along the arc from
/// `Theme.accent` to `Theme.secondary`, never across the whole wheel, so a
/// gallery of personas reads as one family and not as a bag of highlighters.
/// The two states that mean something borrow the colours that already mean it:
/// `Theme.warning` for waiting, `Theme.danger` for failed.
struct PersonaMark: View {
    /// Stable per persona. Zero is fine: it falls back to one settled look
    /// rather than an empty frame, which is what a chat with no persona wants.
    var seed: UInt64
    var size: CGFloat = 28
    var state: PersonaMood = .idle

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.scenePhase) private var scenePhase
    #if os(macOS)
    @Environment(\.controlActiveState) private var controlActiveState
    #endif
    @State private var blinking = false
    @State private var hop: CGFloat = 0
    @State private var tilt: Double = 0

    private var traits: PersonaTraits { PersonaTraits(seed: seed) }

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 24.0, paused: !shouldPulse)) { context in
            let phase = pulse(at: context.date)
            mark(phase: phase)
        }
        .frame(width: size, height: size)
        .offset(y: hop)
        .rotationEffect(.degrees(tilt), anchor: .bottom)
        .accessibilityHidden(true)
        .task(id: blinkToken) { await blinkLoop() }
        .task(id: state) { await play(state) }
    }

    // MARK: - Drawing

    @ViewBuilder
    private func mark(phase: CGFloat) -> some View {
        let traits = traits
        let hue = traits.hue
        let geometry = PersonaGeometry(size: size, phase: phase, mood: state)
        let blob = PersonaBlobShape(
            phase: phase,
            droop: state.droop,
            amplitude: state.gelAmplitude,
            asymmetric: state.asymmetricGel,
            roundness: traits.roundness,
            wobbleA: traits.wobble.0,
            wobbleB: traits.wobble.1,
            wobbleC: traits.wobble.2,
            wobbleD: traits.wobble.3,
            squashWidth: geometry.squash.width,
            squashHeight: geometry.squash.height
        )
        ZStack {
            Ellipse()
                .fill(hue.opacity(0.16))
                .frame(width: geometry.body.width * 0.68, height: size * 0.05)
                .offset(y: geometry.body.maxY - size / 2 - size * 0.015)
            blob.fill(
                LinearGradient(
                    colors: [hue.opacity(0.16), hue.opacity(0.34)],
                    startPoint: UnitPoint(x: 0.5, y: geometry.body.minY / size),
                    endPoint: UnitPoint(x: 0.5, y: geometry.body.maxY / size)
                )
            )
            blob.stroke(hue.opacity(0.9), lineWidth: max(1, size * 0.042))
            if let accent = state.accent {
                blob.stroke(accent, lineWidth: max(1.5, size * 0.055))
            }
            Canvas { context, canvas in
                if traits.hasAntenna {
                    drawAntenna(in: &context, body: geometry.body, unit: geometry.unit, tint: hue)
                }
                context.fill(
                    Path(ellipseIn: CGRect(
                        x: geometry.body.minX + geometry.body.width * 0.16,
                        y: geometry.body.minY + geometry.body.height * 0.12,
                        width: geometry.body.width * 0.20,
                        height: geometry.body.height * 0.13
                    )),
                    with: .color(.white.opacity(0.5))
                )
                drawFace(in: &context, body: geometry.body, unit: geometry.unit, traits: traits, hue: hue)
            }
        }
        .frame(width: size, height: size)
    }

    private func drawAntenna(
        in context: inout GraphicsContext,
        body: CGRect,
        unit: CGFloat,
        tint: Color
    ) {
        let x = body.midX + body.width * 0.20
        let tipY = body.minY - unit * 0.11
        var stalk = Path()
        stalk.move(to: CGPoint(x: x, y: body.minY + unit * 0.03))
        stalk.addQuadCurve(
            to: CGPoint(x: x + unit * 0.05, y: tipY),
            control: CGPoint(x: x + unit * 0.07, y: body.minY - unit * 0.03)
        )
        context.stroke(stalk, with: .color(tint.opacity(0.75)), lineWidth: max(1, unit * 0.032))
        context.fill(
            Path(ellipseIn: CGRect(
                x: x + unit * 0.005,
                y: tipY - unit * 0.045,
                width: unit * 0.09,
                height: unit * 0.09
            )),
            with: .color(tint)
        )
    }

    private func drawFace(
        in context: inout GraphicsContext,
        body: CGRect,
        unit: CGFloat,
        traits: PersonaTraits,
        hue: Color
    ) {
        let count = traits.eyeCount
        let scale: CGFloat = unit < 24 ? 1.35 : unit < 34 ? 1.15 : 1.0
        let radius = unit * (count == 1 ? 0.115 : count == 2 ? 0.082 : 0.065) * scale
        let spread = radius * (count == 2 ? 2.9 : 2.6)
        let ink = state.eyeInk ?? hue
        let centreY = body.midY - body.height * (0.02 - state.eyeLift)
        let shape = state.forcedEyeShape ?? traits.eyeShape

        for index in 0..<count {
            let offset = CGFloat(index) - CGFloat(count - 1) / 2
            let centre = CGPoint(x: body.midX + offset * spread, y: centreY)
            let openness = state.openness(blinking)
            let rect = CGRect(
                x: centre.x - radius,
                y: centre.y - radius * openness,
                width: radius * 2,
                height: radius * 2 * openness
            )
            switch shape {
            case .round, .oval:
                let squeeze: CGFloat = shape == .oval ? 0.78 : 1.0
                context.fill(
                    Path(ellipseIn: rect.insetBy(dx: radius * (1 - squeeze), dy: 0)),
                    with: .color(ink)
                )
            case .pixel:
                context.fill(
                    Path(roundedRect: rect, cornerRadius: radius * 0.32),
                    with: .color(ink)
                )
            case .arc:
                var arc = Path()
                arc.move(to: CGPoint(x: rect.minX, y: rect.maxY))
                arc.addQuadCurve(
                    to: CGPoint(x: rect.maxX, y: rect.maxY),
                    control: CGPoint(x: rect.midX, y: rect.minY - radius * 0.9)
                )
                context.stroke(arc, with: .color(ink), lineWidth: max(1, unit * 0.05))
            }
        }

        guard let mouth = state.forcedMouth ?? traits.mouth, unit >= 22 else { return }
        let y = centreY + radius * 2.1
        let half = unit * 0.075
        var path = Path()
        switch mouth {
        case .dot:
            context.fill(
                Path(ellipseIn: CGRect(
                    x: body.midX - unit * 0.022,
                    y: y - unit * 0.022,
                    width: unit * 0.044,
                    height: unit * 0.044
                )),
                with: .color(ink.opacity(0.75))
            )
            return
        case .smile:
            path.move(to: CGPoint(x: body.midX - half, y: y))
            path.addQuadCurve(
                to: CGPoint(x: body.midX + half, y: y),
                control: CGPoint(x: body.midX, y: y + unit * 0.07)
            )
        case .flat:
            path.move(to: CGPoint(x: body.midX - half * 0.7, y: y))
            path.addLine(to: CGPoint(x: body.midX + half * 0.7, y: y))
        case .frown:
            path.move(to: CGPoint(x: body.midX - half, y: y + unit * 0.03))
            path.addQuadCurve(
                to: CGPoint(x: body.midX + half, y: y + unit * 0.03),
                control: CGPoint(x: body.midX, y: y - unit * 0.05)
            )
        }
        context.stroke(path, with: .color(ink.opacity(0.75)), lineWidth: max(1, unit * 0.038))
    }

    // MARK: - Motion

    private var sceneIsActive: Bool {
        if scenePhase != .active { return false }
        #if os(macOS)
        if controlActiveState != .key { return false }
        #endif
        return true
    }

    private var shouldMove: Bool {
        !reduceMotion && sceneIsActive
    }

    private var shouldPulse: Bool {
        shouldMove && state.period != nil
    }

    private var blinkToken: String {
        "\(state.blinks)-\(shouldMove)"
    }

    private func pulse(at date: Date) -> CGFloat {
        guard shouldPulse, let period = state.period, period > 0 else { return 0 }
        let turn = date.timeIntervalSinceReferenceDate / period
        return CGFloat(turn.truncatingRemainder(dividingBy: 1))
    }

    private func blinkLoop() async {
        guard state.blinks, shouldMove else { return }
        while !Task.isCancelled {
            let wait = Double.random(in: 2.4...5.5)
            try? await Task.sleep(for: .seconds(wait))
            guard !Task.isCancelled else { return }
            blinking = true
            try? await Task.sleep(for: .milliseconds(110))
            blinking = false
        }
    }

    /// One-shot gestures. Repeating motion lives on the phase, not here.
    private func play(_ mood: PersonaMood) async {
        hop = 0
        tilt = 0
        guard shouldMove else { return }
        switch mood {
        case .working:
            withAnimation(.easeOut(duration: 0.10)) { hop = -2 }
            try? await Task.sleep(for: .milliseconds(100))
            guard !Task.isCancelled else { return }
            withAnimation(.easeInOut(duration: 0.16)) { hop = 0 }
        case .waiting:
            withAnimation(.easeOut(duration: 0.14)) { tilt = 7 }
            try? await Task.sleep(for: .milliseconds(180))
            guard !Task.isCancelled else { return }
            withAnimation(.easeInOut(duration: 0.22)) { tilt = 0 }
        case .ok:
            withAnimation(.spring(duration: 0.22, bounce: 0.38)) { hop = -1.5 }
            try? await Task.sleep(for: .milliseconds(120))
            guard !Task.isCancelled else { return }
            withAnimation(.spring(duration: 0.28, bounce: 0.18)) { hop = 0 }
        default:
            break
        }
    }
}

/// The blob's outer path, driven by a scalar phase so SwiftUI interpolates
/// gel rather than swapping two Boolean poses.
struct PersonaBlobShape: Shape {
    var phase: CGFloat
    var droop: CGFloat
    var amplitude: CGFloat
    var asymmetric: Bool
    var roundness: CGFloat
    var wobbleA: CGFloat
    var wobbleB: CGFloat
    var wobbleC: CGFloat
    var wobbleD: CGFloat
    var squashWidth: CGFloat
    var squashHeight: CGFloat

    var animatableData: AnimatablePair<CGFloat, CGFloat> {
        get { AnimatablePair(phase, droop) }
        set {
            phase = newValue.first
            droop = newValue.second
        }
    }

    func path(in rect: CGRect) -> Path {
        let geometry = PersonaGeometry(
            canvas: rect.size,
            squash: (squashWidth, squashHeight)
        )
        return blobPath(in: geometry.body)
    }

    /// A closed curve through four points, each pushed well off centre.
    ///
    /// Phase nudges the control points. After the nudge the centroid is
    /// pulled back, then clamped to one point, so thinking reads as gel and
    /// not as the whole creature sliding in its seat.
    private func blobPath(in rect: CGRect) -> Path {
        let w = rect.width
        let h = rect.height
        let k = roundness
        let wave = sin(phase * 2 * .pi)
        let wave2 = sin(phase * 2 * .pi + 1.17)
        let leftAmp = amplitude * (asymmetric ? 1.0 : 0.55)
        let rightAmp = amplitude * (asymmetric ? 0.7 : 0.55)
        let droopY = h * droop * 0.22

        var top = CGPoint(
            x: rect.midX + w * wobbleA * 0.24 + w * amplitude * wave * 0.35,
            y: rect.minY + h * abs(wobbleB) * 0.09 + h * amplitude * 0.28 * wave2
        )
        var right = CGPoint(
            x: rect.maxX - w * abs(wobbleB) * 0.05 + w * rightAmp * wave2,
            y: rect.midY + h * (wobbleC * 0.22) + droopY + h * rightAmp * wave * 0.4
        )
        var bottom = CGPoint(
            x: rect.midX + w * wobbleD * 0.12,
            y: rect.maxY
        )
        var left = CGPoint(
            x: rect.minX + w * abs(wobbleD) * 0.05 - w * leftAmp * wave,
            y: rect.midY + h * (wobbleA * 0.22) + droopY + h * leftAmp * wave2 * 0.4
        )

        let centroid = CGPoint(
            x: (top.x + right.x + bottom.x + left.x) / 4,
            y: (top.y + right.y + bottom.y + left.y) / 4
        )
        let shift = CGPoint(
            x: clamp(rect.midX - centroid.x, -1, 1),
            y: clamp(rect.midY - centroid.y, -1, 1)
        )
        top.x += shift.x
        top.y += shift.y
        right.x += shift.x
        right.y += shift.y
        bottom.x += shift.x
        bottom.y += shift.y
        left.x += shift.x
        left.y += shift.y

        var path = Path()
        path.move(to: top)
        path.addCurve(
            to: right,
            control1: CGPoint(x: rect.midX + w * (k + wobbleC * 0.14) + shift.x, y: rect.minY - h * (k - 0.34) + shift.y),
            control2: CGPoint(x: rect.maxX + w * (k - 0.34) + shift.x, y: rect.midY - h * (k * 0.62 + wobbleB * 0.12) + shift.y)
        )
        path.addCurve(
            to: bottom,
            control1: CGPoint(x: rect.maxX + w * (k - 0.36) + shift.x, y: rect.maxY + h * 0.10 + shift.y),
            control2: CGPoint(x: rect.midX + w * (k - 0.02) + shift.x, y: rect.maxY + h * 0.08 + shift.y)
        )
        path.addCurve(
            to: left,
            control1: CGPoint(x: rect.midX - w * (k - 0.02) + shift.x, y: rect.maxY + h * 0.08 + shift.y),
            control2: CGPoint(x: rect.minX - w * (k - 0.36) + shift.x, y: rect.maxY + h * 0.10 + shift.y)
        )
        path.addCurve(
            to: top,
            control1: CGPoint(x: rect.minX - w * (k - 0.34) + shift.x, y: rect.midY - h * (k * 0.62 + wobbleD * 0.12) + shift.y),
            control2: CGPoint(x: rect.midX - w * (k + wobbleA * 0.14) + shift.x, y: rect.minY - h * (k - 0.34) + shift.y)
        )
        path.closeSubpath()
        return path
    }
}

/// Shared layout for the blob and the face that sits on it, so fill and
/// features agree on where the body is.
struct PersonaGeometry {
    let unit: CGFloat
    let body: CGRect
    let squash: (width: CGFloat, height: CGFloat)

    init(size: CGFloat, phase: CGFloat, mood: PersonaMood) {
        self.init(canvas: CGSize(width: size, height: size), squash: mood.squash(phase))
    }

    init(canvas: CGSize, squash: (width: CGFloat, height: CGFloat)) {
        unit = min(canvas.width, canvas.height)
        self.squash = squash
        let headroom = unit * 0.16
        let width = unit * squash.width
        let height = (unit - headroom) * squash.height
        body = CGRect(
            x: (canvas.width - width) / 2,
            y: canvas.height - height - unit * 0.04,
            width: width,
            height: height
        )
    }
}

private func clamp(_ value: CGFloat, _ lower: CGFloat, _ upper: CGFloat) -> CGFloat {
    min(upper, max(lower, value))
}

/// What the character is doing, which is what the conversation is doing.
enum PersonaMood: Hashable {
    case idle
    case thinking
    case working
    /// A tool is waiting on a person. Wide eyes, and the colour that already
    /// means "your turn" everywhere else in the app, on the outline only.
    case waiting
    case ok
    case failed

    var blinks: Bool { self == .idle || self == .ok }

    /// Seconds per gel cycle, or nil for a pose that holds still.
    var period: Double? {
        switch self {
        case .idle: return 2.8
        case .thinking: return 1.15
        case .working: return 0.9
        case .waiting, .ok, .failed: return nil
        }
    }

    /// How far phase may push the silhouette, as a fraction of the body.
    var gelAmplitude: CGFloat {
        switch self {
        case .idle: return 0.025
        case .thinking: return 0.048
        case .working: return 0.02
        default: return 0
        }
    }

    var asymmetricGel: Bool { self == .thinking }

    var droop: CGFloat { self == .failed ? 1 : 0 }

    /// An outline colour that overrides the persona's own, or nil to keep it.
    var accent: Color? {
        switch self {
        case .waiting: return Theme.warning
        case .failed: return Theme.danger
        default: return nil
        }
    }

    var eyeInk: Color? {
        switch self {
        case .waiting: return Theme.warning
        case .failed: return Theme.danger
        default: return nil
        }
    }

    var forcedEyeShape: PersonaTraits.EyeShape? {
        switch self {
        case .ok: return .arc
        default: return nil
        }
    }

    var forcedMouth: PersonaTraits.Mouth? {
        switch self {
        case .ok: return .smile
        case .failed: return .frown
        case .waiting: return .dot
        default: return nil
        }
    }

    /// Width and height as a fraction of the frame. Volume stays close to
    /// conserved. Idle is a 2-3% breathe, thinking barely changes the box,
    /// failed is a held squash.
    func squash(_ phase: CGFloat) -> (width: CGFloat, height: CGFloat) {
        let wave = sin(phase * 2 * .pi)
        switch self {
        case .idle:
            let breathe = wave * 0.025
            return (0.84 + breathe, 0.83 - breathe)
        case .thinking:
            let breathe = wave * 0.012
            return (0.84 + breathe, 0.83 - breathe * 0.6)
        case .working:
            let breathe = wave * 0.018
            return (0.84 + breathe, 0.83 - breathe)
        case .waiting:
            return (0.85, 0.84)
        case .ok:
            return (0.84, 0.84)
        case .failed:
            return (0.94, 0.64)
        }
    }

    var eyeLift: CGFloat {
        switch self {
        case .thinking: return 0.08
        case .waiting: return 0.05
        default: return 0
        }
    }

    func openness(_ blinking: Bool) -> CGFloat {
        if blinking { return 0.12 }
        switch self {
        case .working: return 0.55
        case .waiting: return 1.2
        case .failed: return 0.35
        default: return 1
        }
    }
}

/// The fixed features of one character, derived from its seed.
///
/// Deterministic and cheap: the same persona is the same creature on every
/// launch, on every device, with nothing stored but the number.
struct PersonaTraits {
    enum EyeShape { case round, oval, arc, pixel }
    enum Mouth { case dot, smile, flat, frown }

    let hue: Color
    let eyeCount: Int
    let eyeShape: EyeShape
    let mouth: Mouth?
    let hasAntenna: Bool
    let wobble: (CGFloat, CGFloat, CGFloat, CGFloat)
    /// How far the silhouette's control points reach: low is round, high is a
    /// soft square. The single strongest axis of difference between two faces.
    let roundness: CGFloat

    init(seed: UInt64) {
        var bits = seed == 0 ? 0x9E37_79B9_7F4A_7C15 : seed
        func next(_ modulo: UInt64) -> UInt64 {
            bits ^= bits << 13
            bits ^= bits >> 7
            bits ^= bits << 17
            return bits % modulo
        }
        eyeCount = switch next(10) {
        case 0, 1: 1
        case 2: 3
        default: 2
        }
        eyeShape = switch next(4) {
        case 0: .round
        case 1: .arc
        case 2: .pixel
        default: .oval
        }
        mouth = switch next(5) {
        case 0: .smile
        case 1: .flat
        case 2: .dot
        default: nil
        }
        hasAntenna = next(3) == 0
        roundness = 0.34 + CGFloat(next(5)) * 0.055
        wobble = (
            CGFloat(next(200)) / 100 - 1,
            CGFloat(next(200)) / 100 - 1,
            CGFloat(next(200)) / 100 - 1,
            CGFloat(next(200)) / 100 - 1
        )
        hue = Theme.accent.mixed(with: Theme.secondary, by: Double(next(7)) / 6)
    }
}

extension Color {
    /// Blend towards another colour. Used to walk the accent-to-secondary arc
    /// so a persona's tint is always a colour this app already owns.
    func mixed(with other: Color, by amount: Double) -> Color {
        let amount = min(max(amount, 0), 1)
        #if canImport(AppKit)
        guard let from = NSColor(self).usingColorSpace(.sRGB),
              let to = NSColor(other).usingColorSpace(.sRGB)
        else { return self }
        #else
        let from = UIColor(self)
        let to = UIColor(other)
        #endif
        var fromComponents = (r: CGFloat(0), g: CGFloat(0), b: CGFloat(0), a: CGFloat(0))
        var toComponents = (r: CGFloat(0), g: CGFloat(0), b: CGFloat(0), a: CGFloat(0))
        from.getRed(&fromComponents.r, green: &fromComponents.g, blue: &fromComponents.b, alpha: &fromComponents.a)
        to.getRed(&toComponents.r, green: &toComponents.g, blue: &toComponents.b, alpha: &toComponents.a)
        let mix = CGFloat(amount)
        return Color(
            .sRGB,
            red: Double(fromComponents.r + (toComponents.r - fromComponents.r) * mix),
            green: Double(fromComponents.g + (toComponents.g - fromComponents.g) * mix),
            blue: Double(fromComponents.b + (toComponents.b - fromComponents.b) * mix),
            opacity: Double(fromComponents.a + (toComponents.a - fromComponents.a) * mix)
        )
    }
}

/// A face for something that has no persona.
///
/// Every conversation gets a character, whether or not anybody made one, so
/// the transcript is never a row of grey dots waiting for a feature to be
/// used. Derived from the conversation's own id, so it is that chat's face for
/// as long as the chat exists.
///
/// The same FNV-1a as `chat_turn::stable_hash` on the host, on purpose: a
/// persona seeded there and a chat seeded here have to sit in the same family,
/// and a second hash function would be a second set of faces.
func personaSeed(for identifier: String) -> UInt64 {
    var hash: UInt64 = 0xcbf2_9ce4_8422_2325
    for byte in identifier.utf8 {
        hash ^= UInt64(byte)
        hash = hash &* 0x0000_0100_0000_01b3
    }
    return hash | 1
}
