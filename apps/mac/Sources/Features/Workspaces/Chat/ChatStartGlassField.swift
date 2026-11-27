// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
import SwiftUI

@MainActor final class ChatStartPointer {
    struct Sample {
        var lens: SIMD3<Float>
        var stir: Float
        var ripples: [SIMD4<Float>]
    }

    var target: CGPoint? {
        didSet {
            guard let oldValue, let target else { return }
            stirring = min(1, stirring + hypot(target.x - oldValue.x, target.y - oldValue.y) / 140)
        }
    }
    private var point = CGPoint.zero
    private var presence = 0.0
    private var stirring = 0.0
    private var stir = 0.0
    private var sampledAt: Double?
    private var ripples: [(point: CGPoint, at: Double)] = []
    private static let rippleLife = 1.8

    func ripple(at point: CGPoint, now: Double = Date().timeIntervalSinceReferenceDate) {
        ripples.append((point, now))
        if ripples.count > 3 { ripples.removeFirst(ripples.count - 3) }
    }

    func sample(at now: Double) -> Sample {
        let elapsed = sampledAt.map { min(0.25, max(0, now - $0)) } ?? 0
        sampledAt = now
        let follow = 1 - exp(-elapsed / 0.12)
        if let target {
            point.x += (target.x - point.x) * (presence < 0.01 ? 1 : follow)
            point.y += (target.y - point.y) * (presence < 0.01 ? 1 : follow)
        }
        presence += ((target == nil ? 0 : 1) - presence) * (1 - exp(-elapsed / 0.35))
        stir += (stirring - stir) * (1 - exp(-elapsed / 0.10))
        stirring *= exp(-elapsed / 0.45)
        if stir < 0.002 { stir = 0 }
        ripples.removeAll { now - $0.at > Self.rippleLife }
        var slots = ripples.map {
            SIMD4(Float($0.point.x), Float($0.point.y), Float(max(0, now - $0.at)), 1)
        }
        while slots.count < 3 { slots.append(.zero) }
        return Sample(lens: SIMD3(Float(point.x), Float(point.y), Float(presence)),
                      stir: Float(stir), ripples: slots)
    }
}

enum ChatStartGlassField {
    static var ground: Color {
        #if os(macOS)
        Theme.background
        #else
        Theme.chatStartGround
        #endif
    }

    #if os(macOS)
    static let lightGain = 1.0
    #else
    static let lightGain = 1.3
    #endif

    static func shader(size: CGSize, time: Double, lift: Bool, dark: Bool, moving: Bool,
                       pointer: ChatStartPointer.Sample, glyphClock: Double, focus: UnitPoint) -> Shader {
        let lens = pointer.lens
        let ripples = pointer.ripples
        return Shader(function: ShaderLibrary.default.chatStartField, arguments: [
            .float2(size),
            .float4(Float(time), lift ? 1 : 0, dark ? 1 : 0, moving ? 1 : 0),
            .float4(lens.x, lens.y, lens.z, 0),
            .float2(Float(focus.x), Float(focus.y)),
            .color(Theme.accent),
            .float4(pointer.stir, Float(glyphClock.truncatingRemainder(dividingBy: 1000)), 0, 0),
            .float4(ripples[0].x, ripples[0].y, ripples[0].z, ripples[0].w),
            .float4(ripples[1].x, ripples[1].y, ripples[1].z, ripples[1].w),
            .float4(ripples[2].x, ripples[2].y, ripples[2].z, ripples[2].w),
        ])
    }
}

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

struct ChatStartBackdrop: View {
    var isFullScreen = false
    let active: Bool
    var lift = false
    var sending = false
    let pointer: ChatStartPointer
    var focus = UnitPoint(x: 0.5, y: 0.46)
    static let space = "chatStartBackdrop"
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorScheme) private var colorScheme
    @State private var clock = ChatStartFieldClock()
    @State private var shown = false

    #if os(iOS)
    @State private var lowPower = ProcessInfo.processInfo.isLowPowerModeEnabled
    private var moving: Bool { active && !reduceMotion && !lowPower }
    private var ticking: Bool { moving }
    #else
    private var moving: Bool { active && !reduceMotion }
    private var ticking: Bool { active }
    #endif

    var body: some View {
        ZStack {
            floor
            if !reduceTransparency {
                keyLight
                TimelineView(.animation(minimumInterval: 1 / 30, paused: !ticking)) { context in
                    let now = context.date.timeIntervalSinceReferenceDate
                    let time = clock.tick(at: now, running: moving, pace: sending ? 4 : 1)
                    GeometryReader { pane in
                        let origin = pane.frame(in: .named(Self.space)).origin
                        let sample = Self.local(pointer.sample(at: now), origin: origin)
                        Rectangle()
                            .fill(Color.white.opacity(0.001))
                            .colorEffect(ChatStartGlassField.shader(
                                size: pane.size, time: time, lift: lift || sending, dark: colorScheme == .dark,
                                moving: moving, pointer: sample, glyphClock: now, focus: focus))
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
        #if os(iOS)
        .onReceive(NotificationCenter.default.publisher(for: .NSProcessInfoPowerStateDidChange)) { _ in
            lowPower = ProcessInfo.processInfo.isLowPowerModeEnabled
        }
        #endif
    }

    private static func local(_ sample: ChatStartPointer.Sample, origin: CGPoint) -> ChatStartPointer.Sample {
        let shift = SIMD2(Float(origin.x), Float(origin.y))
        var moved = sample
        moved.lens = SIMD3(sample.lens.x - shift.x, sample.lens.y - shift.y, sample.lens.z)
        moved.ripples = sample.ripples.map { SIMD4($0.x - shift.x, $0.y - shift.y, $0.z, $0.w) }
        return moved
    }

    private var keyLight: some View {
        let dark = colorScheme == .dark
        return EllipticalGradient(
            stops: [
                .init(color: Theme.accent.opacity((dark ? 0.12 : 0.06) * ChatStartGlassField.lightGain), location: 0),
                .init(color: Theme.accent.opacity((dark ? 0.04 : 0.02) * ChatStartGlassField.lightGain), location: 0.5),
                .init(color: .clear, location: 1),
            ],
            center: focus,
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
            .overlay(ChatStartGlassField.ground.opacity(0.4))
            #else
            ChatStartGlassField.ground
            #endif
        }
    }
}
