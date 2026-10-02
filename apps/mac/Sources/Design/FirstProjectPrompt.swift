// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
import SwiftUI

/// The same folder and add badge on every client's first-project screen.
struct FirstProjectArt: View {
    var body: some View {
        Canvas { context, _ in
            var folder = Path()
            folder.move(to: CGPoint(x: 24, y: 25))
            for point in [CGPoint(x: 47, y: 25), CGPoint(x: 54, y: 32), CGPoint(x: 100, y: 32),
                          CGPoint(x: 100, y: 70), CGPoint(x: 24, y: 70)] {
                folder.addLine(to: point)
            }
            folder.closeSubpath()
            context.stroke(folder, with: .color(Theme.accent.opacity(0.55)), style: StrokeStyle(lineWidth: 1.7, lineCap: .round, lineJoin: .round))
            var floor = Path()
            floor.move(to: CGPoint(x: 28, y: 77)); floor.addLine(to: CGPoint(x: 102, y: 77))
            context.stroke(floor, with: .color(Theme.border), style: StrokeStyle(lineWidth: 1.7, lineCap: .round, lineJoin: .round))
            let badge = Path(ellipseIn: CGRect(x: 80, y: 48, width: 28, height: 28))
            context.fill(badge, with: .color(Theme.background))
            context.stroke(badge, with: .color(Theme.accent), style: StrokeStyle(lineWidth: 1.7, lineCap: .round, lineJoin: .round))
            var plus = Path()
            plus.move(to: CGPoint(x: 87, y: 62)); plus.addLine(to: CGPoint(x: 101, y: 62))
            plus.move(to: CGPoint(x: 94, y: 55)); plus.addLine(to: CGPoint(x: 94, y: 69))
            context.stroke(plus, with: .color(Theme.accent), style: StrokeStyle(lineWidth: 1.7, lineCap: .round, lineJoin: .round))
        }
        .frame(width: 128, height: 84)
        .accessibilityHidden(true)
    }
}

struct FirstProjectPrompt: View {
    var compact = false
    var onAdd: () -> Void

    var body: some View {
        VStack(spacing: Theme.Space.s) {
            FirstProjectArt()
                .scaleEffect(compact ? 0.75 : 1)
                .frame(height: compact ? 63 : 84)
            Text(L10n.text("common.projects.first_title"))
                .font(Theme.font(compact ? 13 : 24, weight: .semibold))
            Text(L10n.text("common.projects.first_message"))
                .font(Theme.font(compact ? 11 : 14))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Button(L10n.text("common.add_project"), .create, action: onAdd)
                .buttonStyle(AccentButtonStyle(small: true))
        }
        .multilineTextAlignment(.center)
        .frame(maxWidth: compact ? .infinity : 420)
        .padding(compact ? 12 : 24)
    }
}
