// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
//
// Source-available for review, NOT open source. See LICENSE: no rights to
// redistribute, publish, or ship a build are granted. Read it, study it, run
// your own build of it.
// "tokenstat" is a trademark of pueev OU. See TRADEMARK.md.

import SwiftUI

/// The selected device: this machine, a peer, or an account machine.
///
/// Pairing stays a sheet. The list is names and presence. Actions that change
/// a connection live here so the overview does not become a form.
struct MachinesInspector: View {
    @Bindable var model: MachinesModel
    var onClose: () -> Void

    @State private var confirmForget: Peer?
    @State private var confirmRevoke: Peer?
    @State private var pendingUnlink: Machine?

    var body: some View {
        VStack(spacing: 0) {
            InspectorChromeBar(onClose: onClose) {
                InspectorTitle(title: L10n.text("apple.machinesinspector.device.6ba0bdec"), symbol: "laptopcomputer")
                Spacer(minLength: 0)
            }
            Group {
                switch model.selectedDevice {
                case .thisMachine:
                    thisMachine
                case let .peer(peer):
                    peerBody(peer)
                case let .account(machine):
                    accountBody(machine)
                case .none:
                    InspectorEmptyState(
                        mark: "mark_device",
                        title: L10n.text("apple.machinesinspector.pick_a_device.de6694f3"),
                        subtitle: L10n.text("apple.machinesinspector.reachability_and_pairing_actions_open_here.6de3491c")
                    )
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Theme.background)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Theme.background)
        .confirmationDialog(
            L10n.text("apple.machinesinspector.forget_this_device.6bddebb5"),
            isPresented: Binding(
                get: { confirmForget != nil },
                set: { if !$0 { confirmForget = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button(L10n.text("apple.machinesinspector.forget.a6bd489d"), role: .destructive) {
                if let peer = confirmForget { Task { await model.forget(peer) } }
                confirmForget = nil
            }
            Button(L10n.text("common.cancel"), role: .cancel) { confirmForget = nil }
        }
        .confirmationDialog(
            L10n.text("apple.machinesinspector.revoke_this_device.e7e35e2c"),
            isPresented: Binding(
                get: { confirmRevoke != nil },
                set: { if !$0 { confirmRevoke = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button(L10n.text("apple.machinesinspector.revoke.87e6d00b"), role: .destructive) {
                if let peer = confirmRevoke { Task { await model.revoke(peer) } }
                confirmRevoke = nil
            }
            Button(L10n.text("common.cancel"), role: .cancel) { confirmRevoke = nil }
        }
        .confirmationDialog(
            L10n.text("apple.machinesinspector.remove_from_account.a3010e43"),
            isPresented: Binding(
                get: { pendingUnlink != nil },
                set: { if !$0 { pendingUnlink = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button(L10n.text("common.remove"), role: .destructive) {
                if let machine = pendingUnlink { Task { await model.unlink(machine) } }
                pendingUnlink = nil
            }
            Button(L10n.text("common.cancel"), role: .cancel) { pendingUnlink = nil }
        }
    }

    private var thisMachine: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.Space.m) {
                Text(model.identity?.label ?? L10n.text("apple.machinesinspector.this_device.d052579c"))
                    .font(Theme.font(15, weight: .semibold))
                if let words = model.words {
                    labeled(L10n.text("apple.machinesinspector.known_as.9076e6ab"), words)
                }
                if model.pairingCode != nil {
                    Button {
                        model.copyInvite()
                    } label: {
                        ActionIcon.copy.label(L10n.text("apple.machinesinspector.copy_invite.953ed058"))
                    }
                    .buttonStyle(AccentButtonStyle())
                    .help(L10n.text("apple.machinesinspector.paste_this_in_the_other_machine_s_add_devi.be6bf406"))
                }
                if let status = model.status {
                    labeled(
                        L10n.text("apple.machinesinspector.reachability.66f0f432"),
                        status.tunnelOnline == true ? L10n.text("apple.machinesinspector.tunnel_up.77a2eaee") : L10n.text("apple.machinesinspector.not_reachable_from_elsewhere.1f54e85a")
                    )
                }
                HostStatsBar(local: true)
                HostUpdateCard(local: true)
            }
            .padding(Theme.Space.m)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func peerBody(_ peer: Peer) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.Space.m) {
                Text(peer.label.isEmpty ? (model.accountName(for: peer) ?? L10n.text("apple.machinesinspector.unnamed_device.6aba593f")) : peer.label)
                    .font(Theme.font(15, weight: .semibold))
                if let words = peer.words {
                    labeled(L10n.text("apple.machinesinspector.known_as.9076e6ab"), words)
                }
                labeled(L10n.text("apple.machinesinspector.trust.ade9248e"), Self.trustLabel(peer.trust))
                if model.connectedPeerKeys.contains(peer.key) {
                    Text(L10n.text("apple.machinesinspector.projects_from_this_device_are_in_the_sideb.a1c36b35"))
                        .font(Theme.caption)
                        .foregroundStyle(.secondary)
                    HostStatsBar(peer: peer.key, online: true)
                    HostUpdateCard(peer: peer.key)
                }

                VStack(alignment: .leading, spacing: Theme.Space.s) {
                    if peer.trust == .approved {
                        if model.connectedPeerKeys.contains(peer.key) {
                            Button(L10n.text("common.disconnect"), .disconnect) { model.disconnect(peer) }
                                .buttonStyle(SecondaryButtonStyle())
                        } else {
                            Button(L10n.text("common.connect"), .connect) { Task { await model.connect(peer) } }
                                .buttonStyle(AccentButtonStyle())
                        }
                        autoConnectToggle(peer: peer)
                        Button(L10n.text("apple.machinesinspector.revoke.87e6d00b"), .revoke) { confirmRevoke = peer }
                            .buttonStyle(SecondaryButtonStyle())
                    } else {
                        Button(L10n.text("apple.machinesinspector.approve.6007acbe"), .approve) { Task { await model.approve(peer) } }
                            .buttonStyle(AccentButtonStyle())
                    }
                    Button(L10n.text("apple.machinesinspector.forget.a6bd489d"), .delete, role: .destructive) { confirmForget = peer }
                        .buttonStyle(SecondaryButtonStyle())
                }
            }
            .padding(Theme.Space.m)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func accountBody(_ machine: Machine) -> some View {
        let isSelf = machine.machineID == model.account?.thisMachineID
            || machine.publicIdentity == model.identity?.key
        return ScrollView {
            VStack(alignment: .leading, spacing: Theme.Space.m) {
                Text(model.resolvedName(for: machine) ?? machine.displayName)
                    .font(Theme.font(15, weight: .semibold))
                if let id = machine.machineID {
                    labeled(L10n.text("apple.machinesinspector.code.340f4630"), id)
                }
                if isSelf {
                    Text(L10n.text("apple.machinesinspector.this_device.3b5031a9"))
                        .font(Theme.callout)
                        .foregroundStyle(.secondary)
                    HostStatsBar(local: true)
                    HostUpdateCard(local: true)
                } else if !machine.isHost {
                    Text(L10n.text("apple.machinesinspector.this_phone_or_tablet_connects_to_your_comp.c99a1b87"))
                        .font(Theme.callout).foregroundStyle(.secondary)
                } else if let peer = model.peer(for: machine) {
                    if machine.online == true, let key = machine.publicIdentity, !key.isEmpty {
                        HostStatsBar(peer: key, online: true)
                        HostUpdateCard(peer: key)
                    }
                    peerActions(peer, machine: machine)
                } else if model.canConnect(machine) {
                    if machine.online == true, let key = machine.publicIdentity, !key.isEmpty {
                        HostStatsBar(peer: key, online: true)
                    }
                    Button(L10n.text("common.connect"), .connect) { Task { await model.connect(machine) } }
                        .buttonStyle(AccentButtonStyle())
                }
                if !isSelf {
                    Button(L10n.text("apple.machinesinspector.remove_from_account.6bfa319e"), .delete, role: .destructive) {
                        pendingUnlink = machine
                    }
                    .buttonStyle(SecondaryButtonStyle())
                }
            }
            .padding(Theme.Space.m)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    @ViewBuilder
    private func peerActions(_ peer: Peer, machine: Machine) -> some View {
        if model.isConnected(machine) {
            Button(L10n.text("common.disconnect"), .disconnect) { model.disconnect(peer) }
                .buttonStyle(SecondaryButtonStyle())
        } else {
            Button(L10n.text("common.connect"), .connect) { Task { await model.connect(peer) } }
                .buttonStyle(AccentButtonStyle())
        }
        autoConnectToggle(peer: peer, machine: machine)
    }

    /// Whether the sweep dials this peer on its own. Off stops the dialling
    /// and leaves a live connection alone; only Disconnect drops it.
    private func autoConnectToggle(peer: Peer, machine: Machine? = nil) -> some View {
        HStack(spacing: 6) {
            Text(L10n.text("apple.machinesinspector.auto_connect.45b6d201"))
                .font(Theme.caption.weight(.medium))
                .foregroundStyle(.secondary)
            Spacer(minLength: 0)
            Toggle(
                L10n.text("apple.machinesinspector.auto_connect.45b6d201"),
                isOn: Binding(
                    get: { WorkspacesModel.isAutoConnectEnabled(for: peer.key) },
                    set: { model.setAutoConnect($0, peer: peer, machine: machine) }
                )
            )
            .labelsHidden()
            .toggleStyle(.switch)
            .controlSize(.small)
        }
        .accessibilityLabel(L10n.text("apple.machinesinspector.auto_connect_0.3bbf847e", "\(peer.label.isEmpty ? L10n.text("apple.machinesinspector.this_device.cf3cc23e") : peer.label)"))
    }

    private static func trustLabel(_ trust: Peer.Trust) -> String {
        switch trust {
        case .pending: return L10n.text("apple.machinesinspector.waiting_for_approval.10c5739b")
        case .approved: return L10n.text("apple.machinesinspector.approved.87b42e40")
        case .revoked: return L10n.text("apple.machinesinspector.revoked.f6f738d0")
        }
    }

    private func labeled(_ title: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(Theme.caption)
                .foregroundStyle(.tertiary)
            Text(value)
                .font(Theme.callout)
                .textSelection(.enabled)
        }
    }
}
