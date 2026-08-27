// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
//
// Source-available for review, NOT open source. See LICENSE: no rights to
// redistribute, publish, or ship a build are granted. Read it, study it, run
// your own build of it.
// "tokenstat" is a trademark of pueev OU. See TRADEMARK.md.

import SwiftUI

/// Where a step sits in a rail somebody is walking.
///
/// Three states and no fourth: a step is behind you, in front of you, or the
/// one to do now. "Skipped" is not a state, because a rail that can be skipped
/// is a list with numbers painted on it.
enum GettingStartedState {
    case done
    case now
    case next
}

/// One step, and what it offers.
///
/// The action is part of the step rather than something the caller draws under
/// the rail, because a step whose instruction is the name of another screen is
/// the thing this replaces. If there is something to do, the button doing it
/// belongs on the line that asks for it.
struct GettingStartedStep: Identifiable {
    let number: Int
    let title: String
    let body: String
    let state: GettingStartedState
    var actionTitle: String?
    var actionIcon: ActionIcon = .next
    var action: (() -> Void)?

    var id: Int { number }
}

/// The numbered rail a new account walks: one line, one live step, the rest
/// ahead or struck behind.
///
/// The same shape the website's getting-started card uses, for the same reason:
/// somebody who leaves and comes back should find the page they left with one
/// more step behind them, not a different screen with different words. Drawn in
/// the app's own accent rather than in a grey panel, because a screen that is
/// empty is exactly the screen that should look like the product.
///
/// The connector is drawn on the step and not between two of them, so a step
/// can be any height and the line still reaches the next disc.
struct GettingStartedRail: View {
    let steps: [GettingStartedStep]

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(steps) { step in
                row(step, isLast: step.id == steps.last?.id)
            }
        }
    }

    private func row(_ step: GettingStartedStep, isLast: Bool) -> some View {
        HStack(alignment: .top, spacing: Theme.Space.m) {
            VStack(spacing: 0) {
                GettingStartedDisc(number: step.number, state: step.state)
                if !isLast {
                    // Below the disc rather than beside it, so the line starts
                    // where the circle ends whatever the row above is doing.
                    Capsule()
                        .fill(connector(step.state))
                        .frame(width: 2)
                        .frame(maxHeight: .infinity)
                        .padding(.vertical, 4)
                }
            }
            .frame(width: 30)

            VStack(alignment: .leading, spacing: Theme.Space.xs) {
                Text(step.title)
                    .font(Theme.headline)
                    .foregroundStyle(step.state == .done ? Color.secondary : Color.primary)
                Text(step.body)
                    .font(Theme.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: 420, alignment: .leading)
                if let actionTitle = step.actionTitle, let action = step.action {
                    stepButton(actionTitle, step.actionIcon, action)
                        .padding(.top, Theme.Space.xs)
                }
            }
            .padding(.bottom, isLast ? 0 : Theme.Space.l)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .accessibilityElement(children: .combine)
    }

    /// The prominent button each platform already uses everywhere else. The
    /// phone's is the glass capsule from `GlassChrome`, the Mac's is the
    /// system's, and neither is worth a third variant invented here.
    @ViewBuilder
    private func stepButton(
        _ title: String,
        _ icon: ActionIcon,
        _ action: @escaping () -> Void
    ) -> some View {
        #if os(macOS)
        Button(title, icon, action: action)
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .tint(Theme.accent)
        #else
        Button(title, icon, action: action)
            .labelStyle(ActionLabelStyle())
            .clientProminentStyle()
            .controlSize(.large)
            .tint(Theme.accent)
        #endif
    }

    /// A finished stretch of the line reads finished. The rest is the same
    /// border every card uses, fading out so it does not end in a hard stop.
    private func connector(_ state: GettingStartedState) -> LinearGradient {
        let top = state == .done ? Theme.accent.opacity(0.5) : Theme.border
        return LinearGradient(
            colors: [top, top.opacity(0.25)],
            startPoint: .top,
            endPoint: .bottom
        )
    }
}

/// The circle carrying the step number, or a check once the step is behind.
private struct GettingStartedDisc: View {
    let number: Int
    let state: GettingStartedState

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var pulsing = false

