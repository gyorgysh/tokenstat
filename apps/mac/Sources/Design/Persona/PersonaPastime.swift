// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
//
// Source-available: source sharing and own builds are permitted.
// Store and commercial distribution of builds is reserved. See LICENSE.
// "tokenstat" is a trademark of pueev OU. See TRADEMARK.md.

import SwiftUI

struct PersonaPastime: View {
    enum Repertoire: Hashable {
        case leisure
        case thought

        var quiet: PersonaMood {
            switch self {
            case .leisure: return .idle
            case .thought: return .thinking
            }
        }

        var activities: [PersonaMood] {
            switch self {
            case .leisure: return [
                .bouncing, .reading, .gaming, .dancing, .juggling, .pacing,
                .typing, .sipping, .sketching, .stargazing, .gardening,
                .bubbling, .snacking
            ]
            case .thought: return [.pacing, .thinking]
            }
        }

        var quietFor: ClosedRange<Double> {
            switch self {
            case .leisure: return 2.6...5.4
            case .thought: return 1.2...2.4
            }
        }

        var tellings: ClosedRange<Int> {
            switch self {
            case .leisure: return 1...2
            case .thought: return 1...1
            }
        }

        var busyFor: ClosedRange<Double> {
            switch self {
            case .leisure: return 5.5...20.0
            case .thought: return 5.0...11.0
            }
        }

        var naps: Bool { self == .leisure }

        func span(for mood: PersonaMood) -> Double {
            let story = mood.storyLength
            guard story > 0 else { return Double.random(in: busyFor) }
            let least = max(tellings.lowerBound, Int(ceil(busyFor.lowerBound / story)))
            let most = min(tellings.upperBound, Int(floor(busyFor.upperBound / story)))
            guard least <= most else {
                return story
            }
            return story * Double(Int.random(in: least...most))
        }

        var opensBusy: Bool { self == .leisure }
    }

    var seed: UInt64
    var size: CGFloat = 96
    var doing: Repertoire = .leisure
    var pokeable = true

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.personaMotionAllowed) private var paneAllowsMotion
    @Environment(\.isWindowLiveResizing) private var isLiveResizing
    #if os(macOS)
    @Environment(\.controlActiveState) private var controlActiveState
    #endif
    @State private var mood: PersonaMood

    init(seed: UInt64, size: CGFloat = 96, doing: Repertoire = .leisure, pokeable: Bool = true) {
        self.seed = seed
        self.size = size
        self.doing = doing
        self.pokeable = pokeable
        _mood = State(initialValue: doing.quiet)
    }

    private var canAnimate: Bool {
        guard !reduceMotion, paneAllowsMotion, !isLiveResizing, scenePhase == .active else { return false }
        #if os(macOS)
        guard controlActiveState == .key else { return false }
        #endif
        return true
    }

    private struct MotionTaskID: Hashable {
        let moving: Bool
        let repertoire: Repertoire
    }

    var body: some View {
        PersonaMark(seed: seed, size: size, state: mood, pokeable: pokeable)
            .task(id: MotionTaskID(moving: canAnimate, repertoire: doing)) {
                mood = doing.quiet
                if canAnimate { await live() }
            }
    }

    private func live() async {
        guard canAnimate else { return }
        var last: PersonaMood?
        var first = doing.opensBusy
        while !Task.isCancelled {
            if first {
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
                let choices = doing.activities.filter { $0 != last }
                next = choices.randomElement() ?? doing.quiet
            }
            last = next
            mood = next

            let span = next == .sleeping
                ? Double.random(in: 7...14)
                : doing.span(for: next)
            try? await Task.sleep(for: .seconds(span))
            guard !Task.isCancelled else { return }
            mood = doing.quiet
        }
    }
}
