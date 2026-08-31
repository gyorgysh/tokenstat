// SPDX-License-Identifier: LicenseRef-tokenstat-source-available

import SwiftUI

/// The face of a conversation.
///
/// Drawn, not drawn-by-someone: every persona gets a character built from one
/// number, so a new persona has a face the moment it is named and there is no
/// asset to ship, scale, or theme. It works at 16pt beside a message and at
/// 96pt in the wizard from the same source, on Mac and phone alike.
///
/// It is one creature in different moods rather than six icons. That is the
/// point of it: the same character that sits beside a persona's name is the
/// one that squashes while the agent thinks and goes wide-eyed when the agent
/// needs an answer, so a glance at the transcript tells you what is happening
/// without reading a word.
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
    @State private var breathing = false
    @State private var blinking = false

    private var traits: PersonaTraits { PersonaTraits(seed: seed) }

    var body: some View {
        Canvas { context, canvasSize in
            draw(in: &context, size: canvasSize)
        }
        .frame(width: size, height: size)
        .animation(motion, value: breathing)
        .animation(.easeInOut(duration: 0.09), value: blinking)
        .onAppear(perform: start)
        .onChange(of: state) { _, _ in start() }
        .accessibilityHidden(true)
    }

    // MARK: - Drawing

    private func draw(in context: inout GraphicsContext, size canvas: CGSize) {
        let traits = traits
        let unit = min(canvas.width, canvas.height)
        let hue = traits.hue
        let accent = state.accent

        // Room above the body for an antenna, and a hair below for the shadow
        // it sits on. Reserving it here rather than letting the frame clip is
        // why the flourish is visible at all.
        let headroom = unit * 0.16
        let squash = state.squash(breathing)
        let width = unit * squash.width
        let height = (unit - headroom) * squash.height
        let body = CGRect(
            x: (canvas.width - width) / 2,
            y: canvas.height - height - unit * 0.04,
            width: width,
            height: height
        )

        // The thing it is resting on. A blob with no contact shadow floats,
        // and a floating blob is a logo rather than a creature.
        context.fill(
            Path(ellipseIn: CGRect(
                x: body.midX - width * 0.34,
                y: body.maxY - unit * 0.015,
                width: width * 0.68,
                height: unit * 0.05
            )),
            with: .color(hue.opacity(0.16))
        )

        if traits.hasAntenna {
            drawAntenna(in: &context, body: body, unit: unit, tint: hue)
        }

        let shape = blobPath(in: body, traits: traits, state: state)
        // Gel, not a sticker: a soft vertical wash so the base reads heavier
        // than the dome, which is what makes the silhouette look like it holds
        // something rather than being cut out of paper.
        context.fill(
            shape,
            with: .linearGradient(
                Gradient(colors: [hue.opacity(0.16), hue.opacity(0.34)]),
                startPoint: CGPoint(x: body.midX, y: body.minY),
                endPoint: CGPoint(x: body.midX, y: body.maxY)
            )
        )
        context.stroke(shape, with: .color(hue.opacity(0.9)), lineWidth: max(1, unit * 0.042))

        // One highlight, off to the upper left. This single ellipse is what
        // turns the fill into something wet.
        context.fill(
            Path(ellipseIn: CGRect(
                x: body.minX + width * 0.16,
                y: body.minY + height * 0.12,
                width: width * 0.20,
                height: height * 0.13
            )),
            with: .color(.white.opacity(0.5))
        )

        drawFace(in: &context, body: body, unit: unit, traits: traits, hue: hue)

        // A mood is a ring, never a repaint. Recolouring the whole creature
        // for "waiting" threw away the one thing that made it this persona,
        // so the state rides on the outline and the eyes instead.
        if let accent {
            context.stroke(shape, with: .color(accent), lineWidth: max(1.5, unit * 0.055))
        }
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

    /// A closed curve through four points, each pushed well off centre.
    ///
    /// The wobble is large on purpose. An earlier version nudged the control
    /// points by a few percent and produced ten rounded rectangles: technically
    /// distinct, visually one shape. A silhouette has to be different enough to
    /// recognise across a list before it is worth deriving at all.
    ///
    /// The base stays wide and low whatever the seed does, so every character
    /// sits rather than floats, and the top is where the variation goes.
    private func blobPath(in rect: CGRect, traits: PersonaTraits, state: PersonaMood) -> Path {
        var path = Path()
        let w = rect.width, h = rect.height
        let (a, b, c, d) = traits.wobble
        let droop = state == .failed ? 0.22 : 0

        // How far the control points reach. Low is a circle, high is a
        // rounded square, and this one number is what makes two seeds read as
        // different creatures rather than the same one nudged.
        let k = traits.roundness

        let top = CGPoint(x: rect.midX + w * a * 0.24, y: rect.minY + h * abs(b) * 0.09)
        let right = CGPoint(x: rect.maxX - w * abs(b) * 0.05, y: rect.midY + h * (c * 0.22 + droop))
        let bottom = CGPoint(x: rect.midX + w * d * 0.12, y: rect.maxY)
        let left = CGPoint(x: rect.minX + w * abs(d) * 0.05, y: rect.midY + h * (a * 0.22 + droop))

        path.move(to: top)
        path.addCurve(
            to: right,
            control1: CGPoint(x: rect.midX + w * (k + c * 0.14), y: rect.minY - h * (k - 0.34)),
            control2: CGPoint(x: rect.maxX + w * (k - 0.34), y: rect.midY - h * (k * 0.62 + b * 0.12))
        )
        // Both lower controls hug the base line, which is what keeps the
        // bottom flat-ish however wild the top gets.
        path.addCurve(
            to: bottom,
            control1: CGPoint(x: rect.maxX + w * (k - 0.36), y: rect.maxY + h * 0.10),
            control2: CGPoint(x: rect.midX + w * (k - 0.02), y: rect.maxY + h * 0.08)
        )
        path.addCurve(
            to: left,
            control1: CGPoint(x: rect.midX - w * (k - 0.02), y: rect.maxY + h * 0.08),
            control2: CGPoint(x: rect.minX - w * (k - 0.36), y: rect.maxY + h * 0.10)
        )
        path.addCurve(
            to: top,
            control1: CGPoint(x: rect.minX - w * (k - 0.34), y: rect.midY - h * (k * 0.62 + d * 0.12)),
            control2: CGPoint(x: rect.midX - w * (k + a * 0.14), y: rect.minY - h * (k - 0.34))
        )
        path.closeSubpath()
        return path
    }

    private func drawFace(
        in context: inout GraphicsContext,
        body: CGRect,
        unit: CGFloat,
        traits: PersonaTraits,
        hue: Color
    ) {
        let count = traits.eyeCount
        // Eyes grow relative to the body as the frame shrinks. At 16pt a
        // proportional face is a smudge, and the sidebar is full of 16pt.
        let scale = unit < 24 ? 1.35 : unit < 34 ? 1.15 : 1.0
        let radius = unit * (count == 1 ? 0.115 : count == 2 ? 0.082 : 0.065) * scale
        // Comfortably more than twice the radius, or two eyes touch and read
        // as one peanut. That is what the first pass did.
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
                let squeeze = shape == .oval ? 0.78 : 1.0
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
                // Shut is a line whatever it is open, so an arc still blinks
                // rather than disappearing.
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

    private var motion: Animation? {
        guard !reduceMotion, let period = state.period else { return nil }
        return .easeInOut(duration: period).repeatForever(autoreverses: true)
    }

    private func start() {
        breathing = false
        blinking = false
        guard !reduceMotion else { return }
        // Set on the next runloop pass, so the animation has a value to move
        // from. Assigning inside `onAppear` with the same value does nothing.
        DispatchQueue.main.async { breathing = true }
        guard state.blinks else { return }
        Task { @MainActor in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(.random(in: 2.4...5.5)))
                blinking = true
                try? await Task.sleep(for: .milliseconds(110))
                blinking = false
            }
        }
    }
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

    /// Seconds per breath, or nil for a pose that does not move.
    var period: Double? {
        switch self {
        case .idle: return 2.6
        case .thinking: return 0.9
        case .working: return 0.55
        case .waiting: return 1.4
        case .ok, .failed: return nil
        }
    }

    /// An outline colour that overrides the persona's own, or nil to keep it.
    ///
    /// Only the two states that carry a warning get one, and only on the
    /// outline. Repainting the whole creature threw away the thing that made
    /// it recognisable as this persona, which is most of its job.
    var accent: Color? {
        switch self {
        case .waiting: return Theme.warning
        case .failed: return Theme.danger
        default: return nil
        }
    }

    /// Ink for the eyes and mouth. Nil means the persona's own colour.
    var eyeInk: Color? {
        switch self {
        case .waiting: return Theme.warning
        case .failed: return Theme.danger
        default: return nil
        }
    }

    /// Some states own their expression regardless of the seed, because the
    /// expression is the message. A finished turn smiles whatever face it has.
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

    /// Width and height as a fraction of the frame. Squash and stretch: the
    /// body gets wider as it gets shorter, so volume looks conserved and the
    /// thing reads as soft rather than as an image being scaled.
    func squash(_ phase: Bool) -> (width: CGFloat, height: CGFloat) {
        switch self {
        case .idle:
            return phase ? (0.86, 0.80) : (0.81, 0.86)
        case .thinking:
            return phase ? (0.74, 0.94) : (0.92, 0.72)
        case .working:
            return phase ? (0.90, 0.76) : (0.78, 0.90)
        case .waiting:
            return phase ? (0.87, 0.87) : (0.82, 0.82)
        case .ok:
            return (0.84, 0.84)
        case .failed:
            return (0.96, 0.60)
        }
    }

    /// How far the eyes sit above centre. Looking up reads as thinking.
    var eyeLift: CGFloat {
        switch self {
        case .thinking: return 0.12
        case .waiting: return 0.05
        default: return 0
        }
    }

    /// 1 is wide open, 0 is shut.
    func openness(_ blinking: Bool) -> CGFloat {
        if blinking { return 0.12 }
        switch self {
        case .working: return 0.42
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
            // A cheap xorshift, so eight draws from one number are not eight
            // views of the same low bits.
            bits ^= bits << 13
            bits ^= bits >> 7
            bits ^= bits << 17
            return bits % modulo
        }
        // Two eyes most of the time, one often enough to be a surprise, three
        // rarely. A gallery where every third face is a cyclops is a novelty;
        // one where it happens now and then is a character.
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
        // Often no mouth at all. A face that is only eyes is calmer, and it
        // leaves the mouth free to mean something when a state adds one.
        mouth = switch next(5) {
        case 0: .smile
        case 1: .flat
        case 2: .dot
        default: nil
        }
        hasAntenna = next(3) == 0
        roundness = 0.34 + CGFloat(next(5)) * 0.055
        // Full-range, because half-hearted wobble produced ten rounded
        // rectangles that were technically distinct and visually identical.
        wobble = (
            CGFloat(next(200)) / 100 - 1,
            CGFloat(next(200)) / 100 - 1,
            CGFloat(next(200)) / 100 - 1,
            CGFloat(next(200)) / 100 - 1
        )
        // Sampled along the brand arc only: `Theme.accent` at one end,
        // `Theme.secondary` at the other, nothing outside it.
        //
        // Seven stops rather than a continuous mix. A continuous one gave ten
        // personas nine shades of the same violet, because neighbouring points
        // on a short arc are not a difference anybody can see. Quantising
        // spends the whole arc on telling faces apart.
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