    var body: some View {
        ZStack {
            // The live step gets a halo. It is the one thing on the card that
            // should catch the eye first, and a ring costs nothing next to
            // making the disc itself louder than the title beside it.
            if state == .now {
                Circle()
                    .fill(Theme.accent.opacity(0.16))
                    .frame(width: 30, height: 30)
                    .scaleEffect(reduceMotion || !pulsing ? 1 : 1.42)
                    .opacity(reduceMotion || !pulsing ? 1 : 0)
            }
            Circle()
                .fill(fill)
                .overlay { Circle().strokeBorder(stroke, lineWidth: 1) }
                .frame(width: 26, height: 26)
            label
        }
        .frame(width: 30, height: 30)
        .onAppear {
            guard !reduceMotion, state == .now else { return }
            withAnimation(.easeOut(duration: 1.8).repeatForever(autoreverses: false)) {
                pulsing = true
            }
        }
    }

    @ViewBuilder
    private var label: some View {
        switch state {
        case .done:
            Image(systemName: "checkmark")
                .font(Theme.font(12, weight: .bold, relativeTo: .caption))
                .foregroundStyle(Color.white)
        case .now:
            Text("\(number)")
                .font(Theme.monoText(11, weight: .bold))
                .foregroundStyle(Color.white)
        case .next:
            Text("\(number)")
                .font(Theme.monoText(11, weight: .bold))
                .foregroundStyle(.secondary)
        }
    }

    private var fill: Color {
        switch state {
        case .done, .now: return Theme.accent
        case .next: return Theme.accentSoft
        }
    }

    private var stroke: Color {
        state == .next ? Theme.border : .clear
    }
}

/// The grid that is not there yet, drawn where it will be.
///
/// The strongest thing on the website's card, and the reason is that it is not
/// decoration: it is the shape of the answer, so waiting for the first scan
/// looks like waiting for something specific rather than like a screen that
/// failed to load. Cells light in a wave across the weeks and fade, which is
/// roughly what a real first sync looks like arriving.
struct GettingStartedGhostGrid: View {
    /// How many weeks wide. The Mac has room for a season, a phone does not.
    var weeks: Int = 18

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private let rows = 7
    private let cell: CGFloat = 9
    private let gap: CGFloat = 3
    /// One pass of the band, in seconds.
    private static let period: Double = 3.4

    var body: some View {
        // A timeline and not `withAnimation`, because the band is not a
        // transition between two states. Animating a phase that is only read
        // inside a computed opacity makes SwiftUI interpolate every cell from
        // its start value to its end value at once, which is a whole-grid
        // pulse rather than something travelling across the weeks.
        TimelineView(.animation(minimumInterval: 1 / 30, paused: reduceMotion)) { context in
            let phase = reduceMotion ? 0 : Self.phase(at: context.date)
            grid(phase: phase)
        }
        .accessibilityHidden(true)
    }

    private func grid(phase: Double) -> some View {
        VStack(alignment: .leading, spacing: gap) {
            ForEach(0..<rows, id: \.self) { row in
                HStack(spacing: gap) {
                    ForEach(0..<weeks, id: \.self) { week in
                        RoundedRectangle(cornerRadius: 2, style: .continuous)
                            .fill(Theme.accent.opacity(level(row: row, week: week, phase: phase)))
                            .frame(width: cell, height: cell)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// Where the band is, as a fraction of the width, from the wall clock. Time
    /// rather than stored state, so the loop cannot drift and nothing has to be
    /// restarted when the view is rebuilt.
    private static func phase(at date: Date) -> Double {
        let seconds = date.timeIntervalSinceReferenceDate
        return (seconds.truncatingRemainder(dividingBy: period)) / period
    }

    /// A soft band over a floor of empty cells. The per-cell jitter keeps it
    /// from reading as a scanning bar: a real week is not one brightness.
    private func level(row: Int, week: Int, phase: Double) -> Double {
        let floor = 0.08
        guard !reduceMotion else { return floor }
        let position = Double(week) / Double(max(weeks - 1, 1))
        // Wrapped distance, so the band leaves the right edge and arrives at
        // the left one rather than jumping back through the middle.
        var distance = abs(position - phase)
        distance = min(distance, 1 - distance)
        let band = max(0, 1 - distance * 5)
        let jitter = Double((row &* 7 &+ week &* 13) % 5) / 10
        return floor + band * (0.25 + jitter)
    }
}
