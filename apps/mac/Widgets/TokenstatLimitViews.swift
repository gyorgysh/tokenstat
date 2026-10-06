// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
import SwiftUI
import WidgetKit

struct TokenstatLimitRingView: View {
    let provider: EcosystemLimitProvider
    var date: Date = .now
    var accent: Color
    var diameter: CGFloat = 68
    var selectedWindow: EcosystemLimitWindow?
    var usesSelectedWindow = false
    private var window: EcosystemLimitWindow? { usesSelectedWindow ? selectedWindow : provider.peak(at: date) ?? provider.windows.first }
    var body: some View {
        VStack(spacing: diameter < 30 ? 2 : 4) {
            ZStack {
                Circle().stroke(.primary.opacity(0.12), lineWidth: 5)
                if let window, !window.expired(at: date) {
                    Circle().trim(from: 0, to: window.fraction).stroke(TokenstatLimitColor.color(window.percent, accent: accent), style: StrokeStyle(lineWidth: 5, lineCap: .round))
                        .rotationEffect(.degrees(-90)).widgetAccentable()
                }
                Text(window.flatMap { $0.expired(at: date) ? nil : "\(Int($0.percent.rounded()))%" } ?? "—")
                    .font(.system(size: diameter < 50 ? 13 : 19, weight: .semibold, design: .rounded))
                    .monospacedDigit().minimumScaleFactor(0.6).lineLimit(1)
                    .contentTransition(.numericText()).invalidatableContent()
            }.frame(width: diameter, height: diameter).accessibilityHidden(true)
            Text(diameter <= 43 && usesSelectedWindow ? "\(provider.name) · \(window?.compactLabel ?? "—")" : provider.name)
                .font(diameter <= 43 ? .caption2.weight(.medium) : .caption.weight(.medium)).lineLimit(1).minimumScaleFactor(0.7)
            if diameter > 43 { Text(window?.compactLabel ?? "No reading").font(.caption2).foregroundStyle(.secondary).lineLimit(1) }
            if diameter >= 65 {
                if let window, window.expired(at: date) {
                    Text("Refresh after reset").font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                } else if let reset = window?.resetsAt {
                    Text("Resets \(EcosystemWidgetTime.until(reset, at: date))").font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            if diameter >= 65 { Text(EcosystemWidgetTime.age(provider.observedAt, at: date)).font(.caption2).foregroundStyle(.secondary).lineLimit(1) }
        }.privacySensitive().accessibilityElement(children: .combine)
            .accessibilityLabel("\(provider.name), \(window?.label ?? "no window"), \(window.flatMap { $0.expired(at: date) ? nil : "\(Int($0.percent.rounded())) percent used" } ?? "refresh to check"), observed \(provider.observedAt.formatted())")
    }
}

struct TokenstatLimitReadingView: View {
    let provider: EcosystemLimitProvider
    var date: Date = .now
    var accent: Color
    var maximumWindows = 2
    var showsFreshness = true
    var selectedWindows: [EcosystemLimitWindow]?
    var showsResetDetails = true

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(provider.name).font(.system(.headline, design: .rounded)).lineLimit(1)
            if (selectedWindows ?? provider.windows).isEmpty {
                Text("No reading shared").font(.caption2).foregroundStyle(.secondary)
            }
            ForEach(Array((selectedWindows ?? provider.windows.sorted { left, right in
                if left.expired(at: date) != right.expired(at: date) { return !left.expired(at: date) }
                return left.percent > right.percent
            }).prefix(maximumWindows))) { window in
                VStack(alignment: .leading, spacing: 3) {
                    HStack(alignment: .firstTextBaseline, spacing: 4) {
                        Text(window.compactLabel).font(.caption2).lineLimit(1)
                        Spacer(minLength: 0)
                        Text(window.expired(at: date) ? "—" : "\(Int(window.percent.rounded()))%")
                            .font(.system(.caption, design: .rounded, weight: .semibold)).monospacedDigit()
                            .contentTransition(.numericText()).invalidatableContent()
                    }
                    GeometryReader { geometry in
                        ZStack(alignment: .leading) {
                            Capsule().fill(.primary.opacity(0.12))
                            if !window.expired(at: date) {
                                Capsule().fill(TokenstatLimitColor.color(window.percent, accent: accent))
                                    .frame(width: geometry.size.width * window.fraction).widgetAccentable()
                            }
                        }
                    }.frame(height: 5).accessibilityHidden(true)
                    if window.expired(at: date) && showsResetDetails {
                        Text("Reset passed · Refresh").font(.caption2).foregroundStyle(.secondary)
                    } else if showsResetDetails, let reset = window.resetsAt {
                        Text("Resets \(EcosystemWidgetTime.until(reset, at: date))").font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                    }
                }.accessibilityElement(children: .combine)
                    .accessibilityLabel(window.expired(at: date) ? "\(window.label): reset passed, refresh to check" : "\(window.label): \(Int(window.percent.rounded())) percent used")
            }
            if showsFreshness {
                Text(EcosystemWidgetTime.age(provider.observedAt, at: date))
                    .font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                    .accessibilityLabel("Last shared \(provider.observedAt.formatted()), \(provider.isStale(at: date) ? "older reading" : "recent reading")")
            }
        }.privacySensitive()
    }
}

enum TokenstatLimitColor {
    static func color(_ percent: Double, accent: Color) -> Color {
        percent >= 100 ? .red : percent >= 85 ? .orange : accent
    }
}
