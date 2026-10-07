// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
#if !os(macOS)
import SwiftUI

/// Open SSH servers belong to the device, independently of remote projects.
struct ClientServerRows: View {
    var rowHeight: CGFloat = 44
    @Environment(ClientSSHWorkbench.self) private var workbench
    @State private var expanded: Set<String> = []

    private var hosts: [SSHHost] {
        let ids = Set(workbench.sessions.sessions.compactMap(\.hostID))
        return workbench.library.hosts.filter { ids.contains($0.id) }
            .sorted { $0.label.localizedCaseInsensitiveCompare($1.label) == .orderedAscending }
    }

    var body: some View {
        if !hosts.isEmpty || !workbench.sessions.looseSessions.isEmpty {
            Section {
                ForEach(hosts) { host in
                    HStack(spacing: Theme.Space.s) {
                        Button {
                            if expanded.contains(host.id) { expanded.remove(host.id) }
                            else { expanded.insert(host.id) }
                        } label: {
                            Image(systemName: expanded.contains(host.id) ? "chevron.down" : "chevron.right")
                                .font(Theme.font(10)).frame(width: 20, height: rowHeight)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(L10n.text(expanded.contains(host.id)
                            ? "apple.rootview.collapse_sessions.1976b67d"
                            : "apple.rootview.expand_sessions.3675e61a"))
                        Button {
                            if let session = workbench.sessions.activeSession(for: host.id)
                                ?? workbench.sessions.sessions(for: host.id).first {
                                workbench.show(session)
                            }
                        } label: {
                            HStack(spacing: Theme.Space.s) {
                                Image(systemName: "terminal").foregroundStyle(Theme.accent)
                                Text(host.label).lineLimit(1)
                                Spacer(minLength: 0)
                                Text("\(workbench.sessions.liveCount(for: host.id))")
                                    .foregroundStyle(.secondary)
                            }.font(ClientType.body)
                        }.buttonStyle(.plain)
                    }
                    .clientSidebarRowSurface(isSelected: false, height: rowHeight)
                    .clientSidebarRowChrome()
                    .contextMenu {
                        Button(L10n.text("apple.rootview.new_terminal.fe544556"), .create) {
                            workbench.connect(host)
                        }
                    }
                    if expanded.contains(host.id) {
                        ForEach(workbench.sessions.sessions(for: host.id)) { session in
                            sessionRow(session)
                        }
                    }
                }
                ForEach(workbench.sessions.looseSessions) { session in sessionRow(session) }
            } header: {
                HStack {
                    Text(L10n.text("apple.rootview.servers.68d7beb6"))
                        .font(ClientType.caption.weight(.semibold)).textCase(.uppercase)
                    Spacer()
                    Text("\(hosts.count)").font(ClientType.caption.monospacedDigit())
                }.foregroundStyle(.secondary)
            }
        }
    }

    private func sessionRow(_ session: SSHLiveTerminal) -> some View {
        Button { workbench.show(session) } label: {
            Label(session.title, systemImage: session.alive ? "terminal.fill" : "terminal")
                .font(ClientType.caption).lineLimit(1)
                .padding(.leading, Theme.Space.l)
                .frame(maxWidth: .infinity, alignment: .leading)
                .clientSidebarRowSurface(isSelected: false, height: rowHeight)
        }
        .buttonStyle(.plain)
        .clientSidebarRowChrome()
        .accessibilityIdentifier("sidebar.server.session.\(session.id)")
    }
}
#endif
