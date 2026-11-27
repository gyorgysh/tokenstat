// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
//
// Source-available: source sharing and own builds are permitted.
// Store and commercial distribution of builds is reserved. See LICENSE.
// "tokenstat" is a trademark of pueev OU. See TRADEMARK.md.

import SwiftUI

struct CadenceGlyph: View {
    var schedule: AutomationSchedule
    var enabled: Bool = true
    var size: CGFloat = 22
    var summary: String = ""

    private var tint: Color { enabled ? Theme.accent : Theme.stateIdle }

    var body: some View {
        content
            .frame(width: size, height: size)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(summary.isEmpty ? schedule.kind.label : summary)
            .help(summary.isEmpty ? schedule.kind.label : summary)
    }

    @ViewBuilder
    private var content: some View {
        switch schedule.kind {
        case .once:
            symbol("play.circle")
        case .interval:
            symbol("arrow.triangle.2.circlepath")
        case .daily, .weekdays, .weekly, .custom:
            weekRing
        }
    }

    private func symbol(_ name: String) -> some View {
        Image(systemName: name)
            .font(Theme.fixed(size * 0.82, weight: .regular))
            .foregroundStyle(tint)
    }

    private var weekRing: some View {
        let dot = max(3, size * 0.19)
        let radius = (size - dot) / 2
        return ZStack {
            Circle()
                .strokeBorder(Theme.border, lineWidth: 1)
            ForEach(0..<7, id: \.self) { day in
                Circle()
                    .fill(fires(on: day) ? tint : Theme.stateIdle.opacity(0.28))
                    .frame(width: dot, height: dot)
                    .offset(
                        x: radius * sin(Double(day) / 7 * 2 * .pi),
                        y: -radius * cos(Double(day) / 7 * 2 * .pi)
                    )
            }
        }
    }

    private func fires(on day: Int) -> Bool {
        switch schedule.kind {
        case .daily:
            return true
        case .weekdays:
            return day < 5
        case .weekly:
            if schedule.weekdays & 0b0111_1111 != 0 {
                return schedule.weekdays & (1 << day) != 0
            }
            return day == schedule.weekday
        case .custom:
            return schedule.weekdays & (1 << day) != 0
        case .once, .interval:
            return false
        }
    }
}

struct CountdownRing: View {
    var start: Date?
    var end: Date
    var size: CGFloat = 18
    var lineWidth: CGFloat = 2.5

    var body: some View {
        let words = RelativeClock.phrase(for: end, style: .abbreviated)
        return ZStack {
            Circle()
                .strokeBorder(Theme.border, lineWidth: lineWidth)
            Circle()
                .trim(from: 0, to: fraction)
                .stroke(Theme.accent, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                .rotationEffect(.degrees(-90))
                .padding(lineWidth / 2)
        }
        .frame(width: size, height: size)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(L10n.text("apple.cadenceglyph.next_run_0.64198a42", "\(words)"))
        .help(L10n.text("apple.cadenceglyph.next_run_0.64198a42", "\(words)"))
    }

    private var fraction: Double {
        guard let start else { return 0 }
        let total = end.timeIntervalSince(start)
        guard total > 0 else { return 1 }
        let done = Date().timeIntervalSince(start)
        return min(1, max(0, done / total))
    }
}

struct NextRunBadge: View {
    var start: Date?
    var end: Date

    var body: some View {
        HStack(spacing: Theme.Space.xs) {
            CountdownRing(start: start, end: end)
            Text(RelativeClock.phrase(for: end, style: .abbreviated))
                .font(Theme.caption)
                .foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .combine)
    }
}

struct SlotGauge: View {
    var filled: Int
    var total: Int
    var uncapped: Bool = false
    var tile: CGFloat = 10

    private static let maxTiles = 12

    private var drawn: Int {
        min(max(total, 1), Self.maxTiles)
    }

    var body: some View {
        HStack(spacing: 3) {
            if uncapped {
                Text(L10n.text("apple.cadenceglyph.no_cap.59db2115"))
                    .font(Theme.caption)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(0..<drawn, id: \.self) { index in
                    RoundedRectangle(cornerRadius: 3, style: .continuous)
                        .fill(index < filled ? Theme.accent : Theme.border)
                        .frame(width: tile, height: tile)
                }
                if total > drawn {
                    Text("+\(total - drawn)")
                        .font(Theme.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(label)
        .help(label)
    }

    private var label: String {
        if uncapped { return L10n.text("apple.cadenceglyph.no_limit_on_jobs_at_once.76b43c57") }
        return L10n.text("apple.cadenceglyph.0_of_1_slots_busy.2b6c328d", "\(filled)", "\(total)")
    }
}

