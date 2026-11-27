// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
//
// Source-available, not open source. See LICENSE for permissions and restrictions.

import SwiftUI
#if !os(macOS)
import UIKit
#endif

enum SSHLibraryRoute: Hashable {
    case host(String)
    case newHost(folder: String?)
    case key(String)
    case newKey
    case snippet(String)
    case newSnippet
    case folder(String)
    case newFolder(parent: String?)
    case knownHost(String)
    case knownHosts
    case importConfig
    case importCloud
}

#if !os(macOS)
struct SSHLibraryView: View {
    var vaultTier: String?
    var onClose: (() -> Void)?

    enum Section: String, CaseIterable, Identifiable {
        case hosts = "Hosts"
        case keys = "Keys"
        case snippets = "Snippets"
        var id: String { rawValue }
        var searchPrompt: String {
            switch self {
            case .hosts: L10n.text("apple.sshlibraryview.search_hosts")
            case .keys: L10n.text("apple.sshlibraryview.search_keys")
            case .snippets: L10n.text("apple.sshlibraryview.search_snippets")
            }
        }
        var addTitle: String {
            switch self {
            case .hosts: L10n.text("apple.sshlibraryview.add_host")
            case .keys: L10n.text("apple.sshlibraryview.add_key")
            case .snippets: L10n.text("apple.sshlibraryview.add_snippet")
            }
        }
        var emptyTitle: String {
            switch self {
            case .hosts: L10n.text("apple.sshlibraryview.no_hosts_yet")
            case .keys: L10n.text("apple.sshlibraryview.no_keys_yet")
            case .snippets: L10n.text("apple.sshlibraryview.no_snippets_yet")
            }
        }
    }

    @Environment(ClientStore.self) private var store
    @Environment(ClientSSHWorkbench.self) private var workbench
    private var model: SSHLibraryModel { workbench.library }
    private var sessions: SSHSessionsModel { workbench.sessions }
    private var vault: SSHVaultModel { workbench.vault }
    private var section: Section { get { workbench.section } nonmutating set { workbench.section = newValue } }
    private var route: SSHLibraryRoute? { get { workbench.route } nonmutating set { workbench.route = newValue } }
    private var expanded: Set<String> { get { workbench.expanded } nonmutating set { workbench.expanded = newValue } }
    private var connecting: SSHHost? {
        get { workbench.connection?.host }
        nonmutating set { if let newValue { workbench.connect(newValue) } }
    }
    private var showingVault: Bool { get { workbench.showingVault } nonmutating set { workbench.showingVault = newValue } }
    private var showingTerminal: Bool {
        get { workbench.terminal != nil }
        nonmutating set { workbench.terminal = newValue ? .init() : nil }
    }

    private var paidVaultTier: String? { SSHLibraryModel.paidTier(for: vaultTier) }

    private var signedInUnpaid: Bool { vaultTier != nil && paidVaultTier == nil }

    var body: some View { content }


    private var content: some View {
        listSide
            .navigationTitle(L10n.text("apple.sshlibraryview.ssh.01c4d3c2"))
            .toolbar { toolbarContent }
            .navigationDestination(item: Binding(get: { route }, set: { route = $0 })) { destination($0) }
    }

