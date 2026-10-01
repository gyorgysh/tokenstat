// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
//
// Source-available for review, NOT open source. See LICENSE: no rights to
// redistribute, publish, or ship a build are granted. Read it, study it, run
// your own build of it.
// "tokenstat" is a trademark of pueev OU. See TRADEMARK.md.

import SwiftUI

/// How a reading is written, in one place.
///
/// The full bar and the one-line strip say the same thing about the same
/// machine, so a change of wording cannot land on one and miss the other.
/// Missing readings are "n/a" rather than zero: a figure nobody measured is
/// not a machine that is idle.
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

    /// What the memory figure counts, in one line.
    ///
    /// Worth saying out loud. "24 GB" beside a machine with 32 invites the
    /// reading that eight are left and everything else is spoken for, which is
    /// not what any of the three platforms measures: the cache and the
    /// purgeable pages are available and are not in this number.
    static let ramExplanation = L10n.text("apple.hoststatsbar.memory_in_use_by_apps_wired_and_compressed.d6cddcc1")

    static func ramLabel(used: UInt64, total: UInt64) -> String {
        let g = 1024.0 * 1024 * 1024
        let u = Double(used) / g
        let t = Double(total) / g
        if t >= 10 { return String(format: "%.0f / %.0f GB", u, t) }
        return String(format: "%.1f / %.1f GB", u, t)
    }

    static func cpuLabel(_ cpu: Double) -> String {
        "\(Int((cpu * 100).rounded()))%"
    }

    /// Direct vs relay for a live peer, from this device's `remote.status`.
    ///
    /// Missing stays missing. The screen must not invent Encrypted relay
    /// for a path nobody has observed yet.
    @MainActor
    static func loadRoute(for peer: String) async -> String? {
        let traffic = await ConnectionRoutes.shared.traffic()
        return traffic?.peers.first { $0.peer.caseInsensitiveCompare(peer) == .orderedSame }?.route
    }
}

/// One `remote.status` for a screenful of machine rows.
///
/// Every row asks for its own path at the same moment, and the answer is the
/// same list for all of them. The host builds that list under the lock every
/// peer call takes a slot in, so a list of machines used to mean one of those
/// per row. Rows within a couple of seconds of each other share one answer,
/// and a request in flight is joined rather than duplicated.
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

/// The same wording and colours the screen viewer uses, on a machine row.
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
                    Text("\(Int((cpu * 100).rounded()))%")
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
        // The task restarts (and cancels this one) when the peer changes, but
        // a cancelled await still resumes: only publish when this refresh is
        // still the current one, or one peer's answer lands on another's row.
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
            route = await HostStatsFormat.loadRoute(for: peer)
        }
    }
}

extension View {
    /// Opaque panel on both platforms. `cardSurface` is iOS-only.
    ///
    /// Shared by the readings bar and the update card, so it is named for what
    /// it is rather than for whichever of them asked first.
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

#if !os(macOS)

/// The same readings as `HostStatsBar`, on a host row.
///
/// A row in a list has little height to spend, so this drops the captions,
/// the meters and the surface and keeps the three figures plus the path
/// (direct or relay) once this device has one. The full bar stays on the
/// device screen, where there is room to say where the numbers came from.
///
/// Nothing is dialled for an offline host, and a reading that is missing is
/// left out rather than drawn as zero.
struct HostStatsStrip: View {
    let peer: String
    var online: Bool = true

    @State private var stats: HostStats?
    @State private var failed = false
    @State private var route: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: Theme.Space.m) {
                cell(icon: HostStatsFormat.powerSymbol(stats),
                     text: HostStatsFormat.powerLabel(stats, failed: failed))
                if let cpu = stats?.cpu {
                    cell(icon: "cpu", text: HostStatsFormat.cpuLabel(cpu))
                }
                if let used = stats?.ramUsedBytes, let total = stats?.ramTotalBytes, total > 0 {
                    // Used of total, not used alone. One figure with nothing to
                    // measure it against is a figure nobody can read: "24 GB" says
                    // nothing until the 32 is beside it.
                    cell(icon: "memorychip", text: HostStatsFormat.ramLabel(used: used, total: total))
                        .help(HostStatsFormat.ramExplanation)
                }
            }
            ConnectionRouteMark(route: route)
                .font(ClientType.caption)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(voiceOverLabel)
        .task(id: "\(peer)-\(online)") {
            guard online else { return }
            while !Task.isCancelled {
                await refresh()
                try? await Task.sleep(for: .milliseconds(2500))
            }
        }
    }

    private func cell(icon: String, text: String) -> some View {
        HStack(spacing: 4) {
            Image(systemName: icon)
                .font(ClientType.caption)
                .foregroundStyle(Theme.accent)
            Text(text)
                .font(ClientType.caption)
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
        route = await HostStatsFormat.loadRoute(for: peer)
    }
}

#endif
