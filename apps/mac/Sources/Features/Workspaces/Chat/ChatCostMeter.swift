// SPDX-License-Identifier: LicenseRef-tokenstat-source-available

import SwiftUI

/// Folded usage for one conversation: every `Usage` event added together.
///
/// Counted by the host over the whole archive rather than by the client over
/// what it happens to hold, because a conversation is read a page at a time
/// and a total that climbed as somebody scrolled backwards would be wrong in
/// every position but one.
struct ChatUsageTotals: Codable, Equatable, Sendable {
    var input: UInt64
    var output: UInt64
    var cacheRead: UInt64
    var cacheWrite: UInt64
    var cost: Double

    var cache: UInt64 { cacheRead + cacheWrite }
    var isEmpty: Bool { input == 0 && output == 0 && cache == 0 && cost == 0 }

    static let zero = ChatUsageTotals(
        input: 0, output: 0, cacheRead: 0, cacheWrite: 0, cost: 0
    )
}

/// Quiet token and cost card for the inspector and the phone setup sheet.
///
/// In and out share one bar so the split is visible without a table. Cost
/// only appears when a figure is actually known, so a plan-covered turn is
/// not drawn as money charged.
struct ChatCostMeter: View {
    let totals: ChatUsageTotals?

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.s) {
            Text("This conversation")
                .font(Theme.caption)
                .foregroundStyle(.tertiary)
            if let totals {
                TokenSplitBar(input: totals.input, output: totals.output)
                HStack(spacing: Theme.Space.m) {
                    legend(color: Theme.accent, title: "In", value: totals.input)
                    legend(color: Theme.secondary, title: "Out", value: totals.output)
                    Spacer(minLength: 0)
                    if totals.cost > 0 {
                        Text(totals.cost, format: .currency(code: "USD").precision(.fractionLength(2...4)))
                            .font(Theme.callout.weight(.semibold))
                            .foregroundStyle(Theme.accent)
                            .monospacedDigit()
                    }
                }
                if totals.cache > 0 {
                    Text("\(totals.cache.formatted()) cached")
                        .font(Theme.caption)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
            } else {
                Text("Tokens and cost show up after a turn.")
                    .font(Theme.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(Theme.Space.m)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.panel, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(Theme.border, lineWidth: 1)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(label)
    }

    private func legend(color: Color, title: String, value: UInt64) -> some View {
        HStack(spacing: 6) {
            Capsule()
                .fill(color)
                .frame(width: 8, height: 8)
            Text(title)
                .font(Theme.caption)
                .foregroundStyle(.secondary)
            Text(value.formatted())
                .font(Theme.caption.weight(.medium).monospacedDigit())
                .foregroundStyle(.primary)
        }
    }

    private var label: String {
        guard let totals else {
            return "This conversation, no tokens yet"
        }
        var parts = [
            "This conversation",
            "\(totals.input.formatted()) in",
            "\(totals.output.formatted()) out",
        ]
        if totals.cache > 0 {
            parts.append("\(totals.cache.formatted()) cached")
        }
        if totals.cost > 0 {
            parts.append(totals.cost.formatted(.currency(code: "USD").precision(.fractionLength(2...4))))
        }
        return parts.joined(separator: ", ")
    }
}

/// In versus out, as a single capsule. Empty stays a quiet track.
private struct TokenSplitBar: View {
    let input: UInt64
    let output: UInt64

    var body: some View {
        GeometryReader { geo in
            let total = input + output
            Capsule()
                .fill(Theme.accentSoft)
                .overlay {
                    if total > 0 {
                        let inWidth = geo.size.width * CGFloat(input) / CGFloat(total)
                        HStack(spacing: 0) {
                            Rectangle()
                                .fill(Theme.accent)
                                .frame(width: inWidth)
                            Rectangle()
                                .fill(Theme.secondary)
                        }
                        .clipShape(Capsule())
                    }
                }
        }
        .frame(height: 6)
        .accessibilityHidden(true)
    }
}
