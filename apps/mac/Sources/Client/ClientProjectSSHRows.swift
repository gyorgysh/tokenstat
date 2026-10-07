// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
#if !os(macOS)
import SwiftUI

/// Associations are explicit; a server address does not identify a project.
struct ClientProjectSSHRows: View {
    let peer: String
    let workspace: String
    var sidebar = false
    var rowHeight: CGFloat = 44
    @Environment(ClientSSHWorkbench.self) private var workbench
    @State private var renaming: SSHLiveTerminal?
    @State private var name = ""
    @State private var closing: SSHLiveTerminal?

    private var linked: [SSHLiveTerminal] {
        workbench.projectLinks.sessions(peer: peer, workspace: workspace).compactMap { id in
            workbench.sessions.sessions.first { $0.id == id }
        }
    }
    private func title(_ session: SSHLiveTerminal) -> String {
        workbench.projectLinks.title(session.id, fallback: session.title)
    }

    var body: some View {
        Group {
            if sidebar { rows }
            else {
                VStack(alignment: .leading, spacing: Theme.Space.s) {
                    Text(L10n.text("apple.clientprojectssh.title")).font(ClientType.sectionTitle)
                    if linked.isEmpty {
                        Text(L10n.text("apple.clientprojectssh.empty"))
                            .font(ClientType.caption).foregroundStyle(.secondary)
                    }
                    rows
                }
                .padding(Theme.Space.m)
                .cardSurface()
            }
        }
        .alert(L10n.text("apple.clientprojectssh.rename"), isPresented: Binding(
            get: { renaming != nil }, set: { if !$0 { renaming = nil } }
        )) {
            TextField(L10n.text("apple.clientprojectssh.rename"), text: $name)
            Button(L10n.text("common.save"), .save) {
                if let renaming { workbench.rename(renaming, to: name) }
                renaming = nil
            }
            Button(L10n.text("common.cancel"), role: .cancel) { renaming = nil }
        }
        .confirmationDialog(L10n.text("apple.clientworkspacesview.close_this_session.2b66ce2d"),
            isPresented: Binding(get: { closing != nil }, set: { if !$0 { closing = nil } })) {
                if let closing {
                    Button(L10n.text("common.close"), role: .destructive) {
                        self.closing = nil
                        Task {
                            if await workbench.sessions.close(closing) {
                                workbench.projectLinks.prune(available: Set(workbench.sessions.sessions.map(\.id)))
                            }
                        }
                    }
                }
            }
        .onAppear { workbench.projectLinks.refresh() }
    }

    private var rows: some View {
        Group {
            ForEach(linked) { session in
                Button { workbench.show(session) } label: {
                    HStack(spacing: Theme.Space.s) {
                        Image(systemName: "terminal")
                        Text(title(session)).lineLimit(1)
                        Spacer(minLength: 0)
                        if session.alive {
                            Image(systemName: "circle.fill").font(Theme.fixed(6))
                                .foregroundStyle(Theme.accent)
                                .accessibilityLabel(L10n.text("common.running"))
                        }
                    }
                    .font(ClientType.caption)
                    .frame(minHeight: rowHeight)
                    .padding(.leading, sidebar ? Theme.Space.l : 0)
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("project.ssh.\(session.id)")
                .contextMenu {
                    Button(L10n.text("apple.clientprojectssh.rename"), .edit) {
                        name = title(session); renaming = session
                    }
                    Button(L10n.text("apple.clientprojectssh.remove"), .delete) {
                        workbench.projectLinks.detach(session.id, peer: peer, workspace: workspace)
                    }
                    Button(L10n.text("common.close"), role: .destructive) { closing = session }
                }
            }
            Menu {
                if workbench.sessions.sessions.isEmpty {
                    Text(L10n.text("apple.clientprojectssh.none"))
                }
                ForEach(workbench.sessions.sessions) { session in
                    Button(title(session), .connect) {
                        workbench.projectLinks.attach(session.id, peer: peer, workspace: workspace)
                    }
                    .disabled(linked.contains { $0.id == session.id })
                }
            } label: {
                Label(L10n.text("apple.clientprojectssh.attach"), systemImage: "plus")
                    .font(ClientType.caption)
                    .frame(minHeight: rowHeight)
                    .padding(.leading, sidebar ? Theme.Space.l : 0)
            }
            .accessibilityIdentifier("project.ssh.attach")
        }
    }
}
#endif