    @ViewBuilder
    private func destination(_ route: SSHLibraryRoute) -> some View {
        switch route {
        case let .host(id):
            SSHHostEditor(model: model, hostID: id, folderID: nil, onDone: close)
                .toolbar {
                    if let host = model.hosts.first(where: { $0.id == id }) {
                        ToolbarItem(placement: .primaryAction) {
                            Button(L10n.text("common.connect"), .connect) { connecting = host }
                        }
                    }
                }
        case let .newHost(folder):
            SSHHostEditor(model: model, hostID: nil, folderID: folder, onDone: close)
        case let .key(id):
            SSHKeyEditor(model: model, keyID: id, onDone: close)
        case .newKey:
            SSHKeyEditor(model: model, keyID: nil, onDone: close)
        case let .snippet(id):
            SSHSnippetEditor(model: model, snippetID: id, onDone: close)
        case .newSnippet:
            SSHSnippetEditor(model: model, snippetID: nil, onDone: close)
        case let .folder(id):
            SSHFolderEditor(model: model, folderID: id, parentID: nil, onDone: close)
        case let .newFolder(parent):
            SSHFolderEditor(model: model, folderID: nil, parentID: parent, onDone: close)
        case .knownHost, .knownHosts:
            SSHKnownHostsView(model: model)
        case .importConfig:
            SSHConfigImportView(model: model, onDone: close)
        case .importCloud:
            CloudImportForm(model: model, onDone: close)
        }
    }


    private var listSide: some View {
        VStack(spacing: 0) {
            header
            if let error = model.error {
                InlineBanner(text: FriendlyError.from(error).message, kind: .danger) { model.error = nil }
                    .padding(.horizontal, Theme.Space.m)
                    .padding(.bottom, Theme.Space.s)
            }
            if let vaultError = model.vaultError {
                let friendly = FriendlyError.from(vaultError)
                InlineBanner(text: L10n.text("apple.sshlibraryview.saved_on_this_device_but_not_synced_0.97b249b6", "\(friendly.message)")) {
                    model.vaultError = nil
                }
                .padding(.horizontal, Theme.Space.m)
                .padding(.bottom, Theme.Space.s)
            }
            if signedInUnpaid, model.hosts.isEmpty {
                vaultUpgrade
                Spacer(minLength: 0)
            } else if isEmpty {
                EmptyState(symbol: emptySymbol, title: emptyTitle, message: emptyMessage) {
                    Button(emptyActionTitle, .create) { open(addRoute) }
                        .buttonStyle(AccentButtonStyle())
                }
                .frame(maxHeight: .infinity)
            } else {
                list
            }
        }
        .background(Theme.background)
    }

    private var header: some View {
        VStack(spacing: Theme.Space.s) {
            if vaultTier != nil {
                SSHVaultRow(vault: vault, canWrite: paidVaultTier != nil) { showingVault = true }
            }
            SegmentedTabs(options: Section.allCases, selection: Binding(get: { section }, set: { section = $0 }))
            SearchField(text: Binding(get: { model.search }, set: { model.search = $0 }), prompt: section.searchPrompt)
        }
        .padding(Theme.Space.m)
    }

    @ViewBuilder
    private var list: some View {
        List {
            switch section {
            case .hosts:
                if !model.searching, !sessions.sessions.isEmpty {
                    SwiftUI.Section(L10n.text("apple.sshlibraryview.open_sessions.8bf47766")) {
                        ForEach(sessions.sessions) { session in sessionRow(session) }
                    }
                }
                if !model.searching, !model.recentHosts.isEmpty {
                    SwiftUI.Section(L10n.text("apple.sshlibraryview.recent.690dbe9d")) {
                        ForEach(model.recentHosts) { host in hostRow(host, depth: 0) }
                    }
                }
                SwiftUI.Section(model.searching ? L10n.text("apple.sshlibraryview.results.219c4a6c") : L10n.text("apple.sshlibraryview.all_servers.3205261a")) {
                    ForEach(rows) { row in
                        switch row.kind {
                        case let .folder(folder):
                            folderRow(folder, depth: row.depth)
                        case let .host(host):
                            hostRow(host, depth: row.depth)
                        }
                    }
                }
            case .keys:
                ForEach(model.visibleKeys) { key in keyRow(key) }
            case .snippets:
                ForEach(model.visibleSnippets) { snippet in snippetRow(snippet) }
            }
        }
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
        .background(Theme.background)
        .listRowSeparatorTint(Theme.border)
    }

    private struct Row: Identifiable {
        enum Kind {
            case folder(SSHFolder)
            case host(SSHHost)
        }

