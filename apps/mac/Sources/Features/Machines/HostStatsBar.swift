// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
//
// Source-available: source sharing and own builds are permitted.
// Store and commercial distribution of builds is reserved. See LICENSE.
// "tokenstat" is a trademark of pueev OU. See TRADEMARK.md.

import SwiftUI

enum HostStatsFormat {
    static func powerSymbol(_ stats: HostStats?) -> String {
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

    static func powerLabel(_ stats: HostStats?, failed: Bool) -> String {
        if failed, stats == nil { return L10n.text("apple.hoststatsbar.n_a.a683c5c5") }
        guard let stats else { return L10n.text("apple.hoststatsbar..b4935894") }
        if stats.charging == true, let percent = stats.percent { return "\(percent)%" }
        if stats.power == "ac", stats.percent == nil { return L10n.text("apple.hoststatsbar.plugged_in.edefc1f9") }
        if let percent = stats.percent { return "\(percent)%" }
        if stats.power == "battery" { return L10n.text("apple.hoststatsbar.on_battery.51d53044") }
        if stats.power == "ac" { return L10n.text("apple.hoststatsbar.plugged_in.edefc1f9") }
        return L10n.text("apple.hoststatsbar.n_a.a683c5c5")
    }

    static let ramExplanation = L10n.text("apple.hoststatsbar.memory_in_use_by_apps_wired_and_compressed.d6cddcc1")

    static func ramLabel(used: UInt64, total: UInt64) -> String {
        let g = 1024.0 * 1024 * 1024
        let u = Double(used) / g
        let t = Double(total) / g
        if t >= 10 { return String(format: "%.0f / %.0f GB", u, t) }
        return String(format: "%.1f / %.1f GB", u, t)
    }

    static func cpuLabel(_ cpu: Double) -> String {
        guard cpu.isFinite else { return L10n.text("apple.hoststatsbar.n_a.a683c5c5") }
        return "\(Int((min(1, max(0, cpu)) * 100).rounded()))%"
    }

    @MainActor
    static func loadRoute(for peer: String) async -> String? {
        let traffic = await ConnectionRoutes.shared.traffic()
        return traffic?.peers.first { $0.peer.caseInsensitiveCompare(peer) == .orderedSame }?.route
    }
}

@MainActor
final class ConnectionRoutes {
    static let shared = ConnectionRoutes()

    private static let freshFor: TimeInterval = 2
    private var cached: RemoteTraffic?
    private var readAt = Date.distantPast
    private var inFlight: Task<RemoteTraffic?, Never>?

    func traffic() async -> RemoteTraffic? {
        if let cached, Date().timeIntervalSince(readAt) < Self.freshFor { return cached }
        if let inFlight { return await inFlight.value }
        let task = Task { @MainActor in try? await Bridge.remoteStatus().traffic }
        inFlight = task
        let answer = await task.value
        inFlight = nil
        if let answer {
            cached = answer
            readAt = Date()
        }
        return answer
    }
}

struct ConnectionRouteMark: View {
    let route: String?

    var body: some View {
        if let label = RemoteTrafficPeer.knownLabel(route) {
            HStack(spacing: 6) {
                Circle()
                    .fill(route == "direct" ? Theme.success : Theme.warning)
                    .frame(width: 7, height: 7)
                    .accessibilityHidden(true)
                Text(label)
            }
            .accessibilityElement(children: .combine)
        }
    }
}

struct HostStatsBar: View {
    var peer: String? = nil
    var online: Bool = true
    var local: Bool = false

