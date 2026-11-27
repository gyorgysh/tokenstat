// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
//
// Source-available: source sharing and own builds are permitted.
// Store and commercial distribution of builds is reserved. See LICENSE.
// "tokenstat" is a trademark of pueev OU. See TRADEMARK.md.

import SwiftUI

enum GettingStartedState {
    case done
    case now
    case next
}

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

    private func connector(_ state: GettingStartedState) -> LinearGradient {
        let top = state == .done ? Theme.accent.opacity(0.5) : Theme.border
        return LinearGradient(
            colors: [top, top.opacity(0.25)],
            startPoint: .top,
            endPoint: .bottom
        )
    }
}

private struct GettingStartedDisc: View {
    let number: Int
    let state: GettingStartedState

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var pulsing = false

    var body: some View {
        ZStack {
            if state == .now {
                Circle()
                    .fill(Theme.accent.opacity(0.16))
                    .frame(width: 30, height: 30)
                    .animation(pulsing ? .easeOut(duration: 1.8).repeatForever(autoreverses: false) : nil) {
                        $0.scaleEffect(pulsing ? 1.42 : 1).opacity(pulsing ? 0 : 1)
                    }
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
            pulsing = true
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

struct GettingStartedGhostGrid: View {
    var weeks: Int = 18
    var alignment: Alignment = .leading

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private let rows = 7
    private let cell: CGFloat = 9
    private let gap: CGFloat = 3
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
        .frame(maxWidth: .infinity, alignment: alignment)
    }

    private static func phase(at date: Date) -> Double {
        let seconds = date.timeIntervalSinceReferenceDate
        return (seconds.truncatingRemainder(dividingBy: period)) / period
    }

    private func level(row: Int, week: Int, phase: Double) -> Double {
        let floor = 0.08
        guard !reduceMotion else { return floor }
        let position = Double(week) / Double(max(weeks - 1, 1))
        var distance = abs(position - phase)
        distance = min(distance, 1 - distance)
        let band = max(0, 1 - distance * 5)
        let jitter = Double((row &* 7 &+ week &* 13) % 5) / 10
        return floor + band * (0.25 + jitter)
    }
}
