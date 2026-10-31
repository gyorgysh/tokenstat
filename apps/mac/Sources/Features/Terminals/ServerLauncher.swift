// SPDX-License-Identifier: LicenseRef-tokenstat-source-available

#if os(macOS)
import SwiftUI

/// Saved SSH destinations in both terminal launchers. Opening a live server
/// returns to its shell; a disconnected one uses the normal connection form.
struct ServerLauncher: View {
    let library: SSHLibraryModel
    let sessions: SSHSessionsModel
    let onOpen: (SSHHost) -> Void
    let onManage: () -> Void
    @State private var expanded = false

    private var shownHosts: [SSHHost] {
        expanded ? library.launcherHosts : Array(library.launcherHosts.prefix(2))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.s) {
            HStack {
                Label(L10n.text("apple.rootview.servers.68d7beb6"), systemImage: "server.rack")
                    .font(Theme.callout.weight(.semibold))
                Spacer(minLength: Theme.Space.s)
                Button(L10n.text("apple.serverlauncher.manage_servers"), .settings, action: onManage)
                    .font(Theme.caption).buttonStyle(.plain).foregroundStyle(Theme.accent)
            }
            if !library.launcherHosts.isEmpty {
                VStack(spacing: 0) {
                    ForEach(Array(shownHosts.enumerated()), id: \.element.id) { index, host in
                        if index > 0 { Divider().padding(.leading, Theme.Space.m) }
                        Button { onOpen(host) } label: {
                            HStack(spacing: Theme.Space.s) {
                                SSHHostPlatformMark(label: SSHHostPlatformCache.shared.label(for: host))
                                    .accessibilityHidden(true)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(host.label).font(Theme.callout.weight(.medium))
                                        .foregroundStyle(.primary).lineLimit(1)
                                    Text(sessions.liveCount(for: host.id) > 0
                                         ? L10n.text("apple.connectionmodel.connected.22965568")
                                         : L10n.text("apple.sshlibraryview.ssh.01c4d3c2"))
                                        .font(Theme.caption).foregroundStyle(.secondary)
                                }
                                Spacer(minLength: Theme.Space.s)
                                Image(systemName: "chevron.right")
                                    .font(Theme.caption.weight(.semibold))
                                    .foregroundStyle(.tertiary)
                            }
                            .padding(.horizontal, Theme.Space.m)
                            .frame(maxWidth: .infinity, minHeight: 52, alignment: .leading)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                    if library.launcherHosts.count > 2 {
                        Divider()
                        Button {
                            expanded.toggle()
                        } label: {
                            Label(
                                expanded
                                    ? L10n.text("apple.clientrecentchats.show_less.94ea9b1d")
                                    : L10n.text("apple.clientrecentchats.show_more_0_more.c732a4ba", "\(library.launcherHosts.count - 2)"),
                                systemImage: expanded ? "chevron.up" : "chevron.down"
                            )
                            .font(Theme.caption.weight(.semibold))
                            .foregroundStyle(Theme.accent)
                            .frame(maxWidth: .infinity, minHeight: 44)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }
                .background(Theme.panel, in: RoundedRectangle(cornerRadius: Theme.cardRadius))
                .overlay(RoundedRectangle(cornerRadius: Theme.cardRadius).strokeBorder(Theme.border))
            }
            if library.hosts.isEmpty {
                Text(library.loaded ? L10n.text("apple.sshsectionview.no_servers_yet.7846930c") : L10n.text("apple.serverlauncher.loading_servers"))
                    .font(Theme.caption).foregroundStyle(.secondary)
            }
        }
    }
}

extension SSHLibraryModel {
    var launcherHosts: [SSHHost] {
        hosts.sorted {
            if $0.favorite != $1.favorite { return $0.favorite }
            if $0.sort != $1.sort { return $0.sort < $1.sort }
            let order = $0.label.localizedStandardCompare($1.label)
            return order == .orderedSame ? $0.id < $1.id : order == .orderedAscending
        }
    }
}
#endif
