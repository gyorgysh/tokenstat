// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
//
// Source-available for review, NOT open source. See LICENSE: no rights to
// redistribute, publish, or ship a build are granted. Read it, study it, run
// your own build of it.
// "tokenstat" is a trademark of pueev OU. See TRADEMARK.md.

import SwiftUI

/// A character left to get on with something.
///
/// Every other use of `PersonaMark` is told what mood to be in, because the
/// conversation knows. Two places do not have that answer and were showing a
/// held pose instead: an empty chat, where nobody has asked for anything yet,
/// and a long wait, where "thinking" is true for a minute and a single loop of
/// it starts to read as a hang.
///
/// So this picks. It holds a quiet mood for a while, does something for a
/// while, and goes back to quiet, with the length of each drawn fresh every
/// time. Nothing is on a schedule you could learn, nothing repeats the same
/// activity twice in a row, and two people looking at the same screen are not
/// watching the same loop.
struct PersonaPastime: View {
    /// What a character has to choose from.
    enum Repertoire {
        /// Nobody has asked for anything. It reads, it plays, it bounces off
        /// the walls, and every so often it gives up and has a nap.
        case leisure
        /// It is working on an answer. Turning it over on the spot, or
        /// walking the floor, which is the same thought in a different shape.
        case thought

        var quiet: PersonaMood {
            switch self {
            case .leisure: return .idle
            case .thought: return .thinking
            }
        }

        var activities: [PersonaMood] {
            switch self {
            case .leisure: return [.bouncing, .reading, .gaming, .dancing, .juggling, .pacing]
            case .thought: return [.pacing, .thinking]
            }
        }

        /// How long it stays quiet before finding something to do.
        var quietFor: ClosedRange<Double> {
            switch self {
            case .leisure: return 2.6...5.4
            case .thought: return 4.0...7.5
            }
        }

        /// How long an activity lasts. Long enough to be read as that
        /// activity, short enough that nobody watches the loop come round.
        var busyFor: ClosedRange<Double> {
            switch self {
            case .leisure: return 6.0...12.0
            case .thought: return 5.0...9.0
            }
        }

        /// Odds of a nap instead of an activity, and how long it lasts.
        var naps: Bool { self == .leisure }

        /// Whether the first thing it does is an activity rather than a wait.
        ///
        /// An empty screen should be interesting the moment it appears, so
        /// leisure opens on something. A wait must not: `.thought` starts as
        /// thinking because that is what is actually true when the seat
        /// appears, and anything else would be the picture lying about the
        /// state of the turn.
        var opensBusy: Bool { self == .leisure }
    }

    var seed: UInt64
    var size: CGFloat = 96
    var doing: Repertoire = .leisure
    var pokeable = true

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var mood: PersonaMood = .idle

    var body: some View {
        PersonaMark(seed: seed, size: size, state: mood, pokeable: pokeable)
            .task(id: reduceMotion) { await live() }
    }

    private func live() async {
        mood = doing.quiet
        // With motion off there is nothing to schedule: the mark draws the
        // resting pose of whatever it is holding, and a timer swapping between
        // resting poses would be the flicker Reduce Motion asks us not to
        // make.
        guard !reduceMotion else { return }
        var last: PersonaMood?
        var first = doing.opensBusy
        while !Task.isCancelled {
            if first {
                // A short beat, so the character is seen arriving rather than
                // already mid-activity when the screen fades in.
                first = false
                try? await Task.sleep(for: .milliseconds(700))
            } else {
                try? await Task.sleep(for: .seconds(Double.random(in: doing.quietFor)))
            }
            guard !Task.isCancelled else { return }

            let next: PersonaMood
            if doing.naps, Double.random(in: 0...1) < 0.12 {
                next = .sleeping
            } else {
                // Never the same thing twice running. One repeat is a
                // coincidence to a person watching, two is a loop.
                let choices = doing.activities.filter { $0 != last }
                next = choices.randomElement() ?? doing.quiet
            }
            last = next
            mood = next

            let span = next == .sleeping ? Double.random(in: 7...14) : Double.random(in: doing.busyFor)
            try? await Task.sleep(for: .seconds(span))
            guard !Task.isCancelled else { return }
            mood = doing.quiet
        }
    }
}
