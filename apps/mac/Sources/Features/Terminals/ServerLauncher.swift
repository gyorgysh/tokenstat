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

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.s) {
            HStack {
                Label(L10n.text("apple.rootview.servers.68d7beb6"), systemImage: "server.rack")
                    .font(Theme.callout.weight(.semibold))
                Spacer(minLength: Theme.Space.s)
                Button(L10n.text("apple.serverlauncher.manage_servers"), .settings, action: onManage)
                    .font(Theme.caption).buttonStyle(.plain).foregroundStyle(Theme.accent)
            }
            ForEach(library.launcherHosts) { host in
                Button { onOpen(host) } label: {
                    HStack(spacing: Theme.Space.s) {
                        SSHHostPlatformMark(label: SSHHostPlatformCache.shared.label(for: host))
                            .accessibilityHidden(true)
                        VStack(alignment: .leading, spacing: 3) {
                            Text(host.label).font(Theme.callout.weight(.medium))
                                .foregroundStyle(.primary).lineLimit(1)
                            Text(sessions.liveCount(for: host.id) > 0 ? L10n.text("apple.connectionmodel.connected.22965568") : L10n.text("apple.sshlibraryview.ssh.01c4d3c2"))
                                .font(Theme.caption).foregroundStyle(.secondary)
                        }
                        Spacer(minLength: Theme.Space.s)
                        Label(sessions.liveCount(for: host.id) > 0 ? L10n.text("common.open") : L10n.text("common.connect"),
                              systemImage: sessions.liveCount(for: host.id) > 0 ? "terminal" : "arrow.right")
                            .font(Theme.caption.weight(.medium)).foregroundStyle(Theme.accent)
                    }
                    .padding(Theme.Space.m)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Theme.panel, in: RoundedRectangle(cornerRadius: 8))
                    .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Theme.border))
                    .contentShape(RoundedRectangle(cornerRadius: 8))
                }
                .buttonStyle(.plain)
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