        let id: String
        let kind: Kind
        let depth: Int
    }

    private var rows: [Row] {
        var out: [Row] = []
        func walk(parent: String?, depth: Int) {
            for folder in model.folders(in: parent) {
                out.append(Row(id: "folder:\(folder.id)", kind: .folder(folder), depth: depth))
                guard expanded.contains(folder.id) else { continue }
                walk(parent: folder.id, depth: depth + 1)
                for host in model.hosts(in: folder.id) {
                    out.append(Row(id: "host:\(host.id)", kind: .host(host), depth: depth + 1))
                }
            }
            if depth == 0 {
                for host in model.hosts(in: nil) {
                    out.append(Row(id: "host:\(host.id)", kind: .host(host), depth: 0))
                }
            }
        }
        walk(parent: nil, depth: 0)
        return out
    }

    private func folderRow(_ folder: SSHFolder, depth: Int) -> some View {
        HStack(spacing: Theme.Space.xs) {
            Image(systemName: expanded.contains(folder.id) ? "chevron.down" : "chevron.right")
                .font(Theme.font(10, weight: .semibold))
                .foregroundStyle(.secondary)
                .frame(width: 12)
            Image(systemName: "folder")
                .foregroundStyle(SSHColor.color(folder.color))
            Text(folder.name)
            Spacer()
            Text("\(model.hosts(in: folder.id).count)")
                .font(Theme.caption).foregroundStyle(.secondary)
        }
        .padding(.leading, CGFloat(depth) * 14)
        .frame(height: Theme.Control.rowHeight)
        .contentShape(.rect)
        .onTapGesture {
            if expanded.contains(folder.id) { expanded.remove(folder.id) } else { expanded.insert(folder.id) }
        }
        .contextMenu {
            Button(L10n.text("apple.sshlibraryview.rename_folder.7249f19c")) { open(.folder(folder.id)) }
            Button(L10n.text("apple.sshlibraryview.add_server_here.a85b2f00")) { open(.newHost(folder: folder.id)) }
            Button(L10n.text("apple.sshlibraryview.add_sub_folder.768dadd9")) { open(.newFolder(parent: folder.id)) }
            Button(L10n.text("apple.sshlibraryview.delete_folder.39f35f2d"), role: .destructive) {
                Task { await model.delete(folder: folder) }
            }
        }
        .themedRow()
    }

    private func sessionRow(_ session: SSHLiveTerminal) -> some View {
        HStack(spacing: Theme.Space.s) {
            Circle()
                .fill(session.alive ? Theme.accent : Theme.stateIdle)
                .frame(width: 8, height: 8)
            VStack(alignment: .leading, spacing: 1) {
                Text(session.title).lineLimit(1)
                Text(session.alive ? L10n.text("common.running") : L10n.text("apple.sshlibraryview.ended.7cdc804e"))
                    .font(Theme.caption).foregroundStyle(.secondary)
                if let failure = sessions.closeErrors[session.id] {
                    Text(failure).font(Theme.caption).foregroundStyle(.red).lineLimit(2)
                }
            }
            Spacer(minLength: 0)
            Image(systemName: "chevron.right").font(Theme.caption).foregroundStyle(.tertiary)
        }
        .frame(minHeight: Theme.Control.rowHeight)
        .contentShape(.rect)
        .onTapGesture {
            sessions.select(session)
            showingTerminal = true
        }
        .swipeActions(edge: .trailing) {
            Button(L10n.text("apple.sshlibraryview.end.f4db1e48"), role: .destructive) { Task { await sessions.close(session) } }
        }
        .themedRow()
    }

