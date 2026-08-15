// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
//
// Source-available for review, NOT open source. See LICENSE: no rights to
// redistribute, publish, or ship a build are granted. Read it, study it, run
// your own build of it.
// "tokenstat" is a trademark of pueev OU. See TRADEMARK.md.

import SwiftUI

// The client is iOS and iPadOS only.
#if !os(macOS)

/// Which computers are on this account, and what each of them is doing.
///
/// **Levels 1 and 2 of the machine plane**, as `docs/ios-client-ui.md` sets
/// them out: the list, and one device's detail. Both are account plane, so this
/// screen renders with every laptop asleep, which is the state a phone is
/// usually in when somebody opens it.
///
/// Levels 3 to 5 (that device's folders, the sessions running in them, and
/// attaching to a terminal) need the machine plane and a device that is awake.
/// The detail screen links into them through `ClientHostWorkspacesView` when
/// the device has a key to dial, and says nothing when it has not: a phone on
/// this account is not a host, and a computer without remote reach is already
/// explained one card above.
struct ClientDevicesView: View {
    @Environment(AccountModel.self) private var account
    @Environment(ConnectivityModel.self) private var connectivity
    @State private var model = ClientDevicesModel()

    private var machines: [Machine] { account.account?.machines ?? [] }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.Space.m) {
                if machines.isEmpty {
                    if account.isLoading {
                        ClientWireframe.Rows(count: 3)
                    } else {
                        ClientEmptyState(
                            kind: .nothingYet,
                            title: "No devices yet",
                            message: "Install tokenstat on a computer and sign in there. Free includes two devices. This phone uses one of them."
                        )
                    }
                } else {
                    header
                    alwaysOnHost
                    ForEach(sorted) { machine in
                        NavigationLink {
                            ClientDeviceDetailView(
                                machine: machine,
                                usage: model.usage(for: machine),
                                accountTotal: model.total,
                                isThisDevice: isThisDevice(machine)
                            )
                        } label: {
                            DeviceRow(
                                machine: machine,
                                usage: model.usage(for: machine),
                                peak: model.peak,
                                isThisDevice: isThisDevice(machine)
                            )
                        }
                        .buttonStyle(.plain)
                    }
                    if let message = model.errorMessage {
                        // The list still drew. What failed is the share of
                        // spend beside each name, which is worth one quiet line
                        // and not an error card where the devices should be.
                        Label(message, systemImage: "info.circle")
                            .font(ClientType.caption)
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 2)
                    }
                }
            }
            .padding(.horizontal, Theme.Space.m)
            .padding(.top, Theme.Space.s)
            .padding(.bottom, 96)
        }
        .background(Theme.background)
        // Always, not based on size. `basedOnSize` stops a short screen from
        // bouncing, and a screen that cannot bounce cannot be pulled: the
        // refresh gesture quietly disappeared exactly when the page was empty,
        // which is when somebody most wants to pull it.
        .scrollBounceBehavior(.always, axes: .vertical)
        .refreshable {
            await ClientRefresh.pull("devices") {
                await account.load()
                await model.load(
                    machines: machines,
                    days: DeviceHistory.days(for: account.account?.tier),
                    force: true
                )
            }
        }
        .task {
            if account.account == nil { await account.load() }
            await model.load(
                machines: machines,
                days: DeviceHistory.days(for: account.account?.tier)
            )
        }
        .onChange(of: account.account?.tier) { _, _ in
            Task {
                await model.load(
                    machines: machines,
                    days: DeviceHistory.days(for: account.account?.tier),
                    force: true
                )
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .connectivityRestored)) { _ in
            Task {
                await model.load(
                    machines: machines,
                    days: DeviceHistory.days(for: account.account?.tier),
                    force: true
                )
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .tokenstatEntitlementDidChange)) { _ in
            Task {
                await account.load()
                await model.load(
                    machines: machines,
                    days: DeviceHistory.days(for: account.account?.tier),
                    force: true
                )
            }
        }
    }

    /// This device first, then the busiest. Somebody scanning this list is
    /// looking for one of two things: the computer they are holding, or the one
    /// doing the work.
    private var sorted: [Machine] {
        machines.sorted { a, b in
            if isThisDevice(a) != isThisDevice(b) { return isThisDevice(a) }
            let left = model.usage(for: a)?.valueMicros ?? -1
            let right = model.usage(for: b)?.valueMicros ?? -1
            if left != right { return left > right }
            return a.displayName.localizedCaseInsensitiveCompare(b.displayName) == .orderedAscending
        }
    }

    private func isThisDevice(_ machine: Machine) -> Bool {
        guard let id = machine.machineID, let mine = account.account?.thisMachineID else {
            return false
        }
        return id == mine
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(deviceCount)
                .font(ClientType.sectionTitle)
            Text(planLine ?? model.windowDescription)
                .font(ClientType.caption)
                .foregroundStyle(.secondary)
            if let extra = planRemoteLine {
                Text(extra)
                    .font(ClientType.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(Theme.Space.m)
        .cardSurface()
        .accessibilityElement(children: .combine)
    }

    private var deviceCount: String {
        machines.count == 1 ? "1 device" : "\(machines.count) devices"
    }

    private var planLine: String? {
        guard let limit = account.account?.machineLimit else { return nil }
        return "\(machines.count) of \(limit) devices"
    }

    private var planRemoteLine: String? {
        if account.account?.canRemote == false {
            return "Remote control is on Patron. Usage from every linked device is already here."
        }
        return nil
    }

    /// The computers on this account and whether they are reachable right now,
    /// read-only. A phone cannot change a Mac's host policy, and the account
    /// does not carry it, so this says where the setting lives instead.
    @ViewBuilder
    private var alwaysOnHost: some View {
        let hosts = machines.filter(\.isHost)
        if !hosts.isEmpty {
            VStack(alignment: .leading, spacing: Theme.Space.s) {
                Text("Always-on host")
                    .font(ClientType.sectionTitle)
                ForEach(hosts) { machine in
                    HStack(spacing: Theme.Space.s) {
                        AwakeDot(online: machine.online)
                        Image(systemName: ClientDeviceIcon.symbol(
                            name: machine.label,
                            isHost: machine.isHost
                        ))
                        .font(.system(size: 13))
                        .foregroundStyle(.secondary)
                        .frame(width: 18)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(DeviceCopy.name(machine))
                                .font(ClientType.label.weight(.medium))
                                .lineLimit(1)
                                .truncationMode(.middle)
                            Text(alwaysOnLine(machine))
                                .font(ClientType.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer(minLength: Theme.Space.s)
                    }
                }
                Text("A computer with Always-on host on stays reachable even after you quit the app there. Turn it on in Account on that computer.")
                    .font(ClientType.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(Theme.Space.m)
            .frame(maxWidth: .infinity, alignment: .leading)
            .cardSurface()
            .accessibilityElement(children: .contain)
        }
    }

    private func alwaysOnLine(_ machine: Machine) -> String {
        if machine.online == true {
            return "Reachable now"
        }
        if machine.publicIdentity?.isEmpty == false {
            return "Asleep. Reachable once the app is open there."
        }
        return "Not set up for remote reach"
    }
}

/// One device in the list: what it is called, when it was last heard from, and
/// how much of the account's recent work it did.
private struct DeviceRow: View {
    let machine: Machine
    let usage: MachineUsage?
    let peak: Int64
    let isThisDevice: Bool

    private var share: Double {
        guard let usage, peak > 0 else { return 0 }
        return min(1, max(0, Double(usage.valueMicros) / Double(peak)))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: Theme.Space.s) {
                // The device in your hand is awake whatever the directory last
                // recorded: the app asking the question is running on it.
                AwakeDot(online: isThisDevice ? true : machine.online)
                Image(systemName: ClientDeviceIcon.symbol(
                    name: machine.label,
                    isHost: machine.isHost
                ))
                .font(.system(size: 13))
                .foregroundStyle(isThisDevice ? Theme.accent : .secondary)
                .frame(width: 18)
                VStack(alignment: .leading, spacing: 1) {
                    HStack(spacing: 6) {
                        Text(DeviceCopy.name(machine))
                            .font(ClientType.label.weight(.medium))
                            .lineLimit(1)
                            .truncationMode(.middle)
                        if isThisDevice {
                            Text("this device")
                                .font(ClientType.caption)
                                .foregroundStyle(Theme.accent)
                        }
                    }
                    Text(DeviceCopy.caption(machine, isThisDevice: isThisDevice))
                        .font(ClientType.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: Theme.Space.s)
                if let usage {
                    Text(usage.value.formatted)
                        .font(ClientType.rowFigure)
                        .foregroundStyle(Theme.accent)
                } else {
                    // Not zero. A device whose share has not been fetched has
                    // not been shown to have spent nothing, and reporting zero
                    // for something we did not measure is the one thing the
                    // data rules forbid outright.
                    Text("n/a")
                        .font(ClientType.rowFigure)
                        .foregroundStyle(.tertiary)
                }
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.tertiary)
            }
            if usage != nil {
                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        Capsule().fill(Theme.accent.opacity(0.12))
                        Capsule()
                            .fill(Theme.accent.opacity(0.55))
                            .frame(width: max(2, geo.size.width * share))
                    }
                }
                .frame(height: 4)
                .accessibilityHidden(true)
            }
        }
        .padding(Theme.Space.s)
        // A row is a link, so the whole card has to be tappable and at least
        // 44 points tall. The padding above gets it there on one line of text
        // and the bar keeps it there on two.
        .frame(minHeight: 44)
        .cardSurface()
        .accessibilityElement(children: .combine)
        .accessibilityLabel(DeviceCopy.rowLabel(machine, usage: usage, isThisDevice: isThisDevice))
        .accessibilityHint("Opens this device's detail")
    }
}

