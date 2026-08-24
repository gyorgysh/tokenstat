// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
//
// Source-available for review, NOT open source. See LICENSE: no rights to
// redistribute, publish, or ship a build are granted. Read it, study it, run
// your own build of it.
// "tokenstat" is a trademark of pueev OU. See TRADEMARK.md.

import SwiftUI

/// Compact power, CPU and memory for a machine, filled after a tunnel hop.
///
/// Peer set: ask that host. Peer nil: this machine. Offline hosts are not
/// dialled. Missing readings stay off the bar rather than drawing as zero.
struct HostStatsBar: View {
    var peer: String? = nil
    var online: Bool = true
    /// Local sample, used for "this Mac" in the inspector.
    var local: Bool = false

    @State private var stats: HostStats?
    @State private var failed = false

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.s) {
            HStack(spacing: Theme.Space.m) {
                powerCell
                cpuCell
                ramCell
            }
            .frame(minHeight: 44)
            Text(local
                ? "Sampled on this machine. Not uploaded with usage."
                : "Read from this computer over the encrypted tunnel. It is not uploaded with usage.")
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(Theme.Space.m)
        .hostStatsSurface()
        .accessibilityElement(children: .combine)
        .task(id: "\(peer ?? "local")-\(online)-\(local)") {
            guard local || (online && peer != nil) else { return }
            while !Task.isCancelled {
                await refresh()
                try? await Task.sleep(for: .milliseconds(2500))
            }
        }
    }

    @ViewBuilder
    private var powerCell: some View {
        VStack(alignment: .leading, spacing: 2) {
            Label {
                Text(powerLabel)
                    .font(statFont)
                    .monospacedDigit()
            } icon: {
                Image(systemName: powerSymbol)
                    .foregroundStyle(Theme.accent)
            }
            .labelStyle(.titleAndIcon)
            Text("Power")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private var cpuCell: some View {
        VStack(alignment: .leading, spacing: 2) {
            if let cpu = stats?.cpu {
                HStack(spacing: 6) {
                    meter(fraction: cpu)
                    Text("\(Int((cpu * 100).rounded()))%")
                        .font(statFont)
                        .monospacedDigit()
                }
            } else {
                Text("n/a")
                    .font(statFont)
                    .foregroundStyle(.tertiary)
            }
            Text("CPU")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private var ramCell: some View {
        VStack(alignment: .leading, spacing: 2) {
            if let used = stats?.ramUsedBytes, let total = stats?.ramTotalBytes, total > 0 {
                HStack(spacing: 6) {
                    meter(fraction: Double(used) / Double(total))
                    Text(ramLabel(used: used, total: total))
                        .font(statFont)
                        .monospacedDigit()
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)
                }
            } else {
                Text("n/a")
                    .font(statFont)
                    .foregroundStyle(.tertiary)
            }
            Text("Memory")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var statFont: Font {
        #if os(macOS)
        return Theme.numeric(12, weight: .semibold)
        #else
        return ClientType.rowFigure
        #endif
    }

    private var powerSymbol: String {
        if stats?.charging == true { return "battery.100percent.bolt" }
        switch stats?.power {
        case "ac": return "bolt.fill"
        case "battery":
            let p = stats?.percent ?? 100
            if p >= 90 { return "battery.100percent" }
            if p >= 60 { return "battery.75percent" }
            if p >= 35 { return "battery.50percent" }
            if p >= 10 { return "battery.25percent" }
            return "battery.0percent"
        default: return "bolt.slash"
        }
    }

    private var powerLabel: String {
        if failed, stats == nil { return "n/a" }
        if stats == nil { return "…" }
        if stats?.charging == true, let percent = stats?.percent {
            return "\(percent)%"
        }
        if stats?.power == "ac", stats?.percent == nil {
            return "Plugged in"
        }
        if let percent = stats?.percent {
            return "\(percent)%"
        }
        if stats?.power == "battery" { return "On battery" }
        if stats?.power == "ac" { return "Plugged in" }
        return "n/a"
    }

    private func ramLabel(used: UInt64, total: UInt64) -> String {
        let g = 1024.0 * 1024 * 1024
        let u = Double(used) / g
        let t = Double(total) / g
        if t >= 10 {
            return String(format: "%.0f / %.0f GB", u, t)
        }
        return String(format: "%.1f / %.1f GB", u, t)
    }

    private func meter(fraction: Double) -> some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(Theme.accent.opacity(0.12))
                Capsule()
                    .fill(Theme.accent.opacity(0.7))
                    .frame(width: max(2, geo.size.width * min(1, max(0, fraction))))
            }
        }
        .frame(width: 28, height: 6)
        .accessibilityHidden(true)
    }

    private func refresh() async {
        do {
            if local {
                stats = try await Bridge.hostStats()
            } else if let peer {
                stats = try await Bridge.hostStats(peer: peer)
            }
            failed = false
        } catch {
            failed = true
        }
    }
}

private extension View {
    /// Opaque panel on both platforms. `cardSurface` is iOS-only.
    func hostStatsSurface() -> some View {
        #if os(macOS)
        background(Theme.panel, in: RoundedRectangle(cornerRadius: Theme.cardRadius))
            .overlay {
                RoundedRectangle(cornerRadius: Theme.cardRadius)
                    .strokeBorder(Theme.border, lineWidth: 1)
            }
        #else
        cardSurface()
        #endif
    }
}
