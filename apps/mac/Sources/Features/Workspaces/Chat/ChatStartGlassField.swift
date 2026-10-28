// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
import SwiftUI

/// Where the pointer is over the new chat page, kept off the view graph.
///
/// The shader reads it once per frame from inside the timeline's own
/// update, so following the mouse invalidates no view at all. Presence eases
/// in and out on the frame clock, so the lens grows and fades rather than
/// snapping on when the pointer arrives.
@MainActor final class ChatStartPointer {
    /// The pointer's position in the backdrop, nil once it has left.
    var target: CGPoint?
    private var point = CGPoint.zero
    private var presence = 0.0
    private var sampledAt: Double?

    /// (x, y, presence), eased towards the target at the moment of drawing.
    func sample(at now: Double) -> SIMD3<Float> {
        let elapsed = sampledAt.map { min(0.25, max(0, now - $0)) } ?? 0
        sampledAt = now
        let follow = 1 - exp(-elapsed / 0.12)
        if let target {
            point.x += (target.x - point.x) * (presence < 0.01 ? 1 : follow)
            point.y += (target.y - point.y) * (presence < 0.01 ? 1 : follow)
        }
        presence += ((target == nil ? 0 : 1) - presence) * (1 - exp(-elapsed / 0.35))
        return SIMD3(Float(point.x), Float(point.y), Float(presence))
    }
}

/// The new chat page's surface, as arguments to `ChatStartField.metal`.
enum ChatStartGlassField {
    /// The floor the page is drawn on.
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

    static func shader(size: CGSize, time: Double, lift: Bool, dark: Bool, moving: Bool,
                       pointer: SIMD3<Float>) -> Shader {
        Shader(function: ShaderLibrary.default.chatStartField, arguments: [
            .float2(size),
            .float4(Float(time), lift ? 1 : 0, dark ? 1 : 0, moving ? 1 : 0),
            .float4(pointer.x, pointer.y, pointer.z, 0),
            .color(Theme.accent),
        ])
    }
}

/// The field's own clock, integrated frame by frame so its pace can change
/// without the waves jumping to where a faster clock would have put them.
@MainActor final class ChatStartFieldClock {
    private(set) var time = 0.0
    private var pace = 1.0
    private var tickedAt: Double?

    func tick(at now: Double, running: Bool, pace target: Double) -> Double {
        let elapsed = tickedAt.map { min(0.25, max(0, now - $0)) } ?? 0
        tickedAt = running ? now : nil
        pace += (target - pace) * (1 - exp(-elapsed / 0.5))
        time += elapsed * pace
        return time
    }
}

/// A dot grid lit around the composer, with light flowing inward to it.
///
/// Three layers. Underneath is the floor: the Mac's own window glass, tinted
/// so the desktop shows through only faintly, or an opaque colour on a phone
/// and an iPad. Over it a still accent light, then the grid from
/// `ChatStartField.metal`. While a message is sending the waves run faster,
/// so the light visibly gathers into the mark. The clock stops whenever the
/// page is not the thing in front, and with Reduce Motion the grid holds
/// still and only the pointer is left.
struct ChatStartBackdrop: View {
    var isFullScreen = false
    /// The page is on screen and nothing is covering it.
    let active: Bool
    /// Something is being written, so the field brightens a little.
    var lift = false
    /// The first message is on its way.
    var sending = false
    let pointer: ChatStartPointer
    /// The page's coordinate space, which the pointer is measured in.
    static let space = "chatStartBackdrop"
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorScheme) private var colorScheme
    @State private var clock = ChatStartFieldClock()
    @State private var shown = false

    private var moving: Bool { active && !reduceMotion }

    var body: some View {
        ZStack {
            floor
            if !reduceTransparency {
                keyLight
                TimelineView(.animation(minimumInterval: 1 / 30, paused: !active)) { context in
                    let now = context.date.timeIntervalSinceReferenceDate
                    let time = clock.tick(at: now, running: moving, pace: sending ? 4 : 1)
                    GeometryReader { pane in
                        // The pointer arrives in the page's space, and the
                        // backdrop reaches past the page into any safe area.
                        let origin = pane.frame(in: .named(Self.space)).origin
                        let sample = pointer.sample(at: now)
                        Rectangle()
                            .fill(Color.white.opacity(0.001))
                            .colorEffect(ChatStartGlassField.shader(
                                size: pane.size, time: time, lift: lift || sending, dark: colorScheme == .dark,
                                moving: moving,
                                pointer: SIMD3(sample.x - Float(origin.x), sample.y - Float(origin.y), sample.z)))
                    }
                }
                .opacity(shown ? 1 : 0)
            }
        }
        .ignoresSafeArea()
        .allowsHitTesting(false)
        .accessibilityHidden(true)
        .onAppear {
            withAnimation(reduceMotion ? nil : .easeOut(duration: 0.9)) { shown = true }
        }
    }

    private var keyLight: some View {
        let dark = colorScheme == .dark
        return EllipticalGradient(
            stops: [
                .init(color: Theme.accent.opacity((dark ? 0.12 : 0.06) * ChatStartGlassField.lightGain), location: 0),
                .init(color: Theme.accent.opacity((dark ? 0.04 : 0.02) * ChatStartGlassField.lightGain), location: 0.5),
                .init(color: .clear, location: 1),
            ],
            center: UnitPoint(x: 0.5, y: 0.46),
            startRadiusFraction: 0,
            endRadiusFraction: 0.60
        )
        .opacity(shown ? (lift || sending ? 1.15 : 1) : 0)
        .animation(reduceMotion ? nil : .easeOut(duration: 0.6), value: lift || sending)
    }

    @ViewBuilder private var floor: some View {
        if reduceTransparency { ChatStartGlassField.ground }
        else {
            #if os(macOS)
            Group {
                if #available(macOS 26, *) {
                    SidebarGlassSurface(isFullScreen: isFullScreen, cornerRadius: 0)
                } else {
                    Rectangle().fill(.ultraThinMaterial)
                }
            }
            // The glass alone showed the desktop's text through the page.
            // Dark enough that only a faint impression of it remains.
            .overlay(ChatStartGlassField.ground.opacity(0.4))
            #else
            ChatStartGlassField.ground
            #endif
        }
    }
}
