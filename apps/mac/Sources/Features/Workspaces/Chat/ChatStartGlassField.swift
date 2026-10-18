// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
import SwiftUI

/// One pointer sample or one click, with the moment it happened.
struct ChatStartMark {
    var point: CGPoint
    var began: Double
}

/// Pointer history and click rings, deliberately kept off the view graph.
///
/// The shader reads these once per frame from inside the timeline's own
/// update, so taking a sample costs nothing: no view is invalidated and
/// nothing is published. Holding them as view state would rebuild the
/// composer at pointer frequency, which is why the page used to answer the
/// mouse with a throttled ripple rather than following it.
///
/// Both lists are small ring buffers, newest first. Nothing is pruned on a
/// timer: a mark ages out of the shader's reach on its own, and a new one
/// pushes the oldest off the end.
@MainActor final class ChatStartSurfaceMotion {
    private(set) var trail: [ChatStartMark] = []
    private(set) var rings: [ChatStartMark] = []
    private var lastSample = 0.0
    /// When the surface was last told to stay awake.
    var lastWake = 0.0
    /// The last position the parallax was told about, so a jittering mouse
    /// does not publish an offset it has not really earned.
    var settled: CGPoint?
    /// Where the depth layers are leaning to, as the pointer's offset from
    /// the centre in -1...1. Zero once the pointer leaves.
    var aim = CGSize.zero
    /// The composer card's frame in the pane, for the prism around it.
    var card = CGRect.zero
    private var lean = CGSize.zero
    private var leanedAt: Double?

    /// True when the sample was taken, so the caller knows whether this was
    /// movement worth waking the surface for.
    @discardableResult
    func note(_ point: CGPoint, at now: Double) -> Bool {
        guard now - lastSample >= ChatStartGlassField.sampleInterval else { return false }
        lastSample = now
        trail.insert(ChatStartMark(point: point, began: now), at: 0)
        if trail.count > ChatStartGlassField.trailSamples { trail.removeLast() }
        return true
    }

    func strike(_ point: CGPoint, at now: Double) {
        rings.insert(ChatStartMark(point: point, began: now), at: 0)
        if rings.count > ChatStartGlassField.ringSlots { rings.removeLast() }
    }

    func reset() {
        trail = []
        rings = []
        lastSample = 0
        lastWake = 0
        settled = nil
        aim = .zero
        lean = .zero
        leanedAt = nil
    }

    /// The lean, eased towards the aim at the moment the frame is drawn.
    /// Easing here rather than in an animation keeps it off the view graph
    /// like the rest of the motion, and a paused timeline simply holds it.
    func leaning(at now: Double) -> CGSize {
        let elapsed = leanedAt.map { min(0.25, max(0, now - $0)) } ?? 0
        leanedAt = now
        let follow = 1 - exp(-elapsed / ChatStartGlassField.leanLag)
        lean.width += (aim.width - lean.width) * follow
        lean.height += (aim.height - lean.height) * follow
        return lean
    }
}

/// The new chat page's surface, as arguments to `ChatStartField.metal`.
///
/// This was a CPU raster: a 72 pixel image rebuilt every frame, upscaled and
/// blurred to fill the window. It cost an allocation and about nine thousand
/// pixels of trigonometry per frame and could only ever draw curves broad
/// enough to survive the upscale. The shader evaluates the same surface per
/// pixel on the GPU for less, which is what pays for the mist, the rings and
/// the dispersion.
enum ChatStartGlassField {
    /// Slots in the shader's fixed-size arrays. Changing either means
    /// changing the parameter list in `ChatStartField.metal` to match.
    static let trailSamples = 5
    static let ringSlots = 3
    /// Fast enough that a wipe follows the pointer, slow enough that five
    /// samples still cover a visible stretch of its path.
    static let sampleInterval = 1.0 / 45
    static let trailLifetime = 2.4
    static let ringLifetime = 2.2
    /// How long the depth layers take to follow the pointer. Slower than the
    /// wipe, so the room drifts after the hand instead of tracking it.
    static let leanLag = 0.9

    struct Palette {
        var accent: Color
        var secondary: Color
        var background: Color
        var dark: Bool
    }

    /// The floor the page is drawn on, which the surface also tints towards.
    ///
    /// The Mac sits on the window's own glass and has a desktop behind it.
    /// The phone and the iPad have nothing behind them, so they get an opaque
    /// floor instead of a material frosting a blank. See `Theme.chatStartGround`.
    static var ground: Color {
        #if os(macOS)
        Theme.background
        #else
        Theme.chatStartGround
        #endif
    }

    /// How hard the key light is driven. Window glass carries some of the
    /// light itself; an opaque floor carries none, so the phone and the iPad
    /// drive it a little harder for the same depth.
    #if os(macOS)
    static let lightGain = 1.0
    #else
    static let lightGain = 1.3
    #endif

    /// Read from inside a view body, which is where the motion it packs
    /// lives too.
    @MainActor
    static func shader(size: CGSize, time: Double, now: Double, motion: ChatStartSurfaceMotion,
                       lift: Float, gathering: Double = 0, depth: Float = 1, palette: Palette) -> Shader {
        let lean = motion.leaning(at: now)
        let card = motion.card
        var arguments: [Shader.Argument] = [
            .float2(size),
            .float4(Float(time), lift, palette.dark ? 1 : 0, Float(gathering)),
            .float4(Float(lean.width), Float(lean.height), depth, 0),
            .float4(Float(card.minX), Float(card.minY), Float(card.width), Float(card.height)),
            .color(palette.accent),
            .color(palette.secondary),
            .color(palette.background),
        ]
        for slot in 0..<trailSamples {
            arguments.append(mark(motion.trail, slot, now: now, lifetime: trailLifetime))
        }
        for slot in 0..<ringSlots {
            arguments.append(mark(motion.rings, slot, now: now, lifetime: ringLifetime))
        }
        return Shader(function: ShaderLibrary.default.chatStartField, arguments: arguments)
    }

    /// `(x, y, age, strength)`. Strength falls to zero once a mark has aged
    /// out, which is the shader's only test for an empty slot.
    private static func mark(_ marks: [ChatStartMark], _ slot: Int,
                             now: Double, lifetime: Double) -> Shader.Argument {
        guard slot < marks.count else { return .float4(0, 0, 0, 0) }
        let mark = marks[slot]
        // The timeline's date can sit a few milliseconds before the stamp a
        // mark was taken with, so a brand new one would read as negative.
        // That is its first frame, not a reason to drop it.
        let age = max(0, now - mark.began)
        guard age < lifetime else { return .float4(0, 0, 0, 0) }
        return .float4(Float(mark.point.x), Float(mark.point.y), Float(age), 1)
    }
}
