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
                InspectorTitle(title: "Device", symbol: "laptopcomputer")
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
                        title: "Pick a device",
                        subtitle: "Reachability and pairing actions open here."
                    )
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Theme.background)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Theme.background)
        .confirmationDialog(
            "Forget this device?",
            isPresented: Binding(
                get: { confirmForget != nil },
                set: { if !$0 { confirmForget = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button("Forget", role: .destructive) {
                if let peer = confirmForget { Task { await model.forget(peer) } }
                confirmForget = nil
            }
            Button("Cancel", role: .cancel) { confirmForget = nil }
        }
        .confirmationDialog(
            "Revoke this device?",
            isPresented: Binding(
                get: { confirmRevoke != nil },
                set: { if !$0 { confirmRevoke = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button("Revoke", role: .destructive) {
                if let peer = confirmRevoke { Task { await model.revoke(peer) } }
                confirmRevoke = nil
            }
            Button("Cancel", role: .cancel) { confirmRevoke = nil }
        }
        .confirmationDialog(
            "Remove from account?",
            isPresented: Binding(
                get: { pendingUnlink != nil },
                set: { if !$0 { pendingUnlink = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button("Remove", role: .destructive) {
                if let machine = pendingUnlink { Task { await model.unlink(machine) } }
                pendingUnlink = nil
            }
            Button("Cancel", role: .cancel) { pendingUnlink = nil }
        }
    }

    private var thisMachine: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.Space.m) {
                Text(model.identity?.label ?? "This device")
                    .font(Theme.font(15, weight: .semibold))
                if let words = model.words {
                    labeled("Known as", words)
                }
                if model.pairingCode != nil {
                    Button {
                        model.copyInvite()
                    } label: {
                        ActionIcon.copy.label("Copy invite")
                    }
                    .buttonStyle(AccentButtonStyle())
                    .help("Paste this in the other machine's Add device box")
                }
                if let status = model.status {
                    labeled(
                        "Reachability",
                        status.tunnelOnline == true ? "Tunnel up" : "Not reachable from elsewhere"
                    )
                }
                HostStatsBar(local: true)
            }
            .padding(Theme.Space.m)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func peerBody(_ peer: Peer) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.Space.m) {
                Text(peer.label.isEmpty ? (model.accountName(for: peer) ?? "Unnamed device") : peer.label)
                    .font(Theme.font(15, weight: .semibold))
                if let words = peer.words {
                    labeled("Known as", words)
                }
                labeled("Trust", Self.trustLabel(peer.trust))
                if model.connectedPeerKeys.contains(peer.key) {
                    Text("Workspaces from this device are in the sidebar.")
                        .font(Theme.caption)
                        .foregroundStyle(.secondary)
                    HostStatsBar(peer: peer.key, online: true)
                }

                VStack(alignment: .leading, spacing: Theme.Space.s) {
                    if peer.trust == .approved {
                        if model.connectedPeerKeys.contains(peer.key) {
                            Button("Disconnect", .disconnect) { model.disconnect(peer) }
                                .buttonStyle(SecondaryButtonStyle())
                        } else {
                            Button("Connect", .connect) { Task { await model.connect(peer) } }
                                .buttonStyle(AccentButtonStyle())
                        }
                        Button("Revoke", .revoke) { confirmRevoke = peer }
                            .buttonStyle(SecondaryButtonStyle())
                    } else {
                        Button("Approve", .approve) { Task { await model.approve(peer) } }
                            .buttonStyle(AccentButtonStyle())
                    }
                    Button("Forget", .delete, role: .destructive) { confirmForget = peer }
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
                    labeled("Code", id)
                }
                if isSelf {
                    Text("This device.")
                        .font(Theme.callout)
                        .foregroundStyle(.secondary)
                    HostStatsBar(local: true)
                } else if let peer = model.peer(for: machine) {
                    if machine.online == true, let key = machine.publicIdentity, !key.isEmpty {
                        HostStatsBar(peer: key, online: true)
                    }
                    peerActions(peer, machine: machine)
                } else if model.canConnect(machine) {
                    if machine.online == true, let key = machine.publicIdentity, !key.isEmpty {
                        HostStatsBar(peer: key, online: true)
                    }
                    Button("Connect", .connect) { Task { await model.connect(machine) } }
                        .buttonStyle(AccentButtonStyle())
                }
                if !isSelf {
                    Button("Remove from account", .delete, role: .destructive) {
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
            Button("Disconnect", .disconnect) { model.disconnect(peer) }
                .buttonStyle(SecondaryButtonStyle())
        } else {
            Button("Connect", .connect) { Task { await model.connect(peer) } }
                .buttonStyle(AccentButtonStyle())
        }
    }

    private static func trustLabel(_ trust: Peer.Trust) -> String {
        switch trust {
        case .pending: return "Waiting for approval"
        case .approved: return "Approved"
        case .revoked: return "Revoked"
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
