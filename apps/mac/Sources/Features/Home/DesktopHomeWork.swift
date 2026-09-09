// SPDX-License-Identifier: LicenseRef-tokenstat-source-available

import SwiftUI

/// Labels come from the loaded workspace directory and chat list. Home never
/// loads a transcript or contacts a peer to describe a recent destination.
struct DesktopHomeDestination: Identifiable {
    let reference: WorkReference
    let title: String
    let subtitle: String
    let unavailable: String?
    var id: WorkReference { reference }
}

struct DesktopContinueSection: View {
    let destinations: [DesktopHomeDestination]
    let onOpen: (WorkReference) -> Void

    var body: some View {
        if !destinations.isEmpty {
            Card(title: "Continue", subtitle: "The conversations you last opened",
                 leading: AnyView(ActionSeat(icon: .history, size: 24))) {
                VStack(spacing: 0) {
                    ForEach(destinations) { destination in
                        Button { onOpen(destination.reference) } label: {
                            HStack(spacing: Theme.Space.m) {
                                Image(systemName: "bubble.left.and.bubble.right")
                                    .foregroundStyle(Theme.accent)
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(destination.title).font(Theme.callout.weight(.medium))
                                    Text(destination.unavailable ?? destination.subtitle)
                                        .font(Theme.caption)
                                        .foregroundStyle(.secondary)
                                }
                                .lineLimit(2)
                                Spacer(minLength: 0)
                                Image(systemName: ActionIcon.next.symbol)
                                    .foregroundStyle(Theme.accent)
                            }
                            .padding(.vertical, Theme.Space.s)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .disabled(destination.unavailable != nil)
                        .help(destination.unavailable ?? "Open \(destination.title)")
                        if destination.id != destinations.last?.id { ThemeRule() }
                    }
                }
            }
            .accessibilityIdentifier("home.continue")
        }
    }
}

struct DesktopHomeMachines: View {
    let machines: [Machine]
    let onOpen: (Machine) -> Void

    var body: some View {
        if !machines.isEmpty {
            Card(title: "Machines", subtitle: "Devices linked to your account", mark: "mark_device") {
                VStack(spacing: 0) {
                    ForEach(machines) { machine in
                        Button { onOpen(machine) } label: {
                            HStack(spacing: Theme.Space.m) {
                                Image(systemName: machine.isHost ? "desktopcomputer" : "iphone")
                                    .foregroundStyle(Theme.accent)
                                    .frame(width: 24)
                                Text(machine.label.flatMap { $0.isEmpty ? nil : $0 } ?? "Device")
                                    .font(Theme.callout.weight(.medium))
                                    .lineLimit(2)
                                Spacer(minLength: Theme.Space.s)
                                Text(machine.online == true ? "Awake" : machine.online == false ? "Asleep" : "Status unknown")
                                    .font(Theme.caption)
                                    .foregroundStyle(.secondary)
                                Image(systemName: ActionIcon.next.symbol).foregroundStyle(Theme.accent)
                            }
                            .padding(.vertical, Theme.Space.s)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .help("Open this device in Devices")
                        if machine.id != machines.last?.id { ThemeRule() }
                    }
                }
            }
            .accessibilityIdentifier("home.machines")
        }
    }
}
