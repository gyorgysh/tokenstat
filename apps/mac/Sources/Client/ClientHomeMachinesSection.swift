// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
//
// Source-available: source sharing and own builds are permitted.
// Store and commercial distribution of builds is reserved. See LICENSE.
// "tokenstat" is a trademark of pueev OU. See TRADEMARK.md.

import SwiftUI

#if !os(macOS)

struct ClientHomeMachinesSection: View {
    @Environment(AccountModel.self) private var account
    @Environment(ClientNavigationModel.self) private var navigation

    private var hosts: [Machine] {
        let thisID = account.account?.thisMachineID
        return (account.account?.machines ?? []).filter { machine in
            guard machine.isHost, machine.online == true else { return false }
            guard let id = machine.machineID, !id.isEmpty else { return false }
            if let thisID, id == thisID { return false }
            return true
        }
    }

    var body: some View {
        if !hosts.isEmpty {
            VStack(alignment: .leading, spacing: Theme.Space.s) {
                HStack(alignment: .center, spacing: Theme.Space.s) {
                    ClientSectionTitle(title: L10n.text("apple.clienthomemachinessection.machines.c061da19"), mark: "mark_host")
                    Spacer(minLength: 0)
                    Button {
                        navigation.destination = .machines
                    } label: {
                        HStack(spacing: 2) {
                            Text(L10n.text("common.devices"))
                            Image(systemName: "chevron.right")
                        }
                        .font(ClientType.caption.weight(.semibold))
                    }
                    .tint(Theme.accent)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 2)
                VStack(spacing: 0) {
                    ForEach(hosts) { machine in
                        if let key = machine.publicIdentity, !key.isEmpty {
                            NavigationLink {
                                ClientHostWorkspacesView(peerKey: key, hostName: machine.displayName)
                            } label: {
                                row(machine)
                            }
                            .buttonStyle(.plain)
                            .accessibilityHint(L10n.text("apple.clienthomemachinessection.opens_this_computer_s_work.c072040d"))
                        } else {
                            Button {
                                navigation.openDevice(machineID: machine.machineID)
                            } label: {
                                row(machine)
                            }
                            .buttonStyle(.plain)
                        }
                        if machine.id != hosts.last?.id {
                            ThemeRule().padding(.horizontal, Theme.Space.m)
                        }
                    }
                }
                .cardSurface()
            }
            .accessibilityIdentifier("home.machines")
        }
    }

    private func row(_ machine: Machine) -> some View {
        HStack(spacing: Theme.Space.m) {
            Circle()
                .fill(machine.online == true ? Theme.accent : Color.secondary.opacity(0.35))
                .frame(width: 9, height: 9)
                .accessibilityHidden(true)
            Image(systemName: ClientDeviceIcon.symbol(name: machine.displayName, isHost: true))
                .font(ClientType.body)
                .foregroundStyle(.secondary)
                .frame(width: 24)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(machine.displayName)
                    .font(ClientType.label.weight(.medium))
                    .lineLimit(1)
                Text(state(of: machine))
                    .font(ClientType.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Image(systemName: "chevron.right")
                .font(ClientType.caption)
                .foregroundStyle(.tertiary)
                .accessibilityHidden(true)
        }
        .padding(Theme.Space.m)
        .frame(minHeight: 60)
        .contentShape(.rect)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(machine.displayName), \(state(of: machine))")
    }

    private func state(of machine: Machine) -> String {
        if machine.online == true { return L10n.text("apple.clienthomemachinessection.awake.9123b5f4") }
        if machine.online == false { return L10n.text("apple.clienthomemachinessection.asleep.60135e8f") }
        return L10n.text("apple.clienthomemachinessection.status_unknown.e412d872")
    }
}

#endif
