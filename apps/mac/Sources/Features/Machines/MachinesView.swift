// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
//
// Source-available for review, NOT open source. See LICENSE: no rights to
// redistribute, publish, or ship a build are granted. Read it, study it, run
// your own build of it.
// "tokenstat" is a trademark of pueev OU. See TRADEMARK.md.

import SwiftUI
#if os(macOS)
import AppKit
#endif

/// This machine, who may reach it, and who it can reach.
///
/// The screen is ordered by what somebody came here to do: decide about a
/// machine that is knocking, then read this machine's own two words to compare
/// with the other end, then add something new.
///
/// It says nothing about ports, addresses or keys. A person setting up their
/// second computer has a laptop and a desktop, not a host and a socket, and the
/// vocabulary here follows `docs/remote-transport.md`: a name, two words to
/// compare, and one code to paste. The raw facts stay one disclosure away for
/// whoever is debugging their own network.
struct MachinesView: View {
    @State private var confirmForget: Peer?
    @State private var confirmRevoke: Peer?

    @Bindable var model: MachinesModel
    /// Where to send somebody who clicks the SSH card. The shell decides which
    /// section they land on, because this card asks for "servers" and has no
    /// business picking between Hosts and Keys.
    var onNavigate: ((NavigationRequest) -> Void)?
    var onInspect: (() -> Void)?
    var onSignIn: (() -> Void)?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var addingDevice = false
    @State private var encryptionExpanded = false
    private enum DevicePage: String, CaseIterable { case devices = "Devices", access = "Access" }
    @State private var devicePage: DevicePage = .devices
    @State private var deviceSearch = ""
    /// The account machine waiting on a Remove confirmation. Destructive on
    /// the server, so it never happens from a single click.
    @State private var pendingUnlink: Machine?
    /// Which account device is having its name edited, by machine id. Inline
    /// rather than a sheet: naming a device is not a decision with
    /// consequences, it is how the list reads.
    @State private var renamingID: String?
    #if os(macOS)
    /// Devices asking for something. The same object the toast, the sheet and
    /// the notification answer through, so all four agree about what is still
    /// waiting.
    @State private var deviceRequests = DeviceAccessRequests.shared
    #endif

    var body: some View {
        VStack(spacing: 0) {
            DetailChromeBar {
                sshAccess
            }
            if model.remoteReachAllowed {
                HStack(spacing: Theme.Space.m) {
                    SegmentedTabs(options: DevicePage.allCases, selection: $devicePage)
                        .frame(maxWidth: 320)
                        .accessibilityLabel(L10n.text("apple.machinesview.device_management.1a7c41d5"))
                    Spacer(minLength: 0)
                    Button(L10n.text("common.add_device"), .create) { addingDevice = true }
                        .buttonStyle(AccentButtonStyle(small: true))
                }
                .padding(Theme.Space.m)
                ThemeRule()
            }
            ScrollView {
                VStack(alignment: .leading, spacing: Theme.Space.m) {
                    if let message = model.errorMessage {
                        ErrorBanner(message: message) { Task { await model.load() } }
                    }
                    if !Bridge.isHosted {
                        hostSetup
                    }
                    if model.remoteReachAllowed {
                        remoteReadyContent
                    } else {
                        remoteLockedContent
                    }
                }
                .padding(Theme.Space.m)
            }
        }
        .navigationTitle(L10n.text("common.devices"))
        .background(Theme.background)
        .confirmationDialog(
            L10n.text("apple.machinesview.remove_from_account.a3010e43"),
            isPresented: Binding(
                get: { pendingUnlink != nil },
                set: { if !$0 { pendingUnlink = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button(L10n.text("common.remove"), role: .destructive) {
                if let machine = pendingUnlink {
                    Task { await model.unlink(machine) }
                }
                pendingUnlink = nil
            }
            Button(L10n.text("common.cancel"), role: .cancel) { pendingUnlink = nil }
        } message: {
            Text(pendingUnlink.map {
                L10n.text("apple.machinesview.0_will_be_removed_from_this_account_and_it.d003b06e", "\(model.resolvedName(for: $0) ?? $0.displayName)")
            } ?? "")
        }
        .overlay(alignment: .bottomTrailing) {
            TransientToast(message: $model.noticeMessage, severity: .success)
                .padding(Theme.Space.l)
        }
        .task {
            if model.identity == nil { await model.load() }
            await model.ensureHelper()
            // The sleep is where cancellation lands when this screen goes away,
            // and it throws rather than returning, so the check afterwards is
            // what stops a final refresh going out on a torn-down view.
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(5))
                guard !Task.isCancelled else { break }
                await model.refresh()
            }
        }
        // The sidebar sweep is the source of truth for who is actually
        // connected; keep the Connect/Disconnect buttons in step with it.
        .onReceive(NotificationCenter.default.publisher(for: .remotePeerDidConnect)) { note in
            if let key = note.object as? String {
                model.markConnected(key)
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .remotePeerDidDisconnect)) { note in
            if let key = note.object as? String {
                model.markDisconnected(key)
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .remotePeerBecameUnreachable)) { note in
            if let key = note.object as? String {
                model.markDisconnected(key)
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .tokenstatEntitlementDidChange)) { _ in
            Task { await model.load() }
        }
        .sheet(isPresented: $addingDevice) {
            PairingForm(
                showsCard: false,
                onClose: { addingDevice = false }
            ) { key, label, address in
                await model.pair(key: key, label: label, address: address)
                addingDevice = false
            }
        }
    }

    /// A way in, not a place. SSH is a section in the sidebar now, and this
    /// card is here because Devices is where people looked for it first.
    private var sshAccess: some View {
        #if os(macOS)
        Button { onNavigate?(.ssh) } label: { sshAccessLabel }
            .buttonStyle(.plain)
        #else
        NavigationLink {
            SSHLibraryView(vaultTier: model.vaultTier)
        } label: { sshAccessLabel }
        .buttonStyle(.plain)
        #endif
    }

    private var sshAccessLabel: some View {
        Label(L10n.text("apple.machinesview.ssh_hosts.6e8d5967"), systemImage: "terminal")
            .font(Theme.callout.weight(.medium))
            .foregroundStyle(Theme.accent)
            .padding(.horizontal, Theme.Space.s)
            .help(L10n.text("apple.machinesview.saved_servers_keys_and_command_snippets.0ac59dee"))
    }

    /// The full pairing screen: approvals, this machine, peers, add, e2e.
    @ViewBuilder
    private var remoteReadyContent: some View {
        // First, because these are the only things here that are waiting on a
        // person. Everything else can be read at leisure.
        #if os(macOS)
        // Above pairing, because a device asking for either grant is already
        // paired: it got far enough to ask. A toast names a request as it
        // arrives, and this is where somebody who let the toast go, or was
        // away when it landed, finds the question again.
        if !deviceRequests.pending.isEmpty {
            askingForAccess
        }
        #endif
        if !model.pending.isEmpty {
            waitingForApproval
        }
        switch devicePage {
        case .devices:
            thisMachine()
            #if os(macOS)
            alwaysOnHost
            #endif
            SearchField(text: $deviceSearch, prompt: L10n.text("apple.machinesview.find_a_device.d8cd5f42"))
            if !filteredAccountMachines.isEmpty { accountDevices }
            if !filteredKnownMachines.isEmpty { knownMachines }
            if !deviceSearch.isEmpty && filteredAccountMachines.isEmpty && filteredKnownMachines.isEmpty {
                Text(L10n.text("apple.machinesview.no_devices_match_0.e9b713e9", "\(deviceSearch)"))
                    .font(Theme.callout).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, minHeight: 100)
            }
            if model.accountMachines.isEmpty && unlistedKnown.isEmpty { addDeviceAction }
        case .access:
            Text(L10n.text("apple.machinesview.choose_what_connected_devices_can_do_on_th.8a7b1610"))
                .font(Theme.callout).foregroundStyle(.secondary)
            DevicePermissionCard(peers: model.known.filter { $0.trust == .approved })
            DevicePermissionCard(peers: [], localOnly: true)
            encryptionNote
        }
    }

    /// Free and Supporter already share usage. The pairing chrome, the
    /// disabled tunnel switch and a See plans link at the foot of a long
    /// scroll are the wrong empty state: the action that ends it never
    /// reaches the first screenful. Match the phone Remote tab: one
    /// upgrade card, the machine list, then e2e.
    @ViewBuilder
    private var remoteLockedContent: some View {
        remotePlanEmpty
        #if os(macOS)
        alwaysOnHost
        #endif
        if !model.accountMachines.isEmpty {
            lockedMachineList
        }
        encryptionNote
    }