/// One device, level 2: what it is, what it spent, and whether it can be
/// reached.
struct ClientDeviceDetailView: View {
    let machine: Machine
    let usage: MachineUsage?
    let accountTotal: Int64
    let isThisDevice: Bool

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.Space.m) {
                spend
                reach
                work
                identity
                // The same explanation the Workspaces tab carries, with this
                // machine's key beside it: somebody reading a device page is
                // asking what a connection to it actually is.
                if !isThisDevice, let key = machine.publicIdentity, !key.isEmpty {
                    ClientSecurityCard(peerKey: key, peerName: DeviceCopy.name(machine))
                } else {
                    ClientSecurityCard()
                }
            }
            .padding(.horizontal, Theme.Space.m)
            .padding(.top, Theme.Space.s)
            .padding(.bottom, 96)
        }
        .background(Theme.background)
        .navigationTitle(DeviceCopy.name(machine))
        .navigationBarTitleDisplayMode(.inline)
    }

    private var spend: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(usage?.value.formatted ?? "n/a")
                .font(ClientType.figure)
                .foregroundStyle(Theme.accent)
                .minimumScaleFactor(0.6)
                .lineLimit(1)
            Text(usage.map { "at list rates, \(DeviceHistory.windowPhrase(days: $0.days))" }
                ?? "This device's share has not been fetched.")
                .font(ClientType.caption)
                .foregroundStyle(.secondary)
            if let usage {
                Text(detail(usage))
                    .font(ClientType.caption)
                    .foregroundStyle(.secondary)
                    .padding(.top, 2)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(Theme.Space.m)
        .cardSurface()
        .accessibilityElement(children: .combine)
    }

    private func detail(_ usage: MachineUsage) -> String {
        var parts = [
            usage.activeDays == 1 ? "1 active day" : "\(usage.activeDays) active days",
            "\(usage.events.formatted()) events",
        ]
        if accountTotal > 0 {
            let share = Double(usage.valueMicros) / Double(accountTotal) * 100
            parts.append(String(format: "%.0f%% of the account", share))
        }
        return parts.joined(separator: ", ")
    }

    private var reach: some View {
        VStack(alignment: .leading, spacing: Theme.Space.s) {
            Text("Reach")
                .font(ClientType.sectionTitle)
            HStack(spacing: Theme.Space.s) {
                AwakeDot(online: isThisDevice ? true : machine.online)
                Text(DeviceCopy.reach(machine, isThisDevice: isThisDevice))
                    .font(ClientType.label)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(Theme.Space.m)
        .cardSurface()
        .accessibilityElement(children: .combine)
    }

    /// Levels 3 to 5: that device's folders, its sessions, and attaching to
    /// one. A live connection is what they need, so the link is offered when
    /// there is a key to dial and withheld, with the reason, when there is not.
    @ViewBuilder
    private var work: some View {
        if !isThisDevice, let key = machine.publicIdentity, !key.isEmpty, machine.isHost {
            VStack(alignment: .leading, spacing: Theme.Space.s) {
                Text("Work")
                    .font(ClientType.sectionTitle)
                NavigationLink {
                    ClientHostWorkspacesView(peerKey: key, hostName: DeviceCopy.name(machine))
                } label: {
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Folders and sessions")
                                .font(ClientType.label.weight(.medium))
                                .foregroundStyle(.primary)
                            Text(machine.online == true
                                ? "Open what this device is working on."
                                : "It is asleep. Opening this will wake nothing, but it will try.")
                                .font(ClientType.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Image(systemName: "chevron.right")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.tertiary)
                    }
                    .frame(minHeight: 44)
                }
                .buttonStyle(.plain)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(Theme.Space.m)
            .cardSurface()
        }
    }

    private var identity: some View {
        VStack(alignment: .leading, spacing: Theme.Space.s) {
            Text("What this is")
                .font(ClientType.sectionTitle)
            DetailLine(
                label: "Name",
                value: machine.label?.isEmpty == false
                    ? machine.label ?? ""
                    : "not named on this account"
            )
            if let id = machine.machineID {
                DetailLine(label: "Device id", value: id)
            }
            DetailLine(label: "Last sync", value: DeviceCopy.lastSync(machine))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(Theme.Space.m)
        .cardSurface()
    }
}

/// A label and its value, stacked when the value is long enough that a row
/// would truncate it. Device ids are long enough.
private struct DetailLine: View {
    @Environment(\.dynamicTypeSize) private var typeSize
    let label: String
    let value: String

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(label)
                .font(ClientType.caption)
                .foregroundStyle(.secondary)
            Text(value)
                .font(typeSize.isAccessibilitySize ? ClientType.label : ClientType.rowFigure)
                .textSelection(.enabled)
                .lineLimit(2)
                .truncationMode(.middle)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }
}

/// Awake, asleep, or nobody said.
///
/// Three states and three appearances, because a server that never reported
/// presence must not be drawn as one that reported "asleep". The same rule the
/// limit readings follow: "no answer" and "the answer is no" are different.
private struct AwakeDot: View {
    let online: Bool?

    var body: some View {
        Circle()
            .fill(fill)
            .frame(width: 9, height: 9)
            .overlay {
                if online == nil {
                    Circle().strokeBorder(Color.secondary.opacity(0.5), lineWidth: 1)
                }
            }
            .accessibilityHidden(true)
    }

    private var fill: Color {
        switch online {
        case true: return Theme.accent
        case false: return Color.secondary.opacity(0.35)
        case nil: return .clear
        default: return .clear
        }
    }
}

/// Every sentence this screen says about a device, in one place so the list and
/// the detail cannot describe the same machine differently.
private enum DeviceCopy {
    /// What to call a device.
    ///
    /// `Machine.displayName` falls back to the account's id, which on a Mac
    /// sidebar is a reasonable last resort and on a phone is a row of hex where
    /// a computer's name should be. A machine registers its name when remote
    /// reach is turned on there, so an unnamed one is usually a laptop that
    /// only ever synced.
    static func name(_ machine: Machine) -> String {
        if let label = machine.label, !label.isEmpty { return label }
        return "Unnamed device"
    }

    /// The second line: enough to tell two unnamed devices apart, then when it
    /// was last heard from.
    static func caption(_ machine: Machine, isThisDevice: Bool = false) -> String {
        guard machine.label?.isEmpty != false, let id = machine.machineID else {
            return lastSeen(machine, isThisDevice: isThisDevice)
        }
        return "\(shortID(id)) · \(lastSeen(machine, isThisDevice: isThisDevice))"
    }

    /// `m_c982…872c`. Long enough to be unique in a list of five, short enough
    /// to sit under a name.
    static func shortID(_ id: String) -> String {
        guard id.count > 12 else { return id }
        return "\(id.prefix(6))…\(id.suffix(4))"
    }

    static func lastSeen(_ machine: Machine, isThisDevice: Bool = false) -> String {
        if isThisDevice || machine.online == true { return "Awake now" }
        if let seen = formatRelativeDate(machine.lastSeenAt) { return "Last seen \(seen)" }
        if let synced = formatRelativeDate(machine.lastSyncAt) { return "Last synced \(synced)" }
        return "Has not reported in yet"
    }

    static func lastSync(_ machine: Machine) -> String {
        formatServerDate(machine.lastSyncAt) ?? "never"
    }

    static func reach(_ machine: Machine, isThisDevice: Bool) -> String {
        if isThisDevice { return "This is the device you are holding." }
        if machine.online == true {
            return "Awake and reachable through the tunnel from a computer signed in to this account."
        }
        if machine.publicIdentity?.isEmpty == false {
            return "Asleep. It has a connection key, so it can be reached once it is awake."
        }
        // Not a fault, and not something to fix from a phone. Saying which
        // switch it is beats "unavailable".
        return "Not set up for remote reach. Turn on \"Reach devices from anywhere\" on that computer."
    }

    static func rowLabel(_ machine: Machine, usage: MachineUsage?, isThisDevice: Bool) -> String {
        var parts = [name(machine)]
        if isThisDevice { parts.append("this device") }
        parts.append(lastSeen(machine, isThisDevice: isThisDevice))
        if let usage {
            parts.append(
                "\(usage.value.formatted) at list rates, \(DeviceHistory.windowPhrase(days: usage.days))"
            )
        }
        return parts.joined(separator: ", ")
    }
}

/// Device spend window by account tier. Free of MainActor so row labels can
/// format without hopping into the model.
enum DeviceHistory {
    /// How far back this tier's device spend should look.
    ///
    /// Matches the account history product: free a month, supporter a year,
    /// patron and legend everything the series still holds. The host clamps
    /// the upper bound; the server still enforces each account's own depth.
    static func days(for tier: String?) -> Int {
        switch tier?.lowercased() {
        case "legend", "patron": return 3650
        case "supporter": return 365
        default: return 30
        }
    }

    /// Human window for labels: "the last 30 days", "the last year", "all time".
    static func windowPhrase(days: Int) -> String {
        if days >= 1000 { return "all time" }
        if days >= 360 { return "the last year" }
        if days == 1 { return "the last day" }
        return "the last \(days) days"
    }
}

/// What each device contributed, fetched once and kept.
///
/// One request per device on the host's side, so this is asked for when the
/// screen opens and not warmed behind one somebody might never visit.
///
/// The window follows the account tier's history depth: free 30 days,
/// supporter a year, patron all-time. Asking every tier for a month left a
/// paid account looking like it only spent a slice of what it really had.
@Observable
@MainActor
final class ClientDevicesModel {
    private(set) var rows: [MachineUsage] = []
    private(set) var errorMessage: String?
    private(set) var isLoading = false
    private var loadedIDs: Set<String> = []
    private var loadedDays: Int = 0

    func usage(for machine: Machine) -> MachineUsage? {
        guard let id = machine.machineID else { return nil }
        return rows.first { $0.machine == id }
    }

    /// The largest device's value, which the share bars are drawn against. The
    /// account total would make a two-device account draw two half bars and say
    /// nothing.
    var peak: Int64 { rows.map(\.valueMicros).max() ?? 0 }

    var total: Int64 { rows.reduce(0) { $0 + $1.valueMicros } }

    var windowDescription: String {
        guard let days = rows.first?.days else { return "Across this account" }
        return "Share of \(DeviceHistory.windowPhrase(days: days)), at list rates"
    }

    func load(machines: [Machine], days: Int = 30, force: Bool = false) async {
        let ids = machines.compactMap(\.machineID)
        guard !ids.isEmpty else { return }
        if !force, Set(ids) == loadedIDs, loadedDays == days, !rows.isEmpty { return }
        isLoading = true
        defer { isLoading = false }
        do {
            rows = try await Bridge.machineUsage(machines: ids, days: days)
            loadedIDs = Set(ids)
            loadedDays = days
            errorMessage = nil
        } catch {
            // The device list itself came from the account and is already on
            // screen. This failure costs the figures beside the names, which is
            // a line of explanation rather than an empty screen.
            errorMessage = "Could not work out what each device spent: \(error.localizedDescription)"
        }
    }
}

#endif