    @State private var stats: HostStats?
    @State private var failed = false
    @State private var route: String?

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.s) {
            HStack(spacing: Theme.Space.m) {
                powerCell
                cpuCell
                ramCell
            }
            .frame(minHeight: 44)
            if !local {
                ConnectionRouteMark(route: route)
                    .font(Theme.caption)
                    .foregroundStyle(.secondary)
            }
            Text(local
                ? L10n.text("apple.hoststatsbar.sampled_on_this_machine_not_uploaded_with.122c8f2c")
                : L10n.text("apple.hoststatsbar.read_from_this_computer_over_the_encrypted.2e1e5e7b"))
                .font(Theme.caption)
                .foregroundStyle(.tertiary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(Theme.Space.m)
        .machineCardSurface()
        .accessibilityElement(children: .combine)
        .task(id: "\(peer ?? "local")-\(online)-\(local)") {
            stats = nil
            route = nil
            failed = false
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
            Text(L10n.text("apple.hoststatsbar.power.848e9656"))
                .font(Theme.caption)
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
                    Text(HostStatsFormat.cpuLabel(cpu))
                        .font(statFont)
                        .monospacedDigit()
                }
            } else {
                Text(L10n.text("apple.hoststatsbar.n_a.a683c5c5"))
                    .font(statFont)
                    .foregroundStyle(.tertiary)
            }
            Text(L10n.text("apple.hoststatsbar.cpu.db9a4c7d"))
                .font(Theme.caption)
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
                Text(L10n.text("apple.hoststatsbar.n_a.a683c5c5"))
                    .font(statFont)
                    .foregroundStyle(.tertiary)
            }
            Text(L10n.text("apple.hoststatsbar.memory.c3963aed"))
                .font(Theme.caption)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .help(HostStatsFormat.ramExplanation)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(ramVoiceOver)
    }

    private var ramVoiceOver: String {
        guard let used = stats?.ramUsedBytes, let total = stats?.ramTotalBytes, total > 0 else {
            return L10n.text("apple.hoststatsbar.memory_not_available.2fe84030")
        }
        return L10n.text("apple.hoststatsbar.memory_0_used_1.e0f0e4c2", "\(HostStatsFormat.ramLabel(used: used, total: total))", "\(HostStatsFormat.ramExplanation)")
    }

    private var statFont: Font {
        #if os(macOS)
        return Theme.numeric(12, weight: .semibold)
        #else
        return ClientType.rowFigure
        #endif
    }

    private var powerSymbol: String { HostStatsFormat.powerSymbol(stats) }

    private var powerLabel: String { HostStatsFormat.powerLabel(stats, failed: failed) }

    private func ramLabel(used: UInt64, total: UInt64) -> String {
        HostStatsFormat.ramLabel(used: used, total: total)
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
        let peerAtStart = peer
        var fresh: HostStats?
        var didFail = false
        do {
            if local {
                fresh = try await Bridge.hostStats()
            } else if let peer {
                fresh = try await Bridge.hostStats(peer: peer)
            }
        } catch {
            didFail = true
        }
        guard !Task.isCancelled, peer == peerAtStart else { return }
        if let fresh { stats = fresh }
        failed = didFail
        if local {
            route = nil
        } else if let peer {
            let freshRoute = await HostStatsFormat.loadRoute(for: peer)
            guard !Task.isCancelled else { return }
            route = freshRoute
        }
    }
}

extension View {
    func machineCardSurface() -> some View {
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

struct HostStatsStrip: View {
    let peer: String
    var online: Bool = true
    var inline: Bool = false

    @State private var stats: HostStats?
    @State private var failed = false
    @State private var route: String?

    var body: some View {
        Group {
            if inline {
                HStack(spacing: Theme.Space.m) {
                    readings
                    ConnectionRouteMark(route: route)
                        .font(Theme.caption)
                        .foregroundStyle(.secondary)
                }
            } else {
                VStack(alignment: .leading, spacing: 4) {
                    readings
                    ConnectionRouteMark(route: route)
                        .font(Theme.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        // An inline strip participates in a toolbar-sized row. Giving it an
        // infinite-width frame makes ViewThatFits treat even a wide Mac pane
        // as too narrow and pushes the readings below the machine name.
        .frame(maxWidth: inline ? nil : .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(voiceOverLabel)
        .task(id: "\(peer)-\(online)") {
            stats = nil
            route = nil
            failed = false
            guard online else { return }
            while !Task.isCancelled {
                await refresh()
                try? await Task.sleep(for: .milliseconds(2500))
            }
        }
    }

    private var readings: some View {
        HStack(spacing: Theme.Space.m) {
            cell(icon: HostStatsFormat.powerSymbol(stats),
                 text: HostStatsFormat.powerLabel(stats, failed: failed))
            if let cpu = stats?.cpu {
                cell(icon: "cpu", text: HostStatsFormat.cpuLabel(cpu))
            }
            if let used = stats?.ramUsedBytes, let total = stats?.ramTotalBytes, total > 0 {
                cell(icon: "memorychip", text: HostStatsFormat.ramLabel(used: used, total: total))
                    .help(HostStatsFormat.ramExplanation)
            }
        }
    }

    private func cell(icon: String, text: String) -> some View {
        HStack(spacing: 4) {
            Image(systemName: icon)
                .font(Theme.caption)
                .foregroundStyle(Theme.accent)
            Text(text)
                .font(Theme.caption)
                .monospacedDigit()
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .fixedSize(horizontal: true, vertical: false)
    }

    private var voiceOverLabel: String {
        var parts = [L10n.text("apple.hoststatsbar.power_0.3aefb7b4", "\(HostStatsFormat.powerLabel(stats, failed: failed))")]
        if let cpu = stats?.cpu { parts.append(L10n.text("apple.hoststatsbar.cpu_0.ceaa5d7d", "\(HostStatsFormat.cpuLabel(cpu))")) }
        if let used = stats?.ramUsedBytes, let total = stats?.ramTotalBytes, total > 0 {
            parts.append(L10n.text("apple.hoststatsbar.memory_0_used_1.e0f0e4c2", "\(HostStatsFormat.ramLabel(used: used, total: total))", "\(HostStatsFormat.ramExplanation)"))
        }
        if let label = RemoteTrafficPeer.knownLabel(route) { parts.append(label) }
        return parts.joined(separator: ", ")
    }

    private func refresh() async {
        let peerAtStart = peer
        var fresh: HostStats?
        var didFail = false
        do {
            fresh = try await Bridge.hostStats(peer: peer)
        } catch {
            didFail = true
        }
        guard !Task.isCancelled, peer == peerAtStart else { return }
        if let fresh { stats = fresh }
        failed = didFail
        let freshRoute = await HostStatsFormat.loadRoute(for: peer)
        guard !Task.isCancelled else { return }
        route = freshRoute
    }
}