    private var remotePlanEmpty: some View {
        EmptyState(
            symbol: "lock.laptopcomputer",
            title: L10n.text("apple.machinesview.remote_is_on_patron.d25dea13"),
            message: model.account?.signedIn == true
                ? L10n.text("apple.machinesview.this_mac_already_shares_the_account_and_se.9ac4290a")
                : L10n.text("apple.machinesview.sign_in_with_a_patron_or_legend_account_to.af6beaa7"),
            mark: "mark_plan"
        ) {
            Link(L10n.text("apple.machinesview.see_plans.d9898933"), destination: URL(string: "https://tokenstat.ai/pricing")!)
                .buttonStyle(AccentButtonStyle())
        }
        .padding(Theme.Space.m)
        .background(Theme.panel, in: RoundedRectangle(cornerRadius: Theme.cardRadius))
        .overlay(RoundedRectangle(cornerRadius: Theme.cardRadius).strokeBorder(Theme.border))
    }

    /// Names and presence only. Connect, revoke and forget belong on
    /// the plan that can actually open a tunnel.
    private var lockedMachineList: some View {
        Card(
            title: L10n.text("apple.machinesview.devices_on_this_account.50d8cf5c"),
            subtitle: L10n.text("apple.machinesview.usage_from_every_linked_device_is_already.9f16ae77"),
            mark: "mark_device"
        ) {
            VStack(spacing: 0) {
                ForEach(model.listedAccountMachines) { machine in
                    lockedMachineRow(machine)
                    if machine.id != model.listedAccountMachines.last?.id {
                        ThemeRule()
                    }
                }
            }
        }
    }