    private func hostRow(_ host: SSHHost, depth: Int) -> some View {
        SSHHostRow(
            host: host,
            folder: model.folderName(host.folderID),
            searching: model.searching,
            onConnect: { connecting = host }
        )
            .padding(.leading, CGFloat(depth) * 14)
            .contentShape(.rect)
            .onTapGesture { open(.host(host.id)) }
            .contextMenu {
                Button(L10n.text("common.connect")) { connecting = host }
                Button(host.favorite ? L10n.text("apple.sshlibraryview.remove_from_favourites.a5bdeced") : L10n.text("apple.sshlibraryview.add_to_favourites.9e619bff")) {
                    var updated = host
                    updated.favorite.toggle()
                    Task { _ = await model.save(host: updated) }
                }
                Button(L10n.text("common.edit")) { open(.host(host.id)) }
                Button(L10n.text("common.delete"), role: .destructive) { Task { await model.delete(host: host) } }
            }
            .swipeActions(edge: .trailing) {
                Button(L10n.text("common.delete"), role: .destructive) { Task { await model.delete(host: host) } }
            }
            .swipeActions(edge: .leading) {
                Button(L10n.text("common.connect")) { connecting = host }.tint(Theme.accent)
            }
        .themedRow()
    }

    private func keyRow(_ key: SSHKeyRecord) -> some View {
        Label {
            VStack(alignment: .leading, spacing: 2) {
                Text(key.label).font(SSHRowType.name)
                Text(SSHLibraryView.shortFingerprint(key.fingerprint) ?? key.algorithm)
                    .font(SSHRowType.mono)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.head)
            }
        } icon: {
            Image(systemName: key.hardwareBacked ? "key.radiowaves.forward" : "key.fill")
                .foregroundStyle(Theme.accent)
        }
        .frame(minHeight: 44)
        .contentShape(.rect)
        .onTapGesture { open(.key(key.id)) }
        .contextMenu {
            Button(L10n.text("common.edit")) { open(.key(key.id)) }
            Button(L10n.text("apple.sshlibraryview.copy_public_key.5f2f4548")) { copyToPasteboard(key.publicKey) }
            if !key.fingerprint.isEmpty {
                Button(L10n.text("apple.sshlibraryview.copy_fingerprint.71ab1ba9")) { copyToPasteboard(key.fingerprint) }
            }
            Button(L10n.text("common.delete"), role: .destructive) { Task { await model.delete(key: key) } }
        }
        .swipeActions(edge: .trailing) {
            Button(L10n.text("common.delete"), role: .destructive) { Task { await model.delete(key: key) } }
        }
        .themedRow()
    }

    private func snippetRow(_ snippet: SSHSnippet) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(snippet.title).font(SSHRowType.name)
            Text(snippet.command)
                .font(SSHRowType.mono)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.tail)
        }
        .frame(minHeight: 44)
        .contentShape(.rect)
        .onTapGesture { open(.snippet(snippet.id)) }
        .contextMenu {
            Button(L10n.text("common.edit")) { open(.snippet(snippet.id)) }
            Button(L10n.text("apple.sshlibraryview.copy_command.9a01feec")) { copyToPasteboard(snippet.command) }
            Button(snippet.runOnConnect ? L10n.text("apple.sshlibraryview.do_not_run_on_connect.7917a1db") : L10n.text("apple.sshlibraryview.run_on_connect.185c4e03")) {
                var updated = snippet
                updated.runOnConnect.toggle()
                Task { _ = await model.save(snippet: updated) }
            }
            .disabled(!snippet.runOnConnect && (snippet.hostIDs.isEmpty || !SSHSnippet.placeholders(in: snippet.command).isEmpty))
            Button(L10n.text("common.delete"), role: .destructive) { Task { await model.delete(snippet: snippet) } }
        }
        .swipeActions(edge: .trailing) {
            Button(L10n.text("common.delete"), role: .destructive) { Task { await model.delete(snippet: snippet) } }
        }
        .themedRow()
    }

    private func copyToPasteboard(_ value: String) {
        UIPasteboard.general.string = value
    }

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        if let onClose {
            ToolbarItem(placement: .cancellationAction) {
                InspectorCloseButton(action: onClose, help: L10n.text("common.close"), label: L10n.text("apple.sshlibraryview.close_ssh_library.23516468"))
            }
        }
        ToolbarItem(placement: .primaryAction) {
            Menu {
                Button(section.addTitle) { open(addRoute) }
                if section == .hosts {
                    Button(L10n.text("apple.sshlibraryview.add_folder.5bbfc5a6")) { open(.newFolder(parent: nil)) }
                    ThemeRule()
                    Button(L10n.text("apple.sshlibraryview.import_from_ssh_config.1b6e8c38")) { open(.importConfig) }
                    Button(L10n.text("apple.sshlibraryview.import_cloud_servers.34d6891a")) { open(.importCloud) }
                    Button(L10n.text("apple.sshlibraryview.trusted_servers.b101ed86")) { open(.knownHosts) }
                }
            } label: {
                Label(L10n.text("common.add"), systemImage: "plus")
            }
        }
    }


    private func close() { route = nil }

    private func open(_ destination: SSHLibraryRoute) { route = destination }

    static func shortFingerprint(_ value: String) -> String? {
        guard !value.isEmpty else { return nil }
        guard let separator = value.firstIndex(of: ":") else { return value }
        let body = String(value[value.index(after: separator)...])
        return body.isEmpty ? value : body
    }

    private var addRoute: SSHLibraryRoute {
        switch section {
        case .hosts: .newHost(folder: nil)
        case .keys: .newKey
        case .snippets: .newSnippet
        }
    }

    private var isEmpty: Bool {
        switch section {
        case .hosts: model.hosts.isEmpty && model.folders.isEmpty
        case .keys: model.keys.isEmpty
        case .snippets: model.snippets.isEmpty
        }
    }

    private var emptySymbol: String {
        switch section {
        case .hosts: "server.rack"
        case .keys: "key"
        case .snippets: "text.badge.plus"
        }
    }

    private var emptyTitle: String { section.emptyTitle }

    private var emptyMessage: String {
        switch section {
        case .hosts: L10n.text("apple.sshlibraryview.add_a_server_once_then_connect_without_ret.ceca4076")
        case .keys: L10n.text("apple.sshlibraryview.generate_or_import_an_ssh_key_to_authentic.406e6d7d")
        case .snippets: L10n.text("apple.sshlibraryview.save_commands_you_use_often_and_run_them_f.a621eb59")
        }
    }

    private var emptyActionTitle: String {
        switch section {
        case .hosts: L10n.text("apple.sshlibraryview.add_host.7da3f6f4")
        case .keys: L10n.text("apple.sshlibraryview.add_key.12626d65")
        case .snippets: L10n.text("apple.sshlibraryview.add_snippet.a1f802b9")
        }
    }

    private var vaultUpgrade: some View {
        ClientEmptyState(
            kind: .needsAccount,
            title: L10n.text("apple.sshlibraryview.sync_ssh_between_your_devices.8bd160ae"),
            message: L10n.text("apple.sshlibraryview.an_encrypted_vault_keeps_hosts_and_keys_on.75c5e63a"),
            actionTitle: L10n.text("apple.sshlibraryview.see_plans.d9898933"),
            actionIcon: .plans,
            action: { store.showPaywall = true },
            art: .vault
        )
        .padding(.horizontal, Theme.Space.m)
    }
}
#endif

