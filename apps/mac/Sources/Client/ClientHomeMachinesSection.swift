// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
//
// Source-available for review, NOT open source. See LICENSE: no rights to
// redistribute, publish, or ship a build are granted. Read it, study it, run
// your own build of it.
// "tokenstat" is a trademark of pueev OU. See TRADEMARK.md.

import SwiftUI

#if !os(macOS)

/// Which of your computers is awake right now, on the screen that opens.
///
/// Account plane only: names, dots and last-seen words come from the account
/// list, so this draws with every laptop shut. Tapping a row hands over to
/// Devices, which owns the detail screen, rather than growing a second one.
struct ClientHomeMachinesSection: View {
    @Environment(AccountModel.self) private var account
    @Environment(ClientNavigationModel.self) private var navigation

    /// Awake hosts on this account, minus this phone. Asleep ones stay off
    /// this screen: the list is a jumping-off point, not an inventory, and
    /// Devices already inventories everything. Old records predate the kind
    /// field and read as hosts, so the phone is excluded by id, the same way
    /// the Workspaces list does it. Rows without an id cannot be opened, so
    /// they are not rows.
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
                    ClientSectionTitle(title: "Machines", mark: "mark_host")
                    Spacer(minLength: 0)
                    Button {
                        navigation.destination = .machines
                    } label: {
                        HStack(spacing: 2) {
                            Text("Devices")
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
                        Button {
                            navigation.openDevice(machineID: machine.machineID)
                        } label: {
                            row(machine)
                        }
                        .buttonStyle(.plain)
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
        if machine.online == true { return "Awake" }
        if machine.online == false { return "Asleep" }
        return "Status unknown"
    }
}

#endif