    private func lockedMachineRow(_ machine: Machine) -> some View {
        let isSelf = machine.machineID == model.account?.thisMachineID
            || machine.publicIdentity == model.identity?.key
        let resolved = model.resolvedName(for: machine)
        let symbol = machine.isHost
            ? (isSelf ? "laptopcomputer" : ClientDeviceIcon.symbol(for: machine))
            : ClientDeviceIcon.symbol(for: machine)
        return HStack(spacing: Theme.Space.s) {
            Image(systemName: symbol)
                .foregroundStyle(isSelf ? Theme.accent : .secondary)
                .frame(width: 24)
            if isSelf {
                Circle()
                    .fill(Theme.accent)
                    .frame(width: 8, height: 8)
            } else {
                StatusDot(online: machine.online)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(deviceTitle(resolved: resolved, machine: machine))
                    .font(Theme.callout.weight(.medium))
                Text(statusLine(for: machine, isSelf: isSelf))
                    .font(Theme.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(.vertical, Theme.Space.s)
        .accessibilityElement(children: .combine)
    }

    private var addDeviceAction: some View {
        Card(
            title: L10n.text("apple.machinesview.add_a_device.5469d968"),
            subtitle: L10n.text("apple.machinesview.paste_the_key_from_the_other_machine_every.75ebefc4"),
            mark: "mark_device",
            accessory: AnyView(
                Button(L10n.text("common.add_device"), .create) { addingDevice = true }
                    .buttonStyle(AccentButtonStyle(small: true))
            )
        )
    }

    private var hostSetup: some View {
        Card(title: L10n.text("apple.machinesview.this_mac_is_not_ready_for_background_conne.78859719"), subtitle: L10n.text("apple.machinesview.the_app_can_still_show_local_data_a_small.67ec2880"), mark: "mark_host") {
            HStack(spacing: Theme.Space.s) {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(Theme.success)
                Text(L10n.text("apple.machinesview.local_app_mode.74554ff1"))
                    .font(Theme.callout.weight(.medium))
                Spacer()
                Button {
                    Task { await model.setupHelper() }
                } label: {
                    if model.settingUpHelper {
                        ProgressView().controlSize(.small)
                    } else {
                        ActionIcon.settings.label(L10n.text("apple.machinesview.set_up_helper.0ba42af7"))
                    }
                }
                .buttonStyle(AccentButtonStyle())
                .disabled(model.settingUpHelper)
            }
        }
    }

    // MARK: - This machine

    private func thisMachine(fillsHeight: Bool = false) -> some View {
        Card(
            title: L10n.text("apple.machinesview.connection_settings.b4ddb3c1"),
            subtitle: L10n.text("apple.machinesview.identity_and_remote_access_for_this_mac.ca73eeb3"),
            mark: "mark_device",
            fillsHeight: fillsHeight
        ) {
            VStack(alignment: .leading, spacing: Theme.Space.m) {
                if let identity = model.identity {
                    VStack(alignment: .leading, spacing: Theme.Space.m) {
                        LabeledContent(L10n.text("apple.machinesview.name.dcd1d522")) {
                            MachineNameField(identity: identity) { name in
                                await model.rename(to: name)
                            }
                        }
                        if let words = model.words {
                            LabeledContent(L10n.text("apple.machinesview.known_as.9076e6ab")) {
                                // The comparison a person actually performs.
                                // The fingerprint and the key still exist and
                                // are one disclosure away, under Connection
                                // details. The words are derived from a public
                                // key: there is nothing private in them, so
                                // they are shown plain and selectable.
                                Text(words)
                                    .font(Theme.font(13, weight: .medium))
                                    .foregroundStyle(Theme.accent)
                                    .textSelection(.enabled)
                            }
                        }
                    }
                    .transition(.smoothIn(reduceMotion: reduceMotion))
                } else {
                    // The identity comes from the daemon, so this card is empty
                    // for a moment on a cold launch. Two grey rows keep the card
                    // the height it will be rather than letting the whole screen
                    // shuffle upward when the name arrives.
                    VStack(alignment: .leading, spacing: Theme.Space.s) {
                        Skeleton.Bar(width: 220)
                        Skeleton.Bar(width: 160)
                    }
                    .transition(.opacity)
                }
                ThemeRule()
                serving
                Text(
                    model.accountMachines.isEmpty
                        ? L10n.text("apple.machinesview.machines_connect_through_the_tokenstat_tun.afcd7e99")
                        : L10n.text("apple.machinesview.open_devices_to_see_your_computers_and_pho.bc894ce6")
                )
                .font(Theme.caption)
                .foregroundStyle(.tertiary)
            }
            .animation(.easeOut(duration: 0.22), value: model.identity != nil)
            .contentShape(.rect)
            .onTapGesture { model.selectThisMachine() }
        }
        .overlay(
            RoundedRectangle(cornerRadius: Theme.cardRadius)
                .strokeBorder(
                    model.selectedKind == .thisMachine ? Theme.accent.opacity(0.45) : Color.clear,
                    lineWidth: 1
                )
        )
    }

    @ViewBuilder
    private var serving: some View {
        Group {
            if let status = model.status {
                let allowed = model.remoteReachAllowed
                let planExpired = status.tunnel
                    && status.tunnelError?.contains("not_on_this_plan") == true
                VStack(alignment: .leading, spacing: Theme.Space.s) {
                    // A setting, not a dashboard card. Keeping its label,
                    // explanation and switch in one compact preference row
                    // makes the control easy to spot without overpowering the
                    // identity details above it.
                    HStack(alignment: .center, spacing: Theme.Space.m) {
                        HStack(spacing: Theme.Space.s) {
                            Image(systemName: "rectangle.3.group.bubble.left")
                                .font(Theme.font(15, weight: .medium))
                                .foregroundStyle(Theme.accent)
                                .frame(width: 30, height: 30)
                                .background(Theme.accentSoft, in: RoundedRectangle(cornerRadius: 8))
                            VStack(alignment: .leading, spacing: 2) {
                                Text(L10n.text("apple.machinesview.enable_remote_access"))
                                    .font(Theme.callout.weight(.semibold))
                                Text(L10n.text("apple.machinesview.connect_to_this_mac_from_your_signed_in_de.a81e4e37"))
                                    .font(Theme.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        Spacer(minLength: Theme.Space.m)
                        Toggle(L10n.text("apple.machinesview.enable_remote_access"), isOn: Binding(
                            get: { allowed && status.tunnel },
                            set: { enabled in Task { await model.setTunnel(enabled) } }
                        ))
                        .toggleStyle(.switch)
                        .labelsHidden()
                        .accessibilityLabel(L10n.text("apple.machinesview.enable_remote_access"))
                        .disabled(!allowed)
                        .fixedSize()
                    }
                    // Keep controls in the inspector's shared trailing
                    // column. `Toggle` does not distribute its label and
                    // track by itself, so this explicit spacer pins the track
                    // to the same edge as every other control.
                    .frame(maxWidth: .infinity, alignment: .leading)

                    Label(
                        allowed && status.tunnel
                            ? L10n.text("apple.machinesview.remote_access_is_on_this_mac_will_be_reach.d98834a9")
                            : L10n.text("apple.machinesview.turn_this_on_to_make_this_mac_reachable_fr.d2c43ce7"),
                        systemImage: allowed && status.tunnel ? "checkmark.circle.fill" : "info.circle"
                    )
                    .font(Theme.caption)
                    .foregroundStyle(allowed && status.tunnel ? Theme.accent : .secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)

                    Text(L10n.text("apple.machinesview.connections_are_end_to_end_encrypted_scree.fca19521"))
                        .font(Theme.caption)
                        .foregroundStyle(.tertiary)

                    if !allowed {
                        // The relay enforces the plan at every HELLO; this is
                        // the courtesy copy of the same gate, so nobody is
                        // invited to flip a switch the relay will refuse. A
                        // switch that was left on reads as off until the
                        // account qualifies again.
                        VStack(alignment: .leading, spacing: Theme.Space.s) {
                            Text(model.account?.signedIn == true
                                ? L10n.text("apple.machinesview.this_computer_and_another_device_already_s.c3dc1438")
                                : L10n.text("apple.machinesview.remote_reach_needs_a_signed_in_patron_acco.7f190960"))
                                .font(Theme.callout.weight(.medium))
                            Text(model.account?.signedIn == true
                                ? L10n.text("apple.machinesview.free_and_supporter_add_up_usage_from_every.0b5ed1e8")
                                : L10n.text("apple.machinesview.sign_in_with_an_account_that_includes_it_t.3e4fb59e"))
                                .font(Theme.caption)
                                .foregroundStyle(.secondary)
                            if model.account?.signedIn == true {
                                Link(L10n.text("apple.machinesview.see_plans.d9898933"), destination: URL(string: "https://tokenstat.ai/pricing")!)
                                    .font(Theme.caption.weight(.semibold))
                            }
                        }
                        .padding(Theme.Space.s)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(Theme.accentSoft.opacity(0.55), in: RoundedRectangle(cornerRadius: Theme.cardRadius))
                    } else if planExpired {
                        Banner(
                            text: L10n.text("apple.machinesview.your_plan_no_longer_includes_remote_reach.fc6a711f"),
                            severity: .warning
                        )
                    }

                    if status.tunnel && status.tunnelOnline == false && !planExpired {
                        // The toggle is on but the daemon is not holding a
                        // socket. The plan gate, a revoked token and a dead
                        // endpoint all land here, and each needs different
                        // words from "wait".
                        if let raw = status.tunnelError {
                            ErrorBanner(message: raw) {
                                if FriendlyError.from(raw).requiresSignIn {
                                    onSignIn?()
                                } else {
                                    Task { await model.load() }
                                }
                            }
                        } else {
                            Banner(text: L10n.text("apple.machinesview.remote_reach_is_on_but_the_tunnel_has_not.024544f1"), severity: .warning)
                        }
                    }
                    if status.tunnel, status.tunnelOnline == true, status.tunnelRegistered == false {
                        Banner(
                            text: L10n.text("apple.machinesview.this_machine_is_on_the_tunnel_but_the_acco.7b29b022"),
                            severity: .warning
                        )
                    }
                }
                .transition(.smoothIn(reduceMotion: reduceMotion))
            }
        }
        .confirmationDialog(
            L10n.text("apple.machinesview.forget_this_device.6bddebb5"),
            isPresented: Binding(
                get: { confirmForget != nil },
                set: { if !$0 { confirmForget = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button(L10n.text("apple.machinesview.forget.a6bd489d"), role: .destructive) {
                if let peer = confirmForget {
                    Task { await model.forget(peer) }
                }
                confirmForget = nil
            }
            Button(L10n.text("apple.machinesview.keep_it.fdce5da2"), role: .cancel) { confirmForget = nil }
        } message: {
            Text(L10n.text("apple.machinesview.it_is_removed_from_this_machine_s_peer_lis.0fe4b5c8"))
        }
        .confirmationDialog(
            L10n.text("apple.machinesview.revoke_access.8138e6ff"),
            isPresented: Binding(
                get: { confirmRevoke != nil },
                set: { if !$0 { confirmRevoke = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button(L10n.text("apple.machinesview.revoke.87e6d00b"), role: .destructive) {
                if let peer = confirmRevoke {
                    Task { await model.revoke(peer) }
                }
                confirmRevoke = nil
            }
            Button(L10n.text("apple.machinesview.keep_access.68cfc92d"), role: .cancel) { confirmRevoke = nil }
        } message: {
            Text(L10n.text("apple.machinesview.that_device_can_no_longer_reach_this_machi.e0406f8e"))
        }
        .animation(.easeOut(duration: 0.22), value: model.status != nil)
    }

    #if os(macOS)
    /// Devices that have asked for something and are still waiting.
    ///
    /// The same answers the sheet offers, in the one place somebody would go
    /// looking after a toast or a banner has gone.
    private var askingForAccess: some View {
        Card(
            title: L10n.text("apple.machinesview.waiting_for_you.9f760ab2"),
            subtitle: L10n.text("apple.machinesview.approve_only_a_device_you_recognise_you_ca.69c0725e"),
            mark: "mark_device"
        ) {
            VStack(spacing: Theme.Space.s) {
                ForEach(deviceRequests.pending, id: \.id) { request in
                    HStack(alignment: .center, spacing: Theme.Space.m) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(request.headline)
                                .font(Theme.callout.weight(.medium))
                            Text(request.detail)
                                .font(Theme.caption)
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        Spacer(minLength: Theme.Space.s)
                        // Both answers for a screen, whichever was asked for.
                        // Offering only what the device happened to name left
                        // no way to hand over the mouse without sending
                        // somebody back to their phone to ask again.
                        if request.kind == .screen {
                            Button(L10n.text("apple.machinesview.view_only.9b4c6c85"), .preview) {
                                Task { await deviceRequests.answer(request, view: true, control: false) }
                            }
                            .buttonStyle(SecondaryButtonStyle())
                            Button(L10n.text("apple.machinesview.full_access.f19611c6"), .approve) {
                                Task { await deviceRequests.answer(request, view: true, control: true) }
                            }
                            .buttonStyle(AccentButtonStyle())
                        } else {
                            Button(L10n.text("apple.machinesview.allow.e213c161"), .approve) {
                                Task { await deviceRequests.answer(request, view: true, control: false) }
                            }
                            .buttonStyle(AccentButtonStyle())
                        }
                        Button(L10n.text("apple.machinesview.deny.05a2d733"), .revoke, role: .destructive) {
                            Task { await deviceRequests.answer(request, view: false, control: false) }
                        }
                        .buttonStyle(SecondaryButtonStyle())
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                if let error = deviceRequests.errorMessage {
                    Text(error)
                        .font(Theme.caption)
                        .foregroundStyle(Theme.danger)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
    }
    #endif

    private var waitingForApproval: some View {
        Card(
            title: L10n.text("apple.machinesview.needs_your_approval.635ea5c1"),
            subtitle: L10n.text("apple.machinesview.nothing_can_run_here_until_you_approve_it.1dbb95eb"),
            mark: "mark_device"
        ) {
            VStack(spacing: Theme.Space.s) {
                ForEach(model.pending) { peer in
                    PeerRow(
                        peer: peer,
                        resolvedName: model.accountName(for: peer),
                        isSelected: model.selectedKind == .peer(peer.key)
                    ) {
                        HStack(spacing: Theme.Space.s) {
                            Button(L10n.text("apple.machinesview.approve.6007acbe"), .approve) { Task { await model.approve(peer) } }
                                .buttonStyle(AccentButtonStyle())
                            Button(L10n.text("apple.machinesview.forget.a6bd489d"), .delete, role: .destructive) { confirmForget = peer }
                                .buttonStyle(SecondaryButtonStyle())
                        }
                    }
                    .onTapGesture { inspectPeer(peer) }
                    .accessibilityIdentifier("device.details.peer.\(peer.key)")
                    .accessibilityAction(named: L10n.text("apple.machinesview.details.45989de4")) { inspectPeer(peer) }
                }
                Text(L10n.text("apple.machinesview.approve_only_devices_you_recognize_you_can.e599993b"))
                .font(Theme.caption)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    private var filteredAccountMachines: [Machine] {
        let query = deviceSearch.trimmingCharacters(in: .whitespacesAndNewlines)
        return model.listedAccountMachines.filter { machine in
            let isSelf = machine.machineID == model.account?.thisMachineID
                || machine.publicIdentity == model.identity?.key
            return query.isEmpty || [
                deviceTitle(resolved: model.resolvedName(for: machine), machine: machine),
                machine.platform ?? "", machine.machineID ?? "",
                machine.isHost ? "Computer" : "Phone tablet",
                statusLine(for: machine, isSelf: isSelf),
            ].contains { $0.localizedStandardContains(query) }
        }
    }

    private var filteredKnownMachines: [Peer] {
        let query = deviceSearch.trimmingCharacters(in: .whitespacesAndNewlines)
        return unlistedKnown.filter { peer in
            query.isEmpty || [peer.label, model.accountName(for: peer) ?? "", peer.words ?? "",
                              peer.trust == .approved ? "Access allowed" : "Access removed"]
                .contains { $0.localizedStandardContains(query) }
        }
    }

    private var knownMachines: some View {
        Card(title: L10n.text("apple.machinesview.other_devices.4e027dbb"), subtitle: L10n.text("apple.machinesview.devices_known_to_this_mac_outside_your_acc.b77734a5"), mark: "mark_device", fillsHeight: true) {
            VStack(spacing: Theme.Space.s) {
                ForEach(filteredKnownMachines) { peer in
                    PeerRow(
                        peer: peer,
                        resolvedName: model.accountName(for: peer),
                        symbol: model.peerSymbol(for: peer),
                        isSelected: model.selectedKind == .peer(peer.key)
                    ) {
                        HStack(spacing: Theme.Space.s) {
                            ToolbarMenuButton(help: L10n.text("apple.machinesview.manage_0.d77d63f8", "\(peer.label.isEmpty ? (model.accountName(for: peer) ?? "device") : peer.label)")) {
                                if peer.trust == .approved {
                                    Button(L10n.text("apple.machinesview.revoke.87e6d00b"), .revoke, role: .destructive) { confirmRevoke = peer }
                                        .buttonStyle(SecondaryButtonStyle())
                                } else {
                                    Button(L10n.text("apple.machinesview.approve.6007acbe"), .approve) { Task { await model.approve(peer) } }
                                        .buttonStyle(SecondaryButtonStyle())
                                }
                                Button(L10n.text("apple.machinesview.forget.a6bd489d"), .delete, role: .destructive) { confirmForget = peer }
                                    .buttonStyle(SecondaryButtonStyle())
                            }
                            DeviceRowDisclosure()
                        }
                    }
                    .onTapGesture { inspectPeer(peer) }
                    .accessibilityIdentifier("device.details.peer.\(peer.key)")
                    .accessibilityAction(named: L10n.text("apple.machinesview.details.45989de4")) { inspectPeer(peer) }
                }
            }
            .transition(.smoothIn(reduceMotion: reduceMotion))
        }
        .animation(.easeOut(duration: 0.22), value: unlistedKnown.isEmpty)
    }

    /// Approved peers that the account list above does not already show.
    ///
    /// The same iPhone appeared twice, once as `m_1ab6c8e5d261fdab` under
    /// Account-linked devices and again as `mellow-zebra-reef` under Your
    /// devices, with different names and different buttons. One physical
    /// device, one row.
    ///
    /// A peer is only hidden where the row above carries the same actions for
    /// it, which is why the match is by identity rather than by name: dropping
    /// a device from here on a weaker match would leave nowhere to revoke it.
    private var unlistedKnown: [Peer] {
        let covered = Set(
            model.listedAccountMachines.compactMap { linkedPeer(for: $0)?.key }
        )
        return model.known.filter { !covered.contains($0.key) }
    }

    #if os(macOS)
    /// Whether this Mac stays a host after the app quits. Mirrors the Account
    /// screen's card so the setting sits where somebody is deciding whether
    /// other devices may reach this Mac.
    private var alwaysOnHost: some View {
        Card(
            title: L10n.text("apple.machinesview.always_on_host.f7990642"),
            subtitle: L10n.text("apple.machinesview.whether_the_host_helper_stays_up_after_you.dd1619f2"),
            mark: "mark_host",
            fillsHeight: true
        ) {
            VStack(alignment: .leading, spacing: Theme.Space.m) {
                if let policy = model.hostPolicy {
                    toggleRow(
                        L10n.text("apple.machinesview.keep_this_mac_reachable.99f1e1f6"),
                        detail: alwaysOnDetail(policy),
                        isOn: Binding(
                            get: { policy.alwaysOn },
                            set: { on in Task { await model.setAlwaysOnHost(on) } }
                        )
                    )
                    .disabled(model.isSavingHostPolicy)
                    if policy.alwaysOn && policy.hasInternalBattery {
                        Text(L10n.text("apple.machinesview.uses_more_power.a24adb34"))
                            .font(Theme.caption)
                            .foregroundStyle(.secondary)
                    }
                    if !policy.alwaysOn {
                        Text(L10n.text("apple.machinesview.automations_run_only_while_tokenstat_is_op.72980d54"))
                            .font(Theme.caption)
                            .foregroundStyle(.secondary)
                    }
                } else {
                    Text(L10n.text("apple.machinesview.the_host_helper_has_not_answered_yet.ed11e9fb"))
                        .font(Theme.callout)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    private func alwaysOnDetail(_ policy: HostPolicy) -> String {
        if policy.alwaysOn {
            return L10n.text("apple.machinesview.the_host_helper_keeps_running_after_you_qu.8da69cf5")
        }
        return L10n.text("apple.machinesview.the_host_helper_stops_when_you_quit_tokens.3285420e")
    }

    private func toggleRow(_ title: String, detail: String, isOn: Binding<Bool>) -> some View {
        HStack(alignment: .center, spacing: Theme.Space.m) {
            // Awake or asleep, as a picture. The paragraph beside it is
            // accurate and long, and this is the half somebody reads.
            Image(systemName: isOn.wrappedValue ? "bolt.horizontal.circle.fill" : "moon.zzz.fill")
                .font(Theme.font(22))
                .foregroundStyle(isOn.wrappedValue ? Theme.accent : Theme.stateIdle)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(Theme.callout)
                Text(detail)
                    .font(Theme.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: Theme.Space.m)
            Toggle("", isOn: isOn)
                .toggleStyle(.switch)
                .labelsHidden()
                .accessibilityLabel(L10n.text("apple.machinesview.always_on_host.f7990642"))
                .fixedSize()
        }
    }
    #endif

    private var accountDevices: some View {
        Card(title: L10n.text("apple.machinesview.your_devices.555eaa22"), subtitle: L10n.text("apple.machinesview.select_a_device_for_connection_details_pho.2c07fad5"), mark: "mark_device") {
            LazyVStack(spacing: Theme.Space.s) {
                ForEach(filteredAccountMachines) { machine in
                    // Phones are shown but never dialled: a client reaches a
                    // host, not the reverse (P5). Hiding them made a device
                    // somebody had signed in on look like it was not there.
                    // "This device" can also be matched by its key: a stale
                    // record whose id no longer equals thisMachineID must not
                    // suddenly look like a stranger with Connect buttons.
                    let isSelf = machine.machineID == model.account?.thisMachineID
                        || machine.publicIdentity == model.identity?.key
                    // The row's title: the machine's own name, or the name we
                    // know it by (this machine, or an approved peer) when the
                    // account has never named it. The code stays as the
                    // subtitle either way, so a resolved title never hides
                    // which machine the row is.
                    let resolved = model.resolvedName(for: machine)
                    let symbol = ClientDeviceIcon.symbol(for: machine)
                    HStack(alignment: .center, spacing: Theme.Space.m) {
                    HStack(alignment: .center, spacing: Theme.Space.s) {
                        Image(systemName: symbol)
                            .foregroundStyle(isSelf ? Theme.accent : .secondary)
                            .font(Theme.font(18))
                            .frame(width: 32, height: 32)
                            .background(Theme.accentSoft, in: RoundedRectangle(cornerRadius: 10))
                        if isSelf {
                            // This machine's own presence: the accent colour
                            // when the tunnel is actually up (so the row reads
                            // as "this device, reachable"), grey when remote
                            // reach is off or the socket is not connected.
                            Circle()
                                .fill(model.status?.tunnelOnline == true ? Theme.accent : .gray)
                                .frame(width: 8, height: 8)
                        } else {
                            // The industry-standard presence light, before the
                            // name: solid when the machine is reachable right
                            // now, blinking while its state is not confirmed,
                            // grey when it is definitively offline.
                            StatusDot(online: machine.online)
                        }
                        VStack(alignment: .leading, spacing: 2) {
                            // An unnamed machine is still known by name when it
                            // is this one or a peer this Mac has approved. Where
                            // nobody knows it, it gets a description of what it
                            // is rather than its primary key: `Machine
                            // m_c9826340c403872c` as a row title is a database
                            // showing through the window.
                            if renamingID != nil, renamingID == machine.machineID {
                                AccountNameField(
                                    machine: machine,
                                    placeholder: deviceTitle(resolved: resolved, machine: machine)
                                ) { name in
                                    renamingID = nil
                                    // This computer names itself: that writes
                                    // the local label and tells the account,
                                    // so the two agree. Renaming only the
                                    // account row would leave this Mac calling
                                    // itself one thing and the website another.
                                    if isSelf {
                                        await model.rename(to: name)
                                        await model.load()
                                    } else {
                                        await model.renameAccountMachine(machine, to: name)
                                    }
                                } onCancel: {
                                    renamingID = nil
                                }
                            } else {
                                Text(deviceTitle(resolved: resolved, machine: machine))
                                    .font(Theme.callout.weight(.medium))
                                    .lineLimit(1).truncationMode(.middle)
                            }
                            Text([machine.platform, statusLine(for: machine, isSelf: isSelf)]
                                .compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · "))
                                .font(Theme.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(2)

                        }
                        Spacer(minLength: 0)
                    }
                    VStack(alignment: .trailing, spacing: Theme.Space.s) {
                        autoConnectRow(machine, isSelf: isSelf)
                        deviceActions(machine, isSelf: isSelf)
                    }
                    .fixedSize(horizontal: true, vertical: false)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(Theme.Space.m)
                    .background(
                        model.selectedKind == .account(machine.machineID ?? machine.id)
                            ? Theme.rowSelected : Theme.background,
                        in: RoundedRectangle(cornerRadius: Theme.cardRadius)
                    )
                    .overlay(RoundedRectangle(cornerRadius: Theme.cardRadius)
                        .strokeBorder(model.selectedKind == .account(machine.machineID ?? machine.id)
                            ? Theme.accent.opacity(0.5) : Theme.border, lineWidth: 1))
                    .contentShape(.rect)
                    .onTapGesture { inspectAccount(machine) }
                    // The whole row opens the details, so the keyboard and
                    // VoiceOver get the same way in without a button for it.
                    .accessibilityElement(children: .contain)
                    .accessibilityIdentifier("device.details.account.\(machine.id)")
                    .accessibilityAction(named: L10n.text("apple.machinesview.details.45989de4")) { inspectAccount(machine) }
                }
            }
            .transition(.smoothIn(reduceMotion: reduceMotion))
        }
        .animation(.easeOut(duration: 0.22), value: model.accountMachines.isEmpty)
    }

    private func inspectPeer(_ peer: Peer) {
        model.selectPeer(peer)
        onInspect?()
    }

    private func inspectAccount(_ machine: Machine) {
        model.selectAccount(machine)
        onInspect?()
    }

    private func deviceActions(_ machine: Machine, isSelf: Bool) -> some View {
        HStack(spacing: Theme.Space.s) {
            if machine.isHost, !isSelf {
                if let peer = model.peer(for: machine) {
                    if model.isConnected(machine) {
                        Button(L10n.text("common.disconnect"), .disconnect) { model.disconnect(peer) }
                            .buttonStyle(SecondaryButtonStyle(small: true))
                    } else {
                        accountPeerActions(peer, machine: machine)
                    }
                } else if let key = machine.publicIdentity, !key.isEmpty, model.canConnect(machine) {
                    Button(L10n.text("common.connect"), .connect) { Task { await model.connect(machine) } }
                        .buttonStyle(AccentButtonStyle(small: true))
                }
            }
            Spacer(minLength: 0)
            ToolbarMenuButton(help: L10n.text("apple.machinesview.manage_0.d77d63f8", "\(model.resolvedName(for: machine) ?? machine.displayName)")) {
                Button(L10n.text("common.rename"), .edit) { renamingID = machine.machineID }
                if !isSelf {
                    if !machine.isHost, let peer = linkedPeer(for: machine) {
                        Divider()
                        if peer.trust == .approved {
                            Button(L10n.text("apple.machinesview.revoke_access.ab292ddb"), .revoke, role: .destructive) { confirmRevoke = peer }
                        } else {
                            Button(L10n.text("apple.machinesview.approve.6007acbe"), .approve) { Task { await model.approve(peer) } }
                        }
                        Button(L10n.text("apple.machinesview.forget_pairing.a39ae4ac"), .delete, role: .destructive) { confirmForget = peer }
                    } else if machine.isHost {
                        Divider()
                        Button(L10n.text("apple.machinesview.remove_from_account.6bfa319e"), .delete, role: .destructive) { pendingUnlink = machine }
                    }
                }
            }
            DeviceRowDisclosure()
        }
    }

    /// Whether the sweep dials this machine on its own, beside the connection
    /// itself rather than in a folder. Off stops the dialling and leaves a
    /// live connection alone; only Disconnect drops it.
    @ViewBuilder
    private func autoConnectRow(_ machine: Machine, isSelf: Bool) -> some View {
        if machine.isHost, !isSelf, let peer = model.peer(for: machine) {
            HStack(spacing: 6) {
                Text(L10n.text("apple.machinesview.auto_connect.45b6d201"))
                    .font(Theme.caption.weight(.medium))
                    .foregroundStyle(.secondary)
                Spacer(minLength: 0)
                Toggle(
                    L10n.text("apple.machinesview.auto_connect.45b6d201"),
                    isOn: Binding(
                        get: { WorkspacesModel.isAutoConnectEnabled(for: peer.key) },
                        set: { model.setAutoConnect($0, peer: peer, machine: machine) }
                    )
                )
                .labelsHidden()
                .toggleStyle(.switch)
                .controlSize(.small)
            }
            .accessibilityLabel(L10n.text("apple.machinesview.auto_connect_0.3bbf847e", "\(model.resolvedName(for: machine) ?? machine.displayName)"))
        }
    }

    /// The peer record for an account machine, matched on identity only.
    ///
    /// Stricter than `MachinesModel.peer(for:)`, which falls back to the
    /// account record's machine id: only a machine with a public key on this
    /// account can be the peer that decides which rows to hide.
    private func linkedPeer(for machine: Machine) -> Peer? {
        guard let identity = machine.publicIdentity, !identity.isEmpty else { return nil }
        return model.peers.first { $0.key == identity || $0.fingerprint == identity }
    }

    /// What to call a machine in a list. Never its id: the code sits under the
    /// title in monospace, where an identifier belongs.
    private func deviceTitle(resolved: String?, machine: Machine) -> String {
        if let resolved, !resolved.isEmpty { return resolved }
        return machine.isHost ? L10n.text("apple.machinesview.unnamed_computer.810da0c7") : L10n.text("apple.machinesview.unnamed_device.6aba593f")
    }

    /// One caption line under a machine's name. The presence light is the
    /// quick read; this carries the detail, and the two never collide.
    private func statusLine(for machine: Machine, isSelf: Bool) -> String {
        if isSelf { return L10n.text("apple.machinesview.this_device.d052579c") }
        if !machine.isHost {
            // A phone holds the tunnel only while somebody is using it, so
            // "offline" here means "not in the app right now", not "broken".
            if machine.online == true { return L10n.text("apple.machinesview.phone_in_the_app_now.49897ae2") }
            if let seen = formatRelativeDate(machine.lastSeenAt) { return L10n.text("apple.machinesview.phone_last_used_0.555b7a23", "\(seen)") }
            return L10n.text("apple.machinesview.phone_signed_in_on_this_account.58d549b8")
        }
        if machine.publicIdentity?.isEmpty != false { return L10n.text("apple.machinesview.no_connection_key_yet.86015bb4") }
        if machine.online == false {
            if let seen = formatRelativeDate(machine.lastSeenAt) {
                return L10n.text("apple.machinesview.offline_last_seen_0.52d14c6d", "\(seen)")
            }
            return L10n.text("common.offline")
        }
        if model.isConnected(machine) { return L10n.text("apple.machinesview.connected_projects_in_sidebar.bc3f7d2f") }
        if let seen = formatRelativeDate(machine.lastSeenAt) { return L10n.text("apple.machinesview.seen_0.522e2767", "\(seen)") }
        if let sync = formatRelativeDate(machine.lastSyncAt) { return L10n.text("apple.machinesview.last_synced_0.789aa5cd", "\(sync)") }
        return L10n.text("apple.machinesview.no_sync_recorded.e74abceb")
    }

    @ViewBuilder
    private func accountPeerActions(_ peer: Peer, machine: Machine) -> some View {
        switch peer.trust {
        case .pending:
            Button(L10n.text("apple.machinesview.approve.6007acbe"), .approve) { Task { await model.approve(peer) } }
                .buttonStyle(AccentButtonStyle())
        case .approved:
            if model.canConnect(machine) {
                Button(L10n.text("common.connect"), .connect) { Task { await model.connect(peer) } }
                    .buttonStyle(AccentButtonStyle())
                    .help(L10n.text("apple.machinesview.connects_through_the_tunnel_from_anywhere.71e633cf"))
            }
            Button(L10n.text("apple.machinesview.revoke.87e6d00b"), .revoke, role: .destructive) { confirmRevoke = peer }
                .buttonStyle(SecondaryButtonStyle())
                .help(L10n.text("apple.machinesview.stops_this_device_from_reaching_you_worksp.dc0b132f"))
        case .revoked:
            Button(L10n.text("apple.machinesview.approve.6007acbe"), .approve) { Task { await model.approve(peer) } }
                .buttonStyle(SecondaryButtonStyle())
        }
    }

    /// What protects a connection, with the keys it actually runs on.
    ///
    /// The paragraph used to sit at the foot of this screen as grey text, which
    /// is where a claim goes to be skipped. It is the product, so it gets a
    /// card, and it carries the fingerprints somebody can compare against the
    /// other machine rather than asking them to take the sentence on trust.
    private var encryptionNote: some View {
        VStack(alignment: .leading, spacing: Theme.Space.m) {
            Button {
                withAnimation(.easeInOut(duration: 0.2)) {
                    encryptionExpanded.toggle()
                }
            } label: {
                HStack(alignment: .firstTextBaseline, spacing: Theme.Space.s) {
                    Image(systemName: "lock.shield.fill")
                        .foregroundStyle(Theme.accent)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(L10n.text("apple.machinesview.end_to_end_encrypted.e3ac807e"))
                            .font(Theme.fit(13, weight: .semibold))
                        Text(encryptionExpanded
                            ? L10n.text("apple.machinesview.keys_and_fingerprints_are_visible.edabb3c3")
                            : L10n.text("apple.machinesview.keys_are_hidden_until_you_choose_to_view_t.26d1e1a0"))
                            .font(Theme.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer(minLength: Theme.Space.s)
                    Image(systemName: encryptionExpanded ? "chevron.up" : "chevron.down")
                        .font(Theme.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityHint(encryptionExpanded
                ? L10n.text("apple.machinesview.hides_the_encryption_keys.d8fa35b1")
                : L10n.text("apple.machinesview.shows_the_encryption_keys.081948ff"))

            if encryptionExpanded {
                VStack(alignment: .leading, spacing: Theme.Space.s) {
                    Text(L10n.text("apple.machinesview.a_connection_between_two_machines_carries.aa0d4220"))
                    .font(Theme.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                    if let identity = model.identity {
                        keyLine(
                            title: L10n.text("apple.machinesview.this_machine.1b8548de"),
                            words: identity.words,
                            fingerprint: identity.fingerprint
                        )
                    }
                    ForEach(model.known.filter { $0.trust == .approved }) { peer in
                        keyLine(
                            title: peer.label.isEmpty
                                ? (model.accountName(for: peer) ?? L10n.text("apple.machinesview.approved_device.3170ef88"))
                                : peer.label,
                            words: peer.words,
                            fingerprint: peer.fingerprint
                        )
                    }

                    Text(L10n.text("apple.machinesview.noise_xx_handshake_x25519_keys_chacha20_po.8025c019"))
                        .font(Theme.caption)
                        .foregroundStyle(.tertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .padding(Theme.cardPadding)
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .background(Theme.panel, in: RoundedRectangle(cornerRadius: Theme.cardRadius))
        .overlay(
            RoundedRectangle(cornerRadius: Theme.cardRadius)
                .strokeBorder(Theme.border, lineWidth: 1)
        )
    }

    private func keyLine(title: String, words: String?, fingerprint: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: Theme.Space.s) {
            Text(title)
                .font(Theme.callout)
                .frame(width: 160, alignment: .leading)
                .lineLimit(1)
                .truncationMode(.middle)
            Text(words ?? fingerprint)
                .font(Theme.callout.weight(.medium))
            Spacer(minLength: Theme.Space.s)
            Text(fingerprint)
                .font(Theme.mono(11))
                .foregroundStyle(.tertiary)
                .textSelection(.enabled)
                .lineLimit(1)
                .truncationMode(.middle)
        }
    }
}

/// What each paired device is allowed to do here.
///
/// Not only the screen any more. Being approved is not being let in: every
/// device on the account is auto-approved on first contact with the tunnel, so
/// reaching the work on this machine is its own explicit yes, and it is first
/// because it is the broadest of the three.
private struct DevicePermissionCard: View {
    let peers: [Peer]
    var localOnly = false
    var fillsHeight = false
    @State private var permissions: [String: ScreenPermission] = [:]
    /// Peer keys allowed to open the work here.
    @State private var workspaceAllowed: Set<String> = []
    @State private var error: String?
    @State private var transferDestination: String?
    #if os(macOS)
    @State private var access = ScreenAccess()
    #endif

    var body: some View {
        Group {
            if localOnly {
                Card(title: L10n.text("apple.machinesview.local_permissions.26eb1221"), subtitle: L10n.text("apple.machinesview.screen_sharing_and_incoming_files_on_this.ead35623"), mark: "mark_device", fillsHeight: fillsHeight) {
                    VStack(alignment: .leading, spacing: Theme.Space.m) {
                    #if os(macOS)
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(L10n.text("apple.machinesview.incoming_files.41d9096f")).font(Theme.callout.weight(.medium))
                            Text(transferDestination ?? L10n.text("apple.machinesview.choose_a_destination_before_receiving_file.d0d97910"))
                                .font(Theme.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                        }
                        Spacer()
                        Button(L10n.text("apple.machinesview.choose_folder.3db74100"), .reveal) { chooseTransferDestination() }
                    }
                    ThemeRule()
                    permissionRow(.screenRecording, granted: access.screenRecording)
                    if access.needsRelaunch {
                        HStack(alignment: .top) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(L10n.text("apple.machinesview.restart_to_finish.e70f1ec3")).font(Theme.callout.weight(.medium))
                                Text(L10n.text("apple.machinesview.macos_granted_screen_recording_after_this.baaa55d4"))
                                    .font(Theme.caption).foregroundStyle(.secondary)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                            Spacer(minLength: Theme.Space.m)
                            Button(L10n.text("apple.machinesview.restart.6b983a81"), .refresh) { access.relaunch() }
                                .buttonStyle(AccentButtonStyle(small: true))
                        }
                    }
                    permissionRow(.accessibility, granted: access.accessibility)
                    // Directly above Always-on host, which is exactly where
                    // somebody would assume the opposite. Capture runs in this
                    // app, not in the helper, so a closed app has no screen to
                    // share however always-on the helper is.
                    Text(L10n.text("apple.machinesview.capture_runs_in_the_app_so_tokenstat_has_t.e2be3644"))
                        .font(Theme.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    #endif
                        if let error { Text(error).font(Theme.caption).foregroundStyle(Theme.danger) }
                    }
                }
            } else if !peers.isEmpty {
                Card(title: L10n.text("apple.machinesview.device_permissions.8b91be20"), subtitle: L10n.text("apple.machinesview.choose_what_each_approved_device_can_acces.2cfb4ad0"), mark: "mark_device") {
                    WidthReader { width in
                        permissionTable(compact: width < 620)
                    }
                    Text(L10n.text("apple.machinesview.control_requires_view_devices_can_also_req.b5c3c672"))
                        .font(Theme.caption).foregroundStyle(.secondary)
                    if let error { Text(error).font(Theme.caption).foregroundStyle(Theme.danger) }
                }
            }
        }
        .task(id: peers.map(\.key)) { await load() }
        #if os(macOS)
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            Task { await access.refresh() }
        }
        .task { await access.refresh() }
        #endif
    }

    private func permissionTable(compact: Bool) -> some View {
        VStack(spacing: 0) {
            if !compact {
                HStack {
                    Text(L10n.text("apple.machinesview.device.f92fc83b")).frame(maxWidth: .infinity, alignment: .leading)
                    ForEach([L10n.text("apple.machinesview.projects.59891d08"), L10n.text("apple.machinesview.view.28baebc3"), L10n.text("apple.machinesview.control.6fecf908")], id: \.self) { title in
                        Text(title).frame(width: 105)
                    }
                }
                .font(Theme.sectionHeader).foregroundStyle(.secondary)
                .padding(.bottom, Theme.Space.s)
            }
            ForEach(peers) { peer in
                VStack(alignment: .leading, spacing: Theme.Space.s) {
                    HStack {
                        peerIdentity(peer)
                        if !compact {
                            Spacer(minLength: Theme.Space.s)
                            permissionSwitches(peer, compact: false)
                        }
                    }
                    if compact { permissionSwitches(peer, compact: true) }
                }
                .padding(.vertical, Theme.Space.s)
                if peer.id != peers.last?.id { ThemeRule().opacity(0.6) }
            }
        }
    }

    private func peerIdentity(_ peer: Peer) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(peer.label).font(Theme.callout.weight(.medium)).lineLimit(1).truncationMode(.middle)
            Text(peer.words ?? peer.fingerprint).font(Theme.caption).foregroundStyle(.secondary)
                .lineLimit(1).truncationMode(.middle)
        }
    }

    private func permissionSwitches(_ peer: Peer, compact: Bool) -> some View {
        HStack(spacing: 0) {
            permissionSwitch(L10n.text("common.projects"), peer: peer, value: workspaceBinding(peer), compact: compact)
            permissionSwitch(L10n.text("apple.machinesview.view.dcc839a4"), peer: peer, value: binding(peer, control: false), compact: compact)
            permissionSwitch(L10n.text("apple.machinesview.control.32d7e820"), peer: peer, value: binding(peer, control: true), compact: compact)
                .disabled(permissions[peer.key]?.view != true)
                .help(L10n.text("apple.machinesview.control_requires_screen_viewing_access.bf319cd9"))
        }
    }

    private func permissionSwitch(_ title: String, peer: Peer, value: Binding<Bool>, compact: Bool) -> some View {
        VStack(spacing: 5) {
            if compact { Text(title).font(Theme.caption).foregroundStyle(.secondary) }
            Toggle(title, isOn: value).toggleStyle(.switch).labelsHidden()
                .accessibilityLabel("\(peer.label): \(title)")
        }
        .frame(width: 105)
    }

    #if os(macOS)
    /// One permission: what it is for, whether it is granted, and a button that
    /// actually asks rather than pointing at a pane.
    private func permissionRow(_ kind: ScreenAccess.Kind, granted: Bool) -> some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: Theme.Space.xs) {
                    Text(kind.title).font(Theme.callout.weight(.medium))
                    Image(systemName: granted ? "checkmark.circle.fill" : "exclamationmark.circle")
                        .font(Theme.font(11))
                        .foregroundStyle(granted ? Theme.success : Theme.warning)
                    Text(granted ? L10n.text("apple.machinesview.granted.62026a42") : L10n.text("apple.machinesview.not_granted.352a5b4c"))
                        .font(Theme.caption)
                        .foregroundStyle(granted ? Theme.success : Theme.warning)
                }
                Text(granted ? kind.need : "\(kind.need) \(kind.settingsHint)")
                    .font(Theme.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: Theme.Space.m)
            if !granted {
                Button(L10n.text("apple.machinesview.allow.e213c161"), .approve) { ask(kind) }
                    .buttonStyle(AccentButtonStyle(small: true))
            }
        }
    }

    /// Ask, and open the pane only once macOS has stopped asking.
    ///
    /// Never both at once. Both system calls return false while their own
    /// prompt is still on screen, so treating that as a refusal would throw a
    /// Settings window over the dialog the person was about to answer. The
    /// pane is the second press, when there is no dialog left to raise, and
    /// the row it needs switching on is named beside the button.
    private func ask(_ kind: ScreenAccess.Kind) {
        let answer = switch kind {
        case .screenRecording: access.requestScreenRecording()
        case .accessibility: access.requestAccessibility()
        }
        if answer == .alreadyDecided { access.openSettings(kind) }
        // Read the real state back. Somebody who answers the prompt straight
        // away should not have to click away and back for the card to agree.
        Task { await access.refresh() }
    }
    #endif

    /// Whether this device may reach the work here.
    ///
    /// One switch, because there is no half of it: a device that can open a
    /// folder can write to it, start a terminal in it and push it.
    private func workspaceBinding(_ peer: Peer) -> Binding<Bool> {
        Binding {
            workspaceAllowed.contains(peer.key)
        } set: { allow in
            if allow { workspaceAllowed.insert(peer.key) } else { workspaceAllowed.remove(peer.key) }
            Task {
                do { try await Bridge.setWorkspaceAccess(peerID: peer.key, allow: allow) }
                catch { self.error = error.localizedDescription; await load() }
            }
        }
    }

    private func binding(_ peer: Peer, control: Bool) -> Binding<Bool> {
        Binding {
            control ? permissions[peer.key]?.control == true : permissions[peer.key]?.view == true
        } set: { enabled in
            var permission = permissions[peer.key] ?? ScreenPermission(peerID: peer.key, view: false, control: false)
            if control { permission.control = enabled; if enabled { permission.view = true } }
            else { permission.view = enabled; if !enabled { permission.control = false } }
            permissions[peer.key] = permission
            #if os(macOS)
            // The moment somebody says what they want is the moment to ask for
            // what it needs. Waiting until a stream starts meant the viewer on
            // the other device had already failed before the prompt appeared.
            if enabled {
                if permission.view { _ = access.requestScreenRecording() }
                if permission.control { _ = access.requestAccessibility() }
            }
            #endif
            Task {
                do { try await Bridge.setScreenPermission(peerID: peer.key, view: permission.view, control: permission.control) }
                catch { self.error = error.localizedDescription; await load() }
            }
        }
    }

    private func load() async {
        do {
            let values = try await Bridge.screenPermissions()
            permissions = Dictionary(values.map { ($0.peerID, $0) }, uniquingKeysWith: { _, last in last })
            workspaceAllowed = Set((try? await Bridge.workspaceAccessList()) ?? [])
            transferDestination = try? await Bridge.screenTransferDestination().path
            error = nil
        } catch { self.error = error.localizedDescription }
    }

    #if os(macOS)
    private func chooseTransferDestination() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        Task {
            do {
                transferDestination = try await Bridge.setScreenTransferDestination(url.path).path
                error = nil
            } catch { self.error = error.localizedDescription }
        }
    }
    #endif
}

/// The presence light before a machine's name: solid when reachable, blinking
/// while its state is not confirmed yet, grey when offline.
private struct StatusDot: View {
    /// nil means presence is not known yet (connecting), which is the state
    /// that blinks.
    var online: Bool?

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var pulsing = false

    private var ready: Bool { online == true }

    private var color: Color {
        switch online {
        case .some(true): return Theme.success
        case .some(false): return .gray
        case nil: return Theme.warning
        }
    }

    var body: some View {
        Circle()
            .fill(color)
            .frame(width: 8, height: 8)
            .opacity(ready || reduceMotion ? 1 : (pulsing ? 0.3 : 1))
            .onAppear {
                guard !ready, !reduceMotion else { return }
                withAnimation(.easeInOut(duration: 0.7).repeatForever(autoreverses: true)) {
                    pulsing = true
                }
            }
            .accessibilityLabel(accessibilityText)
            .help(helpText)
    }

    private var accessibilityText: String {
        switch online {
        case .some(true): return L10n.text("common.online")
        case .some(false): return L10n.text("common.offline")
        case nil: return L10n.text("apple.machinesview.connecting.d403c686")
        }
    }

    private var helpText: String {
        switch online {
        case .some(true): return L10n.text("common.online")
        case .some(false): return L10n.text("common.offline")
        case nil: return L10n.text("apple.machinesview.presence_not_confirmed_yet.a71e57d2")
        }
    }
}

// MARK: - Naming this machine

/// The machine's name, editable in place.
///
/// A text field rather than a sheet, because renaming a computer is not a
/// decision with consequences: the key is the identity, so this changes only how
/// the machine reads on somebody else's screen. Committed on return or on losing
/// focus, and emptying it puts the computer's own name back.
private struct MachineNameField: View {
    var identity: MachineIdentity
    var rename: (String) async -> Void

    @State private var draft = ""
    @FocusState private var editing: Bool

    var body: some View {
        HStack(spacing: Theme.Space.xs) {
            TextField(L10n.text("apple.machinesview.name.dcd1d522"), text: $draft, prompt: Text(identity.label))
                .textFieldStyle(.plain)
                .focused($editing)
                .onSubmit { commit() }
                .frame(maxWidth: 220)
            if identity.labelIsChosen == true {
                Button(L10n.text("apple.machinesview.use_the_computer_s_name.f856ecb6"), .device) {
                    draft = ""
                    commit()
                }
                #if os(macOS)
                .buttonStyle(.link)
                #else
                .buttonStyle(.plain)
                .foregroundStyle(Theme.accent)
                #endif
                .font(Theme.caption)
            }
        }
        .onAppear { draft = identity.label }
        .onChange(of: identity.label) { _, new in
            // Only while nobody is typing, so a refresh underneath somebody
            // mid-edit does not take the characters back out of the field.
            if !editing { draft = new }
        }
        .onChange(of: editing) { _, focused in
            if !focused { commit() }
        }
    }

    private func commit() {
        let name = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard name != identity.label else { return }
        Task { await rename(name) }
    }
}

/// The name of a device on the account, edited where it is read.
///
/// Separate from `MachineNameField`, which names *this* machine by writing a
/// file beside its key. This one writes the account row, which is the only
/// name a machine you cannot log into has.
private struct AccountNameField: View {
    var machine: Machine
    /// What the row says when the name is empty, so the field offers to
    /// replace what is on screen rather than starting blank with no context.
    var placeholder: String
    var commit: (String) async -> Void
    var onCancel: () -> Void

    @State private var draft = ""
    @FocusState private var editing: Bool

    var body: some View {
        HStack(spacing: Theme.Space.xs) {
            TextField(L10n.text("apple.machinesview.name.dcd1d522"), text: $draft, prompt: Text(placeholder))
                .textFieldStyle(.plain)
                .font(Theme.callout.weight(.medium))
                .focused($editing)
                .frame(maxWidth: 220)
                .onSubmit { Task { await commit(draft) } }
            Button(L10n.text("common.save"), .save) { Task { await commit(draft) } }
                .buttonStyle(SecondaryButtonStyle(small: true))
                .labelStyle(.iconOnly)
            Button(L10n.text("common.cancel"), .dismiss, role: .cancel) { onCancel() }
                .buttonStyle(SecondaryButtonStyle(small: true))
                .labelStyle(.iconOnly)
        }
        .onAppear {
            draft = machine.label ?? ""
            editing = true
        }
    }
}

// MARK: - One peer

private struct PeerRow<Actions: View>: View {
    var peer: Peer
    /// The account directory's name for this machine, when the peer itself
    /// was never named. Shown in place of "Unnamed device".
    var resolvedName: String?
    /// SF Symbol: phone for iOS clients, desktop otherwise.
    var symbol: String = "desktopcomputer"
    var isSelected: Bool = false
    @ViewBuilder var actions: Actions

    var body: some View {
        HStack(alignment: .center, spacing: Theme.Space.m) {
            Image(systemName: symbol)
                .foregroundStyle(tint)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: Theme.Space.s) {
                    Text(peer.label.isEmpty ? (resolvedName ?? L10n.text("apple.machinesview.unnamed_device.6aba593f")) : peer.label)
                        .font(Theme.callout.weight(.medium))
                    TrustBadge(trust: peer.trust)
                }
                // The words rather than the key or the fingerprint: this line
                // exists to be compared with another screen by a person, and
                // that is the form they will read whole. They derive from a
                // public key, so there is nothing to hide.
                Text(peer.words ?? L10n.text("apple.machinesview.paired_device.b2e5f1e4"))
                    .font(Theme.caption)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }
            Spacer()
            actions
        }
        .padding(Theme.Space.s)
        .background(
            (isSelected ? Theme.rowSelected : Theme.background),
            in: RoundedRectangle(cornerRadius: Theme.cardRadius)
        )
        .overlay(
            RoundedRectangle(cornerRadius: Theme.cardRadius)
                .strokeBorder(
                    isSelected ? Theme.accent.opacity(0.45) : Theme.border,
                    lineWidth: 1
                )
        )
    }

    private var tint: Color {
        switch peer.trust {
        case .approved: return Theme.success
        case .pending: return Theme.warning
        case .revoked: return .secondary
        }
    }
}

private struct TrustBadge: View {
    var trust: Peer.Trust

    var body: some View {
        Text(label)
            .font(Theme.caption2.weight(.medium))
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(tint.opacity(0.15), in: Capsule())
            .foregroundStyle(tint)
    }

    private var label: String {
        switch trust {
        case .approved: return L10n.text("apple.machinesview.access_allowed.f5058646")
        case .pending: return L10n.text("apple.machinesview.waiting_for_approval.10c5739b")
        case .revoked: return L10n.text("apple.machinesview.access_removed.dcdce51f")
        }
    }

    private var tint: Color {
        switch trust {
        case .approved: return Theme.success
        case .pending: return Theme.warning
        case .revoked: return Theme.danger
        }
    }
}

// MARK: - Pairing by hand

/// Connect to a machine by pasting its pairing code.
///
/// One field, whatever the other machine showed. This path works with no
/// account and no network service at all, which is why it is on the screen
/// rather than behind an "advanced" disclosure: it is the thing that makes the
/// privacy claim checkable instead of promised.
private struct PairingForm: View {
    var showsCard: Bool = true
    var onClose: (() -> Void)? = nil
    var pair: (String, String, String) async -> Void

    @State private var link = ""
    @State private var label = ""
    @State private var working = false

    var body: some View {
        if showsCard {
            Card(
                title: L10n.text("apple.machinesview.connect_another_device.9890af94"),
                subtitle: L10n.text("apple.machinesview.paste_an_invite_from_the_other_device_a_li.701376c1"),
                mark: "mark_device"
            ) {
                fields(includeConnect: true)
            }
        } else {
            ThemedSheet(
                title: L10n.text("apple.machinesview.connect_another_device.9890af94"),
                subtitle: L10n.text("apple.machinesview.paste_an_invite_from_the_other_device_a_li.701376c1"),
                icon: .pair,
                onClose: { onClose?() }
            ) {
                fields(includeConnect: false)
            } actions: {
                Button(L10n.text("common.cancel"), .dismiss) { onClose?() }
                    .buttonStyle(SecondaryButtonStyle())
                    .keyboardShortcut(.cancelAction)
                Spacer()
                connectButton
                    .keyboardShortcut(.defaultAction)
            }
            .modalFrame(width: 540, height: 480)
        }
    }

    private func fields(includeConnect: Bool) -> some View {
        VStack(alignment: .leading, spacing: Theme.Space.xl) {
            VStack(alignment: .leading, spacing: Theme.Space.m) {
                TextField(
                    L10n.text("apple.machinesview.pairing_code.1c5ea2f7"),
                    text: $link,
                    prompt: Text(L10n.text("apple.machinesview.paste_the_code_from_the_other_device.1fa63d81"))
                )
                .font(Theme.mono(11))
                TextField(L10n.text("apple.machinesview.name.dcd1d522"), text: $label, prompt: Text(L10n.text("apple.machinesview.what_you_call_that_device_optional.dbb5fdab")))
            }
            .textFieldStyle(.themed)

            if includeConnect {
                HStack {
                    Spacer()
                    connectButton
                }
            }

            Text(L10n.text("apple.machinesview.connecting_here_approves_that_machine_to_r.23b01cc2"))
            .font(Theme.caption)
            .foregroundStyle(Theme.controlGlyph)
            .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var connectButton: some View {
        Button {
            working = true
            Task {
                let (key, address) = splitLink(link)
                await pair(key, label, address)
                working = false
                link = ""
                label = ""
            }
        } label: {
            ActionIcon.connect.label(L10n.text("common.connect"))
        }
        .buttonStyle(AccentButtonStyle())
        .disabled(working || link.trimmingCharacters(in: .whitespaces).isEmpty)
    }

    /// `key@host:port` splits at the last @; a bare key has no address, which
    /// is right for a machine that only ever connects *to* this one.
    private func splitLink(_ raw: String) -> (String, String) {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let at = trimmed.lastIndex(of: "@") else { return (trimmed, "") }
        return (
            String(trimmed[..<at]),
            String(trimmed[trimmed.index(after: at)...])
        )
    }
}

/// The chevron at the end of a device row: the row itself opens the details.
///
/// A "Details" button on every row doubled each row's controls and read as
/// one more thing to decide. A chevron is the familiar sign that a row leads
/// somewhere, and the row's tap target is already all of it.
private struct DeviceRowDisclosure: View {
    var body: some View {
        Image(systemName: "chevron.right")
            .font(Theme.font(11, weight: .semibold))
            .foregroundStyle(.tertiary)
            .frame(width: 14)
            .accessibilityHidden(true)
    }
}
