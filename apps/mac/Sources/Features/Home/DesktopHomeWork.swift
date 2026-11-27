// SPDX-License-Identifier: LicenseRef-tokenstat-source-available

import SwiftUI

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
            Card(title: L10n.text("apple.desktophomework.continue.31fbef16"), subtitle: L10n.text("apple.desktophomework.the_conversations_you_last_opened.565f4f1f"),
                 leading: AnyView(ActionSeat(icon: .history, size: 24))) {
                VStack(spacing: 0) {
                    ForEach(destinations) { destination in
                        Button { onOpen(destination.reference) } label: {
                            HStack(spacing: Theme.Space.m) {
                                Image(systemName: "bubble.left.and.bubble.right")
                                    .foregroundStyle(Theme.accent)
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(destination.title)
                                        .font(Theme.callout.weight(.medium))
                                        .lineLimit(2)
                                    Text(destination.unavailable ?? destination.subtitle)
                                        .font(Theme.caption)
                                        .foregroundStyle(.secondary)
                                        .lineLimit(1)
                                }
                                .layoutPriority(1)
                                Spacer(minLength: 0)
                                RowChevron()
                            }
                            .padding(.vertical, Theme.Space.s)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(RowFeedbackStyle())
                        .disabled(destination.unavailable != nil)
                        .help(destination.unavailable ?? L10n.text("apple.desktophomework.open_0.e71b4013", "\(destination.title)"))
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
            Card(title: L10n.text("apple.desktophomework.machines.c061da19"), subtitle: L10n.text("apple.desktophomework.devices_linked_to_your_account.dc6eb913"), mark: "mark_device") {
                VStack(spacing: 0) {
                    ForEach(machines) { machine in
                        Button { onOpen(machine) } label: {
                            HStack(spacing: Theme.Space.m) {
                                Image(systemName: ClientDeviceIcon.symbol(for: machine))
                                    .foregroundStyle(Theme.accent)
                                    .frame(width: 24)
                                Text(machine.label.flatMap { $0.isEmpty ? nil : $0 } ?? L10n.text("apple.desktophomework.device.6ba0bdec"))
                                    .font(Theme.callout.weight(.medium))
                                    .lineLimit(2)
                                Spacer(minLength: Theme.Space.s)
                                Text(machine.online == true ? L10n.text("apple.desktophomework.awake.9123b5f4") : machine.online == false ? L10n.text("apple.desktophomework.asleep.60135e8f") : L10n.text("apple.desktophomework.status_unknown.e412d872"))
                                    .font(Theme.caption)
                                    .foregroundStyle(.secondary)
                                RowChevron()
                            }
                            .padding(.vertical, Theme.Space.s)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(RowFeedbackStyle())
                        .help(L10n.text("apple.desktophomework.open_this_device_in_devices.24ae7e3a"))
                        if machine.id != machines.last?.id { ThemeRule() }
                    }
                }
            }
            .accessibilityIdentifier("home.machines")
        }
    }
}
