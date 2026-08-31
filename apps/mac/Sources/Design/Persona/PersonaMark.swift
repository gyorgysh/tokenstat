// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
//
// Source-available for review, NOT open source. See LICENSE: no rights to
// redistribute, publish, or ship a build are granted. Read it, study it, run
// your own build of it.
// "tokenstat" is a trademark of pueev OU. See TRADEMARK.md.

import SwiftUI

/// The face of a conversation.
///
/// Drawn, not drawn-by-someone: every persona gets a character built from one
/// number, so a new persona has a face the moment it is named and there is no
/// asset to ship, scale, or theme. It works at 16pt beside a message and at
/// 96pt in the wizard from the same source, on Mac and phone alike.
///
/// It is one creature in different moods rather than eleven icons. Underneath
/// is a soft body: a ring of masses held out by pressure, with a floor to land
/// on. Moods do not pose it, they push it, so it lands heavier from higher up,
/// keeps ringing after a hit, and carries a bounce across a change of mood
/// instead of cutting to the next state.
///
/// Motion stays inside a fixed frame. The stage's floor, ceiling and rails are
/// fractions of that frame, so a streaming transcript can pin to this seat
/// while the character bounces, dances or melts inside it without the row
/// changing height.
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
    /// Whether a click or tap shoves it. Off by default: a face beside a
    /// message is not a control, and a hit area there would steal the click
    /// that selects the row.
    var pokeable = false

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.scenePhase) private var scenePhase
    #if os(macOS)
    @Environment(\.controlActiveState) private var controlActiveState
    #endif
    @State private var engine: PersonaEngine

    init(seed: UInt64, size: CGFloat = 28, state: PersonaMood = .idle, pokeable: Bool = false) {
        self.seed = seed
        self.size = size
        self.state = state
        self.pokeable = pokeable
        _engine = State(initialValue: PersonaEngine(seed: seed, mood: state))
    }

    var body: some View {
        let mark = TimelineView(.animation(minimumInterval: 1 / state.frameRate, paused: !moving)) { context in
            Canvas(opaque: false, rendersAsynchronously: false) { canvas, canvasSize in
                // Stepped here rather than in a task: the view is already
                // being redrawn, and the alternative is invalidating SwiftUI
                // sixty times a second to move a spring.
                if engine.seed != seed {
                    engine.reseed(seed)
                }
                engine.advance(
                    to: context.date.timeIntervalSinceReferenceDate,
                    mood: state,
                    moving: moving
                )
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

    /// Motion is off when the person asked for it to be, and when nobody is
    /// looking. A window that is not key does not need sixty frames a second
    /// of anything, and on a laptop that is battery.
    private var moving: Bool {
        if reduceMotion { return false }
        if scenePhase != .active { return false }
        #if os(macOS)
        if controlActiveState != .key { return false }
        #endif
        return true
    }
}