extension View {
    func themedRow() -> some View {
        listRowBackground(Theme.panel)
            .listRowSeparatorTint(Theme.border)
    }
}

/// The type scale the library's rows share.
///
/// The Mac's default body size on a phone is a Mac list pretending to be a
/// phone one: the client next door reads its sizes from `ClientType` so a row
/// scales with Dynamic Type, and these rows were the only ones in the app
/// still asking for a fixed system default. One place for both platforms, so
/// a name means the same weight on each.
enum SSHRowType {
    #if os(macOS)
    static let name = Theme.font(13)
    static let detail = Font.caption
    #else
    static let name = ClientType.label.weight(.medium)
    static let detail = ClientType.caption
    #endif

    static let mono = Theme.mono(11)
}

struct SSHHostRow: View {
    let host: SSHHost
    let folder: String?
    let searching: Bool
    var onConnect: (() -> Void)?

    private var platform: String? { SSHHostPlatformCache.shared.label(for: host) }

    var body: some View {
        HStack(spacing: Theme.Space.s) {
            RoundedRectangle(cornerRadius: 2)
                .fill(SSHColor.color(host.color))
                #if os(macOS)
                .frame(width: 3)
                #else
                .frame(width: 4)
                #endif
            SSHHostPlatformMark(label: platform)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: Theme.Space.xs) {
                    Text(host.label)
                        .font(SSHRowType.name)
                        .lineLimit(1)
                    if host.favorite {
                        Image(systemName: "star.fill")
                            .font(Theme.font(9))
                            .foregroundStyle(Theme.warning)
                    }
                }
                if searching, let folder {
                    Text(folder)
                        .font(Theme.caption2)
                        .padding(.horizontal, 5).padding(.vertical, 1)
                        .background(Theme.rowHighlight, in: Capsule())
                        .foregroundStyle(.secondary)
                }
                if let platform {
                    Text(platform).font(Theme.caption).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            Spacer(minLength: 0)
            if let onConnect {
                #if os(macOS)
                Button(L10n.text("common.connect"), .connect, action: onConnect)
                    .buttonStyle(SecondaryButtonStyle(small: true))
                    .accessibilityLabel(L10n.text("apple.sshlibraryview.connect_to_0.fee15415", "\(host.label)"))
                #else
                Button(L10n.text("common.connect"), .connect, action: onConnect)
                    .buttonStyle(AccentButtonStyle())
                    .frame(minHeight: 44)
                #endif
            }
        }
        // A fixed height on a phone is a row that cannot hold a second line of
        // Dynamic Type and a tap target that shrinks with the text. A floor
        // instead, so the row grows and never goes under 44.
        #if os(macOS)
        .frame(minHeight: platform == nil ? 48 : 62)
        #else
        .frame(minHeight: 44)
        #endif
    }
}

