// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
//
// Source-available: source sharing and own builds are permitted.
// Store and commercial distribution of builds is reserved. See LICENSE.
// "tokenstat" is a trademark of pueev OU. See TRADEMARK.md.

import SwiftUI

private struct WindowLiveResizingKey: EnvironmentKey {
    static let defaultValue = false
}

private struct PersonaMotionAllowedKey: EnvironmentKey {
    static let defaultValue = true
}

extension EnvironmentValues {
    var personaMotionAllowed: Bool {
        get { self[PersonaMotionAllowedKey.self] }
        set { self[PersonaMotionAllowedKey.self] = newValue }
    }

    var isWindowLiveResizing: Bool {
        get { self[WindowLiveResizingKey.self] }
        set { self[WindowLiveResizingKey.self] = newValue }
    }
}

struct PersonaMark: View {
    var seed: UInt64
    var size: CGFloat = 28
    var state: PersonaMood = .idle
    var pokeable = false
    var settlesAfter: Double?

    @Environment(\.personaMotionAllowed) private var paneAllowsMotion
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.isWindowLiveResizing) private var isLiveResizing
    @Environment(\.scenePhase) private var scenePhase
    #if os(macOS)
    @Environment(\.controlActiveState) private var controlActiveState
    #endif
    @State private var isVisible = false
    @State private var settled = false
    @State private var engine: PersonaEngine

    init(seed: UInt64, size: CGFloat = 28, state: PersonaMood = .idle, pokeable: Bool = false,
         settlesAfter: Double? = nil) {
        self.seed = seed
        self.size = size
        self.state = state
        self.pokeable = pokeable
        self.settlesAfter = settlesAfter
        _engine = State(initialValue: PersonaEngine(seed: seed, mood: state))
    }

    var body: some View {
        let mark = TimelineView(.animation(minimumInterval: 1 / state.frameRate, paused: !moving || isLiveResizing)) { context in
            Canvas(opaque: false, rendersAsynchronously: false) { canvas, canvasSize in
                // Stepped here rather than in a task: the view is already
                // being redrawn, and the alternative is invalidating SwiftUI
                // sixty times a second to move a spring.
                if engine.seed != seed {
                    engine.reseed(seed)
                }
                if isLiveResizing {
                    engine.suspendClock()
                } else {
                    engine.advance(
                        to: context.date.timeIntervalSinceReferenceDate,
                        mood: state,
                        moving: moving
                    )
                }
                var canvas = canvas
                PersonaRenderer.draw(
                    engine,
                    in: &canvas,
                    rect: CGRect(origin: .zero, size: canvasSize)
                )
            }
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
        .onAppear { isVisible = true; engine.suspendClock() }
        .onDisappear { isVisible = false; engine.suspendClock() }
        .task(id: state) {
            settled = false
            guard let settlesAfter else { return }
            try? await Task.sleep(for: .seconds(settlesAfter))
            if !Task.isCancelled { settled = true }
        }

        if pokeable {
            mark
                .contentShape(Rectangle())
                .gesture(
                    DragGesture(minimumDistance: 0)
                        .onEnded { value in
                            engine.poke(at: CGPoint(
                                x: value.location.x / max(size, 1),
                                y: value.location.y / max(size, 1)
                            ))
                        }
                )
        } else {
            mark
        }
    }

    private var moving: Bool {
        if reduceMotion || settled || !isVisible || !paneAllowsMotion { return false }
        if scenePhase != .active { return false }
        #if os(macOS)
        if controlActiveState != .key { return false }
        #endif
        return true
    }
}
