// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
//
// Source-available: source sharing and own builds are permitted.
// Store and commercial distribution of builds is reserved. See LICENSE.
// "tokenstat" is a trademark of pueev OU. See TRADEMARK.md.

import SwiftUI

#if !os(macOS)

struct ClientDevicesView: View {
    @Environment(AccountModel.self) private var account
    @Environment(ConnectivityModel.self) private var connectivity
    @Environment(ClientNavigationModel.self) private var navigation
    @Environment(ClientDevicesModel.self) private var model
    @Environment(ClientSetupSession.self) private var setup
    @State private var search = ""

    private var machines: [Machine] { account.account?.machines ?? [] }
    private var shownMachines: [Machine] {
        let query = search.trimmingCharacters(in: .whitespacesAndNewlines)
        return sorted.filter { machine in
            query.isEmpty || [DeviceCopy.name(machine), machine.platform ?? "", machine.machineID ?? "",
                              machine.isHost ? "Computer" : "Phone tablet",
                              DeviceCopy.caption(machine, isThisDevice: isThisDevice(machine))]
                .contains { $0.localizedStandardContains(query) }
        }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.Space.m) {
                HStack(spacing: Theme.Space.m) {
                    Button(L10n.text("common.add_device"), .create) { setup.open() }
                    NavigationLink {
                        SSHLibraryView(vaultTier: account.account?.vaultTierForSsh)
                    } label: {
                        Label(L10n.text("apple.clientdevicesview.ssh_hosts.6e8d5967"), systemImage: "terminal")
                    }
                }
                .buttonStyle(.bordered)
                .font(ClientType.label)
                if !machines.contains(where: \.isHost) {
                    if account.isLoading {
                        ClientWireframe.Rows(count: 3)
                    } else {
                        ClientEmptyState(
                            kind: .nothingYet,
                            title: L10n.text("apple.clientdevicesview.no_computer_connected_yet.f36b705d"),
                            message: L10n.text("apple.clientdevicesview.connect_a_computer_you_own_or_give_tokenst.d19be274"),
                            actionTitle: L10n.text("apple.clientdevicesview.set_up_a_machine.43e10e13"),
                            actionIcon: .connect,
                            action: { setup.open() },
                            art: .connect
                        )
                    }
                }
                if !machines.isEmpty {
                    header
                    if shownMachines.isEmpty {
                        Text(L10n.text("apple.clientdevicesview.no_devices_match_your_search.85a81e48"))
                            .font(ClientType.caption).foregroundStyle(.secondary)
                    }
                    ClientAdaptiveCards {
                    ForEach(shownMachines) { machine in
                        NavigationLink {
                            ClientDeviceDetailView(
                                machine: machine,
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
        .searchable(text: $search, prompt: L10n.text("apple.clientdevicesview.search_devices.3aebaefc"))
        .navigationDestination(
            isPresented: Binding(
                get: { requestedMachine != nil },
                set: { if !$0 { navigation.deviceMachineID = nil } }
            )
        ) {
            if let machine = requestedMachine {
                ClientDeviceDetailView(
                    machine: machine,
                    isThisDevice: isThisDevice(machine),
                    onRenamed: { await account.load() }
                )
            }
        }
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

    private var requestedMachine: Machine? {
        guard let wanted = navigation.deviceMachineID else { return nil }
        return machines.first { $0.machineID == wanted }
    }

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
        VStack(alignment: .leading, spacing: Theme.Space.s) {
            HStack(alignment: .center, spacing: Theme.Space.s) {
                ClientSectionTitle(title: L10n.text("common.devices"), mark: "mark_device")
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
                .accessibilityLabel(L10n.text("apple.clientdevicesview.0_of_1_devices.bd266bff", "\(machines.count)", "\(limit)"))
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
        var parts: [String] = [L10n.text("common.devices")]
        if let limit = account.account?.machineLimit {
            parts.append(L10n.text("apple.clientdevicesview.0_of_1_devices.bd266bff", "\(machines.count)", "\(limit)"))
        } else {
            parts.append(deviceCount)
        }
        if let extra = planRemoteLine { parts.append(extra) }
        return parts.joined(separator: ". ")
    }

    private var deviceCount: String {
        machines.count == 1 ? "1 device" : L10n.text("apple.clientdevicesview.0_devices.f3bf57aa", "\(machines.count)")
    }

    private var planRemoteLine: String? {
        if account.account?.canRemote == false {
            return L10n.text("apple.clientdevicesview.remote_control_is_on_patron_usage_from_eve.5dc0dfc8")
        }
        return nil
    }
}

private struct DeviceRow: View {
    let machine: Machine
    let usage: MachineUsage?
    let isThisDevice: Bool

    private var showsSpend: Bool {
        machine.isHost && !isThisDevice
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: Theme.Space.s) {
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
                if showsSpend {
                    if let usage {
                        Text(usage.value.formatted)
                            .font(ClientType.rowFigure)
                            .foregroundStyle(Theme.accent)
                    } else {
                        Text(L10n.text("apple.clientdevicesview.n_a.a683c5c5"))
                            .font(ClientType.rowFigure)
                            .foregroundStyle(.tertiary)
                    }
                } else if isThisDevice {
                    Text(L10n.text("apple.clientdevicesview.you.08b04193"))
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
        .frame(minHeight: 44)
        .cardSurface()
        .accessibilityElement(children: .combine)
        .accessibilityLabel(DeviceCopy.rowLabel(
            machine,
            usage: showsSpend ? usage : nil,
            isThisDevice: isThisDevice
        ))
        .accessibilityHint(L10n.text("apple.clientdevicesview.opens_this_device_s_detail.58c2810e"))
    }
}

struct ClientDeviceDetailView: View {
    @Environment(ClientWorkspacesModel.self) private var workspaces: ClientWorkspacesModel?
    @Environment(ClientDevicesModel.self) private var devices
    @State private var usageRequested = false
    let machine: Machine
    let isThisDevice: Bool
    var onRenamed: () async -> Void = {}
    @Environment(AccountModel.self) private var account
    @Environment(ClientStore.self) private var store

    @State private var renaming = false
    @State private var draft = ""
    @State private var savingName = false
    @State private var renameError: String?
    @FocusState private var editingName: Bool
    @State private var renamedTo: String?

    private var current: Machine {
        guard let renamedTo else { return machine }
        var updated = machine
        updated.label = renamedTo.isEmpty ? nil : renamedTo
        return updated
    }

    private var usage: MachineUsage? { devices.usage(for: machine) }
    private var accountTotal: Int64 { devices.total }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.Space.m) {
                if showsSpend {
                    spend
                }
                if !isThisDevice, let key = machine.publicIdentity, !key.isEmpty, machine.isHost {
                    ClientHostHeader(
                        name: DeviceCopy.name(current),
                        peerKey: key,
                        online: machine.online,
                        reach: DeviceCopy.reach(machine, isThisDevice: isThisDevice)
                    )
                    if let workspaces, workspaces.loadedHostKeys.contains(key),
                       !workspaces.staleHostKeys.contains(key) {
                        Button(L10n.text("common.disconnect"), .disconnect) { workspaces.disconnectHost(key) }
                            .buttonStyle(SecondaryButtonStyle())
                            .accessibilityHint(L10n.text("apple.clientdevicesview.disconnects_this_device_from_the_computer.19cd3aac"))
                    }
                } else {
                    liveStats
                    reach
                }
                identity
                software
                work
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
        .task(id: machine.machineID) {
            usageRequested = true
            await devices.load(machines: account.account?.machines ?? [machine],
                               days: DeviceHistory.days(for: account.account?.tier))
        }
    }

    private var showsSpend: Bool {
        machine.isHost && !isThisDevice
    }

    private var spend: some View {
        VStack(alignment: .leading, spacing: 2) {
            if let usage {
                Text(usage.value.formatted)
                    .font(ClientType.figure)
                    .foregroundStyle(Theme.accent)
                    .minimumScaleFactor(0.6)
                    .lineLimit(1)
                Text(L10n.text("apple.clientdevicesview.at_api_list_price_0.32cb2c25", "\(DeviceHistory.windowPhrase(days: usage.days))"))
                    .font(ClientType.caption)
                    .foregroundStyle(.secondary)
                Text(detail(usage))
                    .font(ClientType.caption)
                    .foregroundStyle(.secondary)
                    .padding(.top, 2)
            } else if !usageRequested || devices.isLoading {
                ProgressView(L10n.text("apple.clientdevicesview.loading_usage"))
                    .frame(maxWidth: .infinity, minHeight: 60, alignment: .leading)
            } else if devices.errorMessage != nil {
                Text(L10n.text("apple.clientdevicesview.usage_unavailable"))
                    .font(ClientType.label.weight(.medium))
                Button(L10n.text("common.retry"), .refresh) {
                    Task { await devices.load(machines: account.account?.machines ?? [machine],
                                              days: DeviceHistory.days(for: account.account?.tier), force: true) }
                }
            } else {
                Text(L10n.text("apple.clientdevicesview.no_usage_recorded"))
                    .font(ClientType.label.weight(.medium))
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .overlay(alignment: .topTrailing) {
            FeatureMark(name: "mark_insights", size: 26)
                .accessibilityHidden(true)
        }
        .padding(Theme.Space.m)
        .cardSurface()
        .accessibilityElement(children: .combine)
    }

    private func detail(_ usage: MachineUsage) -> String {
        var parts = [
            usage.activeDays == 1 ? L10n.text("apple.clientdevicesview.1_active_day.1b05d320") : L10n.text("apple.clientdevicesview.0_active_days.16d30c85", "\(usage.activeDays)"),
            L10n.text("apple.clientdevicesview.0_events.a7742aab", "\(usage.events.formatted())"),
        ]
        if accountTotal > 0 {
            let share = Double(usage.valueMicros) / Double(accountTotal) * 100
            parts.append(String(format: "%.0f%% of the account", share))
        }
        return parts.joined(separator: ", ")
    }

    private var nameField: some View {
        VStack(alignment: .leading, spacing: Theme.Space.s) {
            Text(L10n.text("apple.clientdevicesview.name.dcd1d522"))
                .font(ClientType.caption)
                .foregroundStyle(.secondary)
            TextField(L10n.text("apple.clientdevicesview.name_this_device.ab6b2bc7"), text: $draft)
                .textFieldStyle(.themed)
                .autocorrectionDisabled()
                .focused($editingName)
                .submitLabel(.done)
                .onSubmit { Task { await saveName() } }
            HStack(spacing: Theme.Space.s) {
                Button(savingName ? L10n.text("apple.clientdevicesview.saving.23e39291") : L10n.text("common.save"), .save) {
                    Task { await saveName() }
                }
                .clientProminentStyle()
                .tint(Theme.accent)
                .disabled(savingName)
                Button(L10n.text("common.cancel"), .dismiss, role: .cancel) {
                    renaming = false
                    renameError = nil
                }
                .font(ClientType.caption.weight(.semibold))
                .tint(Theme.accent)
            }
            Text(L10n.text("apple.clientdevicesview.empty_puts_back_the_name_the_device_gives.9bb5bd6d"))
                .font(ClientType.caption)
                .foregroundStyle(.tertiary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func saveName() async {
        guard !savingName, !Task.isCancelled, let owner = WorkSessionContext.shared.scope else { return }
        guard let id = machine.machineID, !id.isEmpty else {
            renameError = L10n.text("apple.clientdevicesview.this_device_has_no_id_on_the_account_yet.5edab834")
            return
        }
        savingName = true
        defer { savingName = false }
        do {
            let wanted = draft.trimmingCharacters(in: .whitespacesAndNewlines)
            try await Bridge.renameAccountMachine(id: id, name: wanted)
            guard !Task.isCancelled, owner == WorkSessionContext.shared.scope else { return }
            renamedTo = wanted
            renameError = nil
            renaming = false
            await onRenamed()
        } catch {
            guard !Task.isCancelled, owner == WorkSessionContext.shared.scope else { return }
            renameError = FriendlyError.from(error.localizedDescription).message
        }
    }

    private var reach: some View {
        VStack(alignment: .leading, spacing: Theme.Space.s) {
            ClientSectionTitle(title: L10n.text("apple.clientdevicesview.reach.2068b81b"), mark: "mark_host")
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

    @ViewBuilder
    private var work: some View {
        if !isThisDevice,
           let key = machine.publicIdentity,
           !key.isEmpty,
           machine.isHost {
            VStack(alignment: .leading, spacing: Theme.Space.s) {
                ClientSectionTitle(title: L10n.text("common.projects"), mark: "mark_folder")
                NavigationLink {
                    ClientFolderPicker(peer: key, hostName: DeviceCopy.name(current)) { _ in }
                } label: {
                    DeviceActionRow(
                        title: L10n.text("apple.clientdevicesview.choose_a_folder.5c71b8cd"),
                        subtitle: L10n.text("apple.clientdevicesview.register_a_folder_already_on_this_computer.31c7d112"),
                        icon: .reveal
                    )
                }
                .buttonStyle(DeviceActionRowStyle())
                NavigationLink {
                    ClientCloneRepository(peer: key, hostName: DeviceCopy.name(current)) { _ in }
                } label: {
                    DeviceActionRow(
                        title: L10n.text("apple.clientdevicesview.clone_a_repository.749e5d4d"),
                        subtitle: L10n.text("apple.clientdevicesview.run_git_on_this_computer_and_register_the.d6fc5a8e"),
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
            ClientSectionTitle(title: L10n.text("apple.clientdevicesview.what_this_is.45d2766e"), mark: "mark_device")
            if renaming {
                nameField
            } else {
                HStack(alignment: .firstTextBaseline) {
                    DetailLine(
                        label: L10n.text("apple.clientdevicesview.name.dcd1d522"),
                        value: current.label?.isEmpty == false
                            ? current.label ?? ""
                            : "not named on this account"
                    )
                    Spacer(minLength: Theme.Space.s)
                    Button(L10n.text("common.rename"), .edit) {
                        draft = current.label ?? ""
                        renaming = true
                        editingName = true
                    }
                    .font(ClientType.caption.weight(.semibold))
                    .tint(Theme.accent)
                    .frame(minHeight: 44)
                }
            }
            if let renameError {
                Text(renameError)
                    .font(ClientType.caption)
                    .foregroundStyle(Theme.danger)
            }
            if let platform = machine.platform, !platform.isEmpty {
                DetailLine(label: L10n.text("apple.clientdevicesview.what_it_runs.ba619d80"), value: platform)
            }
            if let id = machine.machineID {
                DetailLine(label: L10n.text("apple.clientdevicesview.device_id.4ad41656"), value: id)
            }
            if machine.reportsArchiveSync {
                DetailLine(label: L10n.text("apple.clientdevicesview.last_sync.71967fca"), value: DeviceCopy.lastSync(machine))
            } else if let seen = formatRelativeDate(machine.lastSeenAt) {
                DetailLine(label: L10n.text("apple.clientdevicesview.last_used.830ec7f8"), value: seen)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(Theme.Space.m)
        .cardSurface()
    }
}

struct DeviceActionRow: View {
    let title: String
    let subtitle: String
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
        }
    }
}

private enum DeviceCopy {
    static func name(_ machine: Machine) -> String {
        if let label = machine.label, !label.isEmpty { return label }
        if let platform = machine.platform,
           let family = platform.split(separator: "·").first?
               .split(separator: " ").first,
           !family.isEmpty {
            return "\(family) \(machine.isHost ? "computer" : "device")"
        }
        return L10n.text("apple.clientdevicesview.unnamed_device.6aba593f")
    }

    static func caption(_ machine: Machine, isThisDevice: Bool = false) -> String {
        let status = statusLine(machine, isThisDevice: isThisDevice)
        guard machine.label?.isEmpty != false, let id = machine.machineID else {
            return status
        }
        return "\(shortID(id)) · \(status)"
    }

    static func statusLine(_ machine: Machine, isThisDevice: Bool) -> String {
        if isThisDevice || machine.online == true {
            return L10n.text("apple.clientdevicesview.awake_now.64f95f4c")
        }
        if machine.isHost {
            if machine.publicIdentity?.isEmpty == false {
                if let seen = formatRelativeDate(machine.lastSeenAt) {
                    return L10n.text("apple.clientdevicesview.asleep_last_seen_0.6ef899b9", "\(seen)")
                }
                return L10n.text("apple.clientdevicesview.asleep.60135e8f")
            }
            return L10n.text("apple.clientdevicesview.not_set_up_for_remote.3db4bb28")
        }
        if let seen = formatRelativeDate(machine.lastSeenAt) {
            return L10n.text("apple.clientdevicesview.last_seen_0.77ac00d1", "\(seen)")
        }
        return L10n.text("apple.clientdevicesview.has_not_reported_in_yet.88f189cb")
    }

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
        if isThisDevice { return L10n.text("apple.clientdevicesview.this_is_the_device_you_are_holding.19fe2976") }
        if machine.online == true {
            return L10n.text("apple.clientdevicesview.awake_and_reachable_through_the_tunnel_fro.81ab5be0")
        }
        if machine.publicIdentity?.isEmpty == false {
            return L10n.text("apple.clientdevicesview.asleep_it_has_a_connection_key_so_it_can_b.8982cace")
        }
        return L10n.text("apple.clientdevicesview.not_set_up_for_remote_reach_turn_on_reach.9d22e688")
    }

    static func rowLabel(_ machine: Machine, usage: MachineUsage?, isThisDevice: Bool) -> String {
        var parts = [name(machine)]
        if isThisDevice { parts.append(L10n.text("apple.clientdevicesview.this_device.cf3cc23e")) }
        parts.append(statusLine(machine, isThisDevice: isThisDevice))
        if let usage {
            parts.append(
                L10n.text("apple.clientdevicesview.0_at_api_list_price_1.3531a559", "\(usage.value.formatted)", "\(DeviceHistory.windowPhrase(days: usage.days))")
            )
        }
        return parts.joined(separator: ", ")
    }
}

enum DeviceHistory {
    static func days(for tier: String?) -> Int {
        switch tier?.lowercased() {
        case "legend", "patron": return 3650
        case "supporter": return 365
        default: return 30
        }
    }

    static func windowPhrase(days: Int) -> String {
        if days >= 1000 { return L10n.text("apple.clientdevicesview.all_time.c79ddf2b") }
        if days >= 360 { return L10n.text("apple.clientdevicesview.the_last_year.ce4cc449") }
        if days == 1 { return L10n.text("apple.clientdevicesview.the_last_day.8319fd61") }
        return L10n.text("apple.clientdevicesview.the_last_0_days.1bfce3a7", "\(days)")
    }
}

#endif