struct SearchField: View {
    @Binding var text: String
    let prompt: String

    var body: some View {
        HStack(spacing: Theme.Space.xs) {
            Image(systemName: "magnifyingglass")
                .font(Theme.font(12))
                .foregroundStyle(.secondary)
            TextField(prompt, text: $text)
                .textFieldStyle(.plain)
            if !text.isEmpty {
                Button {
                    text = ""
                } label: {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                }
                .buttonStyle(ControlFeedbackStyle(pressScale: 0.9))
                .accessibilityLabel(L10n.text("apple.sshlibraryview.clear_search.3b7ea517"))
            }
        }
        .padding(.horizontal, Theme.Space.s)
        .frame(height: Theme.Control.height)
        .background(Theme.panel, in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Theme.border))
    }
}

struct InlineBanner: View {
    enum Kind { case danger, info }
    let text: String
    var kind: Kind = .info
    var dismiss: (() -> Void)?

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: Theme.Space.s) {
            Image(systemName: kind == .danger ? "exclamationmark.triangle.fill" : "info.circle")
                .foregroundStyle(kind == .danger ? Theme.danger : Theme.accent)
            Text(text).font(Theme.callout).fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
            if let dismiss {
                Button {
                    dismiss()
                } label: {
                    Image(systemName: "xmark").font(Theme.font(10))
                }
                .buttonStyle(ControlFeedbackStyle(pressScale: 0.9))
                .accessibilityLabel(L10n.text("apple.sshlibraryview.dismiss.48845bff"))
            }
        }
        .padding(Theme.Space.s)
        .background(
            (kind == .danger ? Theme.danger : Theme.accent).opacity(0.08),
            in: RoundedRectangle(cornerRadius: 8)
        )
    }
}
