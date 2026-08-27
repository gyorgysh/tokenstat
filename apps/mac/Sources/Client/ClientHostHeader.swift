// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
//
// Source-available for review, NOT open source. See LICENSE: no rights to
// redistribute, publish, or ship a build are granted. Read it, study it, run
// your own build of it.
// "tokenstat" is a trademark of pueev OU. See TRADEMARK.md.

import SwiftUI

// The client is iOS and iPadOS only.
#if !os(macOS)

/// What another computer is doing, and the two ways in.
///
/// One view in two places on purpose. The machine's power, CPU and memory and
/// the View screen action only existed on the Devices detail page, so somebody
/// who thought "I want to see what that Mac is doing" opened it under
/// Workspaces, which is the honest reading of the word, and found a folder
/// list. Copying the header into that screen would have let the two drift, so
/// they share this one.
struct ClientHostHeader: View {
    let name: String
    let peerKey: String
    let online: Bool?
    /// The sentence under the name. Devices already composes one from the
    /// account's record; the work screen has no record to compose from.
    var reach: String?
    /// Off on the work screen, which is what Open work opens: a button that
    /// pushes the screen you are already on is a button that does nothing.
    var showsOpenWork = true

    @Environment(AccountModel.self) private var account
    @Environment(ClientStore.self) private var store

    private var canRemote: Bool {
        if let remote = account.account?.canRemote { return remote }
        switch account.account?.tier?.lowercased() {
        case "patron", "legend": return true
        default: return false
        }
    }

    private var isLegend: Bool { account.account?.tier?.lowercased() == "legend" }

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.s) {
            HStack(spacing: Theme.Space.s) {
                AwakeDot(online: online)
                VStack(alignment: .leading, spacing: 2) {
                    Text(name)
                        .font(ClientType.sectionTitle)
                    if let reach {
                        Text(reach)
                            .font(ClientType.label)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                Spacer(minLength: 0)
            }

            // Only for a host that is awake. A sleeping machine has no
            // readings, and a bar of dashes says less than no bar.
            if online == true, !peerKey.isEmpty {
                HostStatsBar(peer: peerKey, online: true)
            }

            if showsOpenWork { openWork }
            viewScreen
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(Theme.Space.m)
        .cardSurface()
    }

    /// Patron and above. The tier rules are the ones Devices already had.
    @ViewBuilder
    private var openWork: some View {
        if canRemote {
            NavigationLink {
                ClientHostWorkspacesView(peerKey: peerKey, hostName: name)
            } label: {
                DeviceActionRow(
                    title: "Open work",
                    subtitle: online == true
                        ? "Folders, terminals and sessions on this computer."
                        : "It is asleep. Opening this will wake nothing, but it will try.",
                    icon: .reveal
                )
            }
            .buttonStyle(DeviceActionRowStyle())
        } else {
            // The same seat and panel as the row it stands in for. An upsell
            // drawn as loose text beside two panelled rows reads as a
            // different component rather than as the locked version of one.
            HStack(spacing: Theme.Space.m) {
                ActionSeat(icon: .reveal)
                VStack(alignment: .leading, spacing: 4) {
                    Text("Open work")
                        .font(ClientType.label.weight(.medium))
                    Text("Opening folders and terminals on this computer is on Patron.")
                        .font(ClientType.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Button("See plans", .plans) { store.showPaywall = true }
                        .font(ClientType.caption.weight(.semibold))
                }
                Spacer(minLength: 0)
            }
            .frame(minHeight: 44)
            .padding(Theme.Space.m)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Theme.panel, in: RoundedRectangle(cornerRadius: Theme.cardRadius))
            .overlay {
                RoundedRectangle(cornerRadius: Theme.cardRadius)
                    .strokeBorder(Theme.border, lineWidth: 1)
            }
        }
    }

    /// Legend. The screen viewer says so itself when the tier is lower, so the
    /// row stays reachable rather than disappearing with no explanation.
    private var viewScreen: some View {
        NavigationLink {
            ScreenViewerView(peer: peerKey, name: name, tier: account.account?.tier)
        } label: {
            DeviceActionRow(
                title: "View screen",
                subtitle: isLegend ? "End-to-end encrypted from this device." : "Requires Legend.",
                icon: .preview
            )
        }
        .buttonStyle(DeviceActionRowStyle())
    }
}

#endif
