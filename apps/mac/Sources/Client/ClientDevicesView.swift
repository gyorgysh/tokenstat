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
/// the device has a key to dial. Reach and awake state live on each row's
/// caption, not in a second list of the same hosts.
struct ClientDevicesView: View {
    @Environment(AccountModel.self) private var account
    @Environment(ConnectivityModel.self) private var connectivity
    @Environment(ClientNavigationModel.self) private var navigation
    @State private var model = ClientDevicesModel()
    @State private var showSetup = false
    @State private var search = ""

    private var machines: [Machine] { account.account?.machines ?? [] }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.Space.m) {
                // The one place that makes a machine, rather than listing the
                // ones that already exist. Above the list because somebody with
                // nothing on the account is exactly who is looking at it.
                Button { showSetup = true } label: {
                    HStack(spacing: Theme.Space.m) {
                        // The machine, not the act of connecting. Most people
                        // arriving here are renting one rather than plugging in
                        // something they can see, and a cloud says that where a
                        // plug says something about cables.
                        Image(systemName: "cloud.fill").foregroundStyle(Theme.accent)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Set up a machine").font(ClientType.label.weight(.semibold))
                            Text("A cloud server, a Mac you own, or one over SSH")
                                .font(ClientType.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Image(systemName: "chevron.right").foregroundStyle(.tertiary)
                    }
                    .padding(Theme.Space.m)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .cardSurface()
                }
                .buttonStyle(.plain)
                NavigationLink {
                    SSHLibraryView(vaultTier: account.account?.vaultTierForSsh)
                } label: {
                    HStack(spacing: Theme.Space.m) {
                        Image(systemName: "terminal.fill").foregroundStyle(Theme.accent)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("SSH hosts").font(ClientType.label.weight(.semibold))
                            Text("Connect to a saved server").font(ClientType.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Image(systemName: "chevron.right").foregroundStyle(.tertiary)
                    }
                    .padding(Theme.Space.m)
                    .cardSurface()
                }
                .buttonStyle(.plain)
                if !machines.contains(where: \.isHost) {
                    if account.isLoading {
                        ClientWireframe.Rows(count: 3)
                    } else {
                        ClientEmptyState(
                            kind: .nothingYet,
                            title: "No computer connected yet",
                            message: "Connect a computer you own, or give tokenstat a server "
                                + "and it will set the machine up for you.",
                            actionTitle: "Set up a machine",
                            actionIcon: .connect,
                            action: { showSetup = true },
                            art: .connect
                        )
                    }
                }
                if !machines.isEmpty {
                    header
                    ClientAdaptiveCards {
                    ForEach(sorted.filter { search.isEmpty || ($0.label ?? "").localizedCaseInsensitiveContains(search) || ($0.platform ?? "").localizedCaseInsensitiveContains(search) }) { machine in
                        NavigationLink {
                            ClientDeviceDetailView(
                                machine: machine,
                                usage: model.usage(for: machine),
                                accountTotal: model.total,
                                isThisDevice: isThisDevice(machine),
                                onRenamed: { await account.load() }
                            )
                        } label: {
                            DeviceRow(
                                machine: machine,
                                usage: model.usage(for: machine),
                                isThisDevice: isThisDevice(machine)
                            )
                        }
                        .buttonStyle(.plain)
                    }
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
        .searchable(text: $search, prompt: "Search devices")
        .fullScreenCover(isPresented: $showSetup) {
            ClientSetupWizard()
        }
        // One push, driven from outside this tab: Workspaces sends a machine
        // here rather than growing a device screen of its own. A binding
        // rather than a path because the stack belongs to `ClientRootView`,
        // and clearing the id on dismiss is what lets Devices open on its
        // list the next time somebody taps the tab.
        .navigationDestination(
            isPresented: Binding(
                get: { requestedMachine != nil },
                set: { if !$0 { navigation.deviceMachineID = nil } }
            )
        ) {
            if let machine = requestedMachine {
                ClientDeviceDetailView(
                    machine: machine,
                    usage: model.usage(for: machine),
                    accountTotal: model.total,
                    isThisDevice: isThisDevice(machine),
                    onRenamed: { await account.load() }
                )
            }
        }
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
        // An id that matches nothing would otherwise sit in the model
        // forever, and the push it was asking for can never happen. Clearing
        // it lets Devices open on its list next time instead of on nothing.
        // The same change is when per-device spend goes stale: a machine
        // added, removed or renamed must refetch its share, and the load
        // dedupes on the host id set so unchanged lists cost nothing.
        .onChange(of: machines) { _, _ in
            if let wanted = navigation.deviceMachineID,
               !machines.contains(where: { $0.machineID == wanted }) {
                navigation.deviceMachineID = nil
            }
            Task {
                await model.load(
                    machines: machines,
                    days: DeviceHistory.days(for: account.account?.tier)
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

    /// The machine another tab asked for, if the account still lists it.
    ///
    /// Resolved on every read rather than captured, because the account is
    /// reloaded underneath this screen and a stale `Machine` would push a row
    /// that no longer matches what the list shows.
    private var requestedMachine: Machine? {
        guard let wanted = navigation.deviceMachineID else { return nil }
        return machines.first { $0.machineID == wanted }
    }

    /// This device first, then awake machines by spend, then everyone else by
    /// how recently they were last active. Clients never rank on spend (they
    /// do not upload usage), so value only separates hosts.
    private var sorted: [Machine] {
        machines.sorted { a, b in
            if isThisDevice(a) != isThisDevice(b) { return isThisDevice(a) }
            let aAwake = isAwake(a)
            let bAwake = isAwake(b)
            if aAwake != bAwake { return aAwake }
            let left = sortSpend(a)
            let right = sortSpend(b)
            if left != right { return left > right }
            let aSeen = activityDate(a)
            let bSeen = activityDate(b)
            if aSeen != bSeen { return aSeen > bSeen }
            return a.displayName.localizedCaseInsensitiveCompare(b.displayName)
                == .orderedAscending
        }
    }

    private func isAwake(_ machine: Machine) -> Bool {
        isThisDevice(machine) || machine.online == true
    }

    /// Host spend for ordering. Clients and unknown usage sort below any real
    /// figure so a $0 phone does not float above a busy laptop.
    private func sortSpend(_ machine: Machine) -> Int64 {
        guard machine.isHost, let usage = model.usage(for: machine) else { return -1 }
        return usage.valueMicros
    }

    private func activityDate(_ machine: Machine) -> Date {
        if isThisDevice(machine) { return .distantFuture }
        if machine.online == true { return .distantFuture }
        return parseServerDate(machine.lastSeenAt)
            ?? parseServerDate(machine.lastSyncAt)
            ?? .distantPast
    }

    private func isThisDevice(_ machine: Machine) -> Bool {
        guard let id = machine.machineID, let mine = account.account?.thisMachineID else {
            return false
        }
        return id == mine
    }

    private var header: some View {
        // Title + plan fill. The spend window used to sit under the bar as
        // "Share of all time…", which repeated what every host figure already
        // means and crowded the list.
        VStack(alignment: .leading, spacing: Theme.Space.s) {
            HStack(alignment: .center, spacing: Theme.Space.s) {
                ClientSectionTitle(title: "Devices", mark: "mark_device")
                Spacer(minLength: Theme.Space.s)
                capacityBadge
            }
            if let limit = account.account?.machineLimit, limit > 0 {
                capacityBar(used: machines.count, limit: limit)
            }
            if let extra = planRemoteLine {
                Text(extra)
                    .font(ClientType.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(headerAccessibilityLabel)
    }

    /// Plan fill as a trailing chip: "8 / 10". Reads as capacity, not as a
    /// second title for the same list of devices below.
    @ViewBuilder
    private var capacityBadge: some View {
        if let limit = account.account?.machineLimit {
            Text("\(machines.count) / \(limit)")
                .font(ClientType.caption.weight(.semibold))
                .foregroundStyle(capacityTint(used: machines.count, limit: limit))
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(
                    capacityTint(used: machines.count, limit: limit).opacity(0.12),
                    in: Capsule()
                )
                .accessibilityLabel("\(machines.count) of \(limit) devices")
        } else {
            Text(deviceCount)
                .font(ClientType.caption.weight(.medium))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(Theme.accent.opacity(0.10), in: Capsule())
        }
    }

    private func capacityBar(used: Int, limit: Int) -> some View {
        let fill = min(1, Double(used) / Double(max(limit, 1)))
        return GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(Theme.accent.opacity(0.12))
                Capsule()
                    .fill(capacityTint(used: used, limit: limit).opacity(0.7))
                    .frame(width: max(4, geo.size.width * fill))
            }
        }
        .frame(height: 4)
        .accessibilityHidden(true)
    }

    private func capacityTint(used: Int, limit: Int) -> Color {
        guard limit > 0 else { return Theme.accent }
        let ratio = Double(used) / Double(limit)
        if ratio >= 1 { return Theme.danger }
        if ratio >= 0.8 { return Theme.warning }
        return Theme.accent
    }

    private var headerAccessibilityLabel: String {
        var parts: [String] = ["Devices"]
        if let limit = account.account?.machineLimit {
            parts.append("\(machines.count) of \(limit) devices")
        } else {
            parts.append(deviceCount)
        }
        if let extra = planRemoteLine { parts.append(extra) }
        return parts.joined(separator: ". ")
    }

    private var deviceCount: String {
        machines.count == 1 ? "1 device" : "\(machines.count) devices"
    }

    private var planRemoteLine: String? {
        if account.account?.canRemote == false {
            return "Remote control is on Patron. Usage from every linked device is already here."
        }
        return nil
    }
}

/// One device in the list: what it is called, when it was last heard from, and
/// how much of the account's recent work it did (hosts only).
private struct DeviceRow: View {
    let machine: Machine
    let usage: MachineUsage?
    let isThisDevice: Bool

    /// Phones, tablets and "this device" never upload an archive. A $0.00
    /// figure there is noise, not a measurement, so the row stays about status.
    private var showsSpend: Bool {
        machine.isHost && !isThisDevice
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: Theme.Space.s) {
                // The device in your hand is awake whatever the directory last
                // recorded: the app asking the question is running on it.
                AwakeDot(online: isThisDevice ? true : machine.online)
                Image(systemName: ClientDeviceIcon.symbol(for: machine))
                .font(Theme.font(13))
                .foregroundStyle(isThisDevice ? Theme.accent : .secondary)
                .frame(width: 18)
                VStack(alignment: .leading, spacing: 1) {
                    Text(DeviceCopy.name(machine))
                        .font(ClientType.label.weight(.medium))
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Text(DeviceCopy.caption(machine, isThisDevice: isThisDevice))
                        .font(ClientType.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: Theme.Space.s)
                // Trailing column: spend on hosts, a You chip on this phone,
                // nothing on other clients. Keeps the name line clean and
                // lines the marker up with the figures on host rows.
                if showsSpend {
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
                } else if isThisDevice {
                    Text("You")
                        .font(ClientType.caption.weight(.semibold))
                        .foregroundStyle(Theme.accent)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(Theme.accent.opacity(0.12), in: Capsule())
                        .accessibilityHidden(true)
                }
                Image(systemName: "chevron.right")
                    .font(Theme.caption.weight(.semibold))
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(Theme.Space.s)
        // A row is a link, so the whole card has to be tappable and at least
        // 44 points tall.
        .frame(minHeight: 44)
        .cardSurface()
        .accessibilityElement(children: .combine)
        .accessibilityLabel(DeviceCopy.rowLabel(
            machine,
            usage: showsSpend ? usage : nil,
            isThisDevice: isThisDevice
        ))
        .accessibilityHint("Opens this device's detail")
    }
}

/// One device, level 2: what it is, what it spent, and whether it can be
/// reached.
struct ClientDeviceDetailView: View {
    @Environment(ClientWorkspacesModel.self) private var workspaces: ClientWorkspacesModel?
    let machine: Machine
    let usage: MachineUsage?
    let accountTotal: Int64
    let isThisDevice: Bool
    /// Re-read the account after a rename, so the list behind this screen says
    /// the new name too.
    var onRenamed: () async -> Void = {}
    @Environment(AccountModel.self) private var account
    @Environment(ClientStore.self) private var store

    @State private var renaming = false
    @State private var draft = ""
    @State private var savingName = false
    @State private var renameError: String?
    @FocusState private var editingName: Bool
    /// The name this screen just set. `machine` is the copy this screen was
    /// pushed with, so without it a rename read as having done nothing until
    /// you went back to the list.
    @State private var renamedTo: String?

    /// The device as it stands now: what was typed here, or what was pushed.
    private var current: Machine {
        guard let renamedTo else { return machine }
        var updated = machine
        updated.label = renamedTo.isEmpty ? nil : renamedTo
        return updated
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.Space.m) {
                // Hosts only. Phones and tablets (including this device) do not
                // upload usage, so a $0.00 card would invent a number.
                if showsSpend {
                    spend
                }
                // Reachability, live readings and the two ways in, as one
                // header shared with the screen you reach from Workspaces.
                if !isThisDevice, let key = machine.publicIdentity, !key.isEmpty, machine.isHost {
                    ClientHostHeader(
                        name: DeviceCopy.name(current),
                        peerKey: key,
                        online: machine.online,
                        reach: DeviceCopy.reach(machine, isThisDevice: isThisDevice)
                    )
                    if let workspaces, workspaces.connectedKey == key {
                        Button("Disconnect", .disconnect) { workspaces.disconnect() }
                            .buttonStyle(SecondaryButtonStyle())
                            .accessibilityHint("Disconnects this device from the computer")
                    }
                } else {
                    liveStats
                    reach
                }
                identity
                // Which release that computer runs, and the button that moves
                // it. A server has no application to update and nobody at the
                // keyboard, so this is the only place it can be done from.
                software
                // Giving a machine more work after setup. The empty machine
                // is covered from the Workspaces tab; a machine that already
                // has folders had no way in from here.
                work
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
        .navigationTitle(DeviceCopy.name(current))
        .navigationBarTitleDisplayMode(.inline)
    }

    /// Hosts that are not this phone: the only place spend is a real figure.
    private var showsSpend: Bool {
        machine.isHost && !isThisDevice
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
        .overlay(alignment: .topTrailing) {
            // Top trailing, the way every other figure card carries its mark.
            // An overlay rather than a row, because the figure under it scales
            // itself down to fit and must keep the whole width to do that.
            FeatureMark(name: "mark_insights", size: 26)
                .accessibilityHidden(true)
        }
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

    /// Naming a device, in the row where the name is read.
    ///
    /// Empty is the undo rather than an error: the machine goes back to
    /// naming itself, which is the same rule the Mac's own name field has.
    private var nameField: some View {
        VStack(alignment: .leading, spacing: Theme.Space.s) {
            Text("Name")
                .font(ClientType.caption)
                .foregroundStyle(.secondary)
            TextField("Name this device", text: $draft)
                .textFieldStyle(.themed)
                .autocorrectionDisabled()
                .focused($editingName)
                .submitLabel(.done)
                .onSubmit { Task { await saveName() } }
            HStack(spacing: Theme.Space.s) {
                Button(savingName ? "Saving…" : "Save", .save) {
                    Task { await saveName() }
                }
                .clientProminentStyle()
                .tint(Theme.accent)
                .disabled(savingName)
                Button("Cancel", .dismiss, role: .cancel) {
                    renaming = false
                    renameError = nil
                }
                .font(ClientType.caption.weight(.semibold))
                .tint(Theme.accent)
            }
            Text("Empty puts back the name the device gives itself.")
                .font(ClientType.caption)
                .foregroundStyle(.tertiary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func saveName() async {
        guard let id = machine.machineID, !id.isEmpty else {
            renameError = "This device has no id on the account yet."
            return
        }
        savingName = true
        defer { savingName = false }
        do {
            let wanted = draft.trimmingCharacters(in: .whitespacesAndNewlines)
            try await Bridge.renameAccountMachine(id: id, name: wanted)
            renamedTo = wanted
            renameError = nil
            renaming = false
            await onRenamed()
        } catch {
            renameError = FriendlyError.from(error.localizedDescription).message
        }
    }

    private var reach: some View {
        VStack(alignment: .leading, spacing: Theme.Space.s) {
            ClientSectionTitle(title: "Reach", mark: "mark_host")
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

    /// More work for a machine that already has some. Both destinations run
    /// their own connection and dismiss themselves, so this screen keeps no
    /// loading state for them.
    @ViewBuilder
    private var work: some View {
        if !isThisDevice,
           let key = machine.publicIdentity,
           !key.isEmpty,
           machine.isHost {
            VStack(alignment: .leading, spacing: Theme.Space.s) {
                ClientSectionTitle(title: "Folders", mark: "mark_folder")
                NavigationLink {
                    ClientFolderPicker(peer: key, hostName: DeviceCopy.name(current)) { _ in }
                } label: {
                    DeviceActionRow(
                        title: "Choose a folder",
                        subtitle: "Register a folder already on this computer.",
                        icon: .reveal
                    )
                }
                .buttonStyle(DeviceActionRowStyle())
                NavigationLink {
                    ClientCloneRepository(peer: key, hostName: DeviceCopy.name(current)) { _ in }
                } label: {
                    DeviceActionRow(
                        title: "Clone a repository",
                        subtitle: "Run git on this computer and register the folder.",
                        icon: .download
                    )
                }
                .buttonStyle(DeviceActionRowStyle())
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(Theme.Space.m)
            .cardSurface()
        }
    }

    /// The release a paired host runs. Only for a host, and only while it is
    /// awake: a machine that cannot be reached cannot be asked, and this phone
    /// is not a host at all.
    @ViewBuilder
    private var software: some View {
        if !isThisDevice,
           let key = machine.publicIdentity,
           !key.isEmpty,
           machine.isHost,
           machine.online == true {
            HostUpdateCard(peer: key)
        }
    }

    /// Power, CPU and memory after a hop to an awake host. This phone is
    /// never sampled here: it is not a host.
    @ViewBuilder
    private var liveStats: some View {
        if !isThisDevice,
           let key = machine.publicIdentity,
           !key.isEmpty,
           machine.online == true {
            HostStatsBar(peer: key, online: true)
        }
    }

    private var identity: some View {
        VStack(alignment: .leading, spacing: Theme.Space.s) {
            ClientSectionTitle(title: "What this is", mark: "mark_device")
            if renaming {
                nameField
            } else {
                HStack(alignment: .firstTextBaseline) {
                    DetailLine(
                        label: "Name",
                        value: current.label?.isEmpty == false
                            ? current.label ?? ""
                            : "not named on this account"
                    )
                    Spacer(minLength: Theme.Space.s)
                    // Any device on the account, not only this phone. A Linux
                    // server with nothing but the CLI on it has no other way
                    // to be named.
                    Button("Rename", .edit) {
                        draft = current.label ?? ""
                        renaming = true
                        editingName = true
                    }
                    .font(ClientType.caption.weight(.semibold))
                    .tint(Theme.accent)
                    // Caption sized text is about twenty points tall on its
                    // own, which is a hard thing to hit beside a name that
                    // takes two lines. The glyph and the word stay small,
                    // the target around them does not.
                    .frame(minHeight: 44)
                }
            }
            if let renameError {
                Text(renameError)
                    .font(ClientType.caption)
                    .foregroundStyle(Theme.danger)
            }
            if let platform = machine.platform, !platform.isEmpty {
                DetailLine(label: "What it runs", value: platform)
            }
            if let id = machine.machineID {
                DetailLine(label: "Device id", value: id)
            }
            if machine.reportsArchiveSync {
                DetailLine(label: "Last sync", value: DeviceCopy.lastSync(machine))
            } else if let seen = formatRelativeDate(machine.lastSeenAt) {
                DetailLine(label: "Last used", value: seen)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(Theme.Space.m)
        .cardSurface()
    }
}

/// One row inside the From this device card: a glyph, a title, a line of why,
/// a chevron.
///
/// The glyph and the panel under it are what say this is a button. Without
/// them the two ways into another computer were the only actionable surface in
/// the app drawn as plain text on a card, and people read past them.
struct DeviceActionRow: View {
    let title: String
    let subtitle: String
    /// From the one vocabulary, so an action cannot be a folder here and a
    /// document on the next screen.
    let icon: ActionIcon

    var body: some View {
        HStack(spacing: Theme.Space.m) {
            ActionSeat(icon: icon)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(ClientType.label.weight(.medium))
                    .foregroundStyle(.primary)
                Text(subtitle)
                    .font(ClientType.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: Theme.Space.s)
            Image(systemName: "chevron.right")
                .font(Theme.caption.weight(.semibold))
                .foregroundStyle(.tertiary)
        }
        .frame(minHeight: 44)
    }
}

/// The surface a device action row sits on, and what it does while held.
///
/// A style rather than a modifier on the row, because the pressed fill is the
/// other half of "this is a button" and only the style can see the press. The
/// panel and hairline are the ones `HostStatsBar` already nests inside the same
/// card, so the rows and the readings above them are one family.
struct DeviceActionRowStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .padding(Theme.Space.m)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                configuration.isPressed ? Theme.rowHighlight : Theme.panel,
                in: RoundedRectangle(cornerRadius: Theme.cardRadius)
            )
            .overlay {
                RoundedRectangle(cornerRadius: Theme.cardRadius)
                    .strokeBorder(Theme.border, lineWidth: 1)
            }
            .contentShape(.rect(cornerRadius: Theme.cardRadius))
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
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
struct AwakeDot: View {
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
        // What the machine says it is, before giving up. A CLI-only install
        // sends this at login, so "Linux computer" is usually available where
        // a name is not, and it places the row in a way "Unnamed" cannot.
        if let platform = machine.platform,
           let family = platform.split(separator: "·").first?
               .split(separator: " ").first,
           !family.isEmpty {
            return "\(family) \(machine.isHost ? "computer" : "device")"
        }
        return "Unnamed device"
    }

    /// The second line: awake / reach first, then enough to tell two unnamed
    /// devices apart when there is no status worth leading with.
    static func caption(_ machine: Machine, isThisDevice: Bool = false) -> String {
        let status = statusLine(machine, isThisDevice: isThisDevice)
        // Named rows: status alone. Unnamed ones keep a short id so two
        // "Linux computer" rows do not look identical under the same caption.
        guard machine.label?.isEmpty != false, let id = machine.machineID else {
            return status
        }
        return "\(shortID(id)) · \(status)"
    }

    /// Short presence + reach for a list row. Detail still carries the longer
    /// reach paragraph; the list only needs a glance.
    ///
    /// The account directory does not publish Always-on host as a flag, so
    /// "Always on" is not claimed here. Online hosts read as awake; hosts with
    /// a connection key but offline read as asleep and ready; hosts without a
    /// key say so in one line instead of a second panel of the same machines.
    static func statusLine(_ machine: Machine, isThisDevice: Bool) -> String {
        if isThisDevice || machine.online == true {
            return "Awake now"
        }
        if machine.isHost {
            if machine.publicIdentity?.isEmpty == false {
                if let seen = formatRelativeDate(machine.lastSeenAt) {
                    return "Asleep · last seen \(seen)"
                }
                return "Asleep"
            }
            return "Not set up for remote"
        }
        if let seen = formatRelativeDate(machine.lastSeenAt) {
            return "Last seen \(seen)"
        }
        return "Has not reported in yet"
    }

    /// `m_c982…872c`. Long enough to be unique in a list of five, short enough
    /// to sit under a name.
    static func shortID(_ id: String) -> String {
        guard id.count > 12 else { return id }
        return "\(id.prefix(6))…\(id.suffix(4))"
    }

    static func lastSeen(_ machine: Machine, isThisDevice: Bool = false) -> String {
        statusLine(machine, isThisDevice: isThisDevice)
    }

    static func lastSync(_ machine: Machine) -> String {
        guard machine.reportsArchiveSync else { return "—" }
        return formatServerDate(machine.lastSyncAt) ?? "never"
    }

    static func reach(_ machine: Machine, isThisDevice: Bool) -> String {
        if isThisDevice { return "This is the device you are holding." }
        if machine.online == true {
            return "Awake and reachable through the tunnel from this device, and from any other device signed in to this account."
        }
        if machine.publicIdentity?.isEmpty == false {
            return "Asleep. It has a connection key, so it can be reached from this device once it is awake. Always-on host on that computer keeps it reachable after you quit the app there."
        }
        // Not a fault, and not something to fix from a phone. Saying which
        // switch it is beats "unavailable".
        return "Not set up for remote reach. Turn on \"Reach devices from anywhere\" on that computer."
    }

    static func rowLabel(_ machine: Machine, usage: MachineUsage?, isThisDevice: Bool) -> String {
        var parts = [name(machine)]
        if isThisDevice { parts.append("this device") }
        parts.append(statusLine(machine, isThisDevice: isThisDevice))
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

    var total: Int64 { rows.reduce(0) { $0 + $1.valueMicros } }

    var windowDescription: String {
        guard let days = rows.first?.days else { return "Across this account" }
        return "Share of \(DeviceHistory.windowPhrase(days: days)), at list rates"
    }

    func load(machines: [Machine], days: Int = 30, force: Bool = false) async {
        // Hosts only. Clients never upload an archive, so asking for their
        // spend only produces $0 rows the UI does not show.
        let ids = machines.filter(\.isHost).compactMap(\.machineID)
        guard !ids.isEmpty else {
            rows = []
            loadedIDs = []
            loadedDays = days
            errorMessage = nil
            return
        }
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
