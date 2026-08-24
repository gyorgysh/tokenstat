// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
//
// Source-available for review, NOT open source. See LICENSE.

import SwiftUI

/// What the detail side of the library is showing.
///
/// A value rather than a pile of `@State` booleans, because the old screen had
/// one flag per sheet and no way to say "editing this host": adding was the
/// only thing it could express.
enum SSHLibraryRoute: Hashable {
    case host(String)
    case newHost(folder: String?)
    case key(String)
    case newKey
    case snippet(String)
    case newSnippet
    case folder(String)
    case newFolder(parent: String?)
    case knownHosts
    case importConfig
    case importCloud
}

/// The SSH library: hosts, keys and snippets, with folders and search.
///
/// One screen with a list and a detail side, rather than a segmented picker
/// over three lists and a fixed-size sheet per action. The sheets were the
/// problem: a snippet is a shell script and it was being edited in a box 380
/// points tall, and a host had nowhere to show what it was actually configured
/// to do. Sheets are kept for the two things that really are modal and
/// dangerous: recovery words, and confirming a deletion.
struct SSHLibraryView: View {
    var vaultTier: String?
    var onClose: (() -> Void)?

    enum Section: String, CaseIterable, Identifiable {
        case hosts = "Hosts"
        case keys = "Keys"
        case snippets = "Snippets"
        var id: String { rawValue }
    }

    #if !os(macOS)
    @Environment(ClientStore.self) private var store
    #endif
    @State private var model = SSHLibraryModel()
    @State private var section = Section.hosts
    @State private var route: SSHLibraryRoute?
    @State private var connecting: SSHHost?
    @State private var terminal: SSHLiveTerminal?
    @State private var vaultRecovery: String?
    @State private var vaultStatus: SSHVaultStatus?
    @State private var expanded: Set<String> = []

    private var paidVaultTier: String? {
        guard let tier = vaultTier?.lowercased(), ["supporter", "patron", "legend"].contains(tier) else { return nil }
        return tier
    }

    private var signedInUnpaid: Bool { vaultTier != nil && paidVaultTier == nil }

    var body: some View {
        content
            .task { await model.load(vaultTier: paidVaultTier) }
            .task { vaultStatus = try? await Bridge.sshVaultStatus() }
            .sheet(item: $connecting) { host in
                SSHConnectForm(host: host, model: model) { terminal = $0 }
            }
            #if os(macOS)
            .sheet(item: $terminal) { SSHLiveTerminalScreen(session: $0).frame(minWidth: 720, minHeight: 480) }
            #else
            .fullScreenCover(item: $terminal) { SSHLiveTerminalScreen(session: $0) }
            #endif
    }

    // MARK: - Platform shells

    #if os(macOS)
    private var content: some View {
        HStack(spacing: 0) {
            listSide
                .frame(width: 300)
            Divider()
            detailSide
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(Theme.background)
        .navigationTitle("SSH")
        .toolbar { toolbarContent }
    }

    @ViewBuilder
    private var detailSide: some View {
        switch route {
        case let .host(id):
            SSHHostEditor(model: model, hostID: id, folderID: nil, onDone: close).id(id)
        case let .newHost(folder):
            SSHHostEditor(model: model, hostID: nil, folderID: folder, onDone: close)
        case let .key(id):
            SSHKeyEditor(model: model, keyID: id, onDone: close).id(id)
        case .newKey:
            SSHKeyEditor(model: model, keyID: nil, onDone: close)
        case let .snippet(id):
            SSHSnippetEditor(model: model, snippetID: id, onDone: close).id(id)
        case .newSnippet:
            SSHSnippetEditor(model: model, snippetID: nil, onDone: close)
        case let .folder(id):
            SSHFolderEditor(model: model, folderID: id, parentID: nil, onDone: close).id(id)
        case let .newFolder(parent):
            SSHFolderEditor(model: model, folderID: nil, parentID: parent, onDone: close)
        case .knownHosts:
            SSHKnownHostsView(model: model)
        case .importConfig:
            SSHConfigImportView(model: model, onDone: close)
        case .importCloud:
            CloudImportForm(model: model, onDone: close)
        case nil:
            EmptyState(
                symbol: "sidebar.left",
                title: "Nothing selected",
                message: "Pick a server, a key or a snippet on the left, or add one."
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
    #else
    private var content: some View {
        listSide
            .navigationTitle("SSH")
            .toolbar { toolbarContent }
            // Pushed onto whichever stack this screen was opened from, rather
            // than onto one of its own: Devices already owns a stack, and a
            // second one inside it draws a second title bar.
            .navigationDestination(item: $route) { destination($0) }
    }

    @ViewBuilder
    private func destination(_ route: SSHLibraryRoute) -> some View {
        switch route {
        case let .host(id):
            SSHHostEditor(model: model, hostID: id, folderID: nil, onDone: close)
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
        case .knownHosts:
            SSHKnownHostsView(model: model)
        case .importConfig:
            SSHConfigImportView(model: model, onDone: close)
        case .importCloud:
            CloudImportForm(model: model, onDone: close)
        }
    }
    #endif

    // MARK: - The list side

    private var listSide: some View {
        VStack(spacing: 0) {
            header
            if let error = model.error {
                InlineBanner(text: error, kind: .danger) { model.error = nil }
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
        .background(Theme.sidebar)
    }

    private var header: some View {
        VStack(spacing: Theme.Space.s) {
            if let vaultTier {
                SSHVaultBanner(
                    tier: vaultTier,
                    canWrite: paidVaultTier != nil,
                    status: $vaultStatus,
                    recovery: $vaultRecovery
                )
            }
            Picker("SSH library", selection: $section) {
                ForEach(Section.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            SearchField(text: $model.search, prompt: "Search \(section.rawValue.lowercased())")
        }
        .padding(Theme.Space.m)
    }

    @ViewBuilder
    private var list: some View {
        List {
            switch section {
            case .hosts:
                if !model.searching, !model.recentHosts.isEmpty {
                    SwiftUI.Section("Recent") {
                        ForEach(model.recentHosts) { host in hostRow(host, depth: 0) }
                    }
                }
                SwiftUI.Section(model.searching ? "Results" : "All servers") {
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
        #if os(macOS)
        .listStyle(.sidebar)
        #else
        .listStyle(.insetGrouped)
        #endif
    }

    /// One row per visible line, with its depth.
    ///
    /// Flattened rather than nested `DisclosureGroup`s: a view that contains
    /// itself cannot be typed, and indentation reads the same to a person.
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
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.secondary)
                .frame(width: 12)
            Image(systemName: "folder")
                .foregroundStyle(SSHColor.color(folder.color))
            Text(folder.name)
            Spacer()
            Text("\(model.hosts(in: folder.id).count)")
                .font(.caption).foregroundStyle(.secondary)
        }
        .padding(.leading, CGFloat(depth) * 14)
        .frame(height: Theme.Control.rowHeight)
        .contentShape(.rect)
        .onTapGesture {
            if expanded.contains(folder.id) { expanded.remove(folder.id) } else { expanded.insert(folder.id) }
        }
        .contextMenu {
            Button("Rename folder") { open(.folder(folder.id)) }
            Button("Add server here") { open(.newHost(folder: folder.id)) }
            Button("Add sub-folder") { open(.newFolder(parent: folder.id)) }
            Button("Delete folder", role: .destructive) {
                Task { await model.delete(folder: folder) }
            }
        }
    }

    private func hostRow(_ host: SSHHost, depth: Int) -> some View {
        SSHHostRow(host: host, folder: model.folderName(host.folderID), searching: model.searching)
            .padding(.leading, CGFloat(depth) * 14)
            .contentShape(.rect)
            .onTapGesture { open(.host(host.id)) }
            .contextMenu {
                Button("Connect") { connecting = host }
                Button(host.favorite ? "Remove from favourites" : "Add to favourites") {
                    var updated = host
                    updated.favorite.toggle()
                    Task { _ = await model.save(host: updated) }
                }
                Button("Edit") { open(.host(host.id)) }
                Button("Delete", role: .destructive) { Task { await model.delete(host: host) } }
            }
            .swipeActions(edge: .trailing) {
                Button("Delete", role: .destructive) { Task { await model.delete(host: host) } }
            }
    }

    private func keyRow(_ key: SSHKeyRecord) -> some View {
        Label {
            VStack(alignment: .leading, spacing: 2) {
                Text(key.label)
                Text(key.fingerprint.isEmpty ? key.algorithm : key.fingerprint)
                    .font(Theme.mono(11)).foregroundStyle(.secondary).lineLimit(1)
            }
        } icon: {
            Image(systemName: key.hardwareBacked ? "key.radiowaves.forward" : "key.fill")
                .foregroundStyle(Theme.accent)
        }
        .frame(height: Theme.Control.rowHeight)
        .contentShape(.rect)
        .onTapGesture { open(.key(key.id)) }
        .swipeActions(edge: .trailing) {
            Button("Delete", role: .destructive) { Task { await model.delete(key: key) } }
        }
    }

    private func snippetRow(_ snippet: SSHSnippet) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(snippet.title)
            Text(snippet.command)
                .font(Theme.mono(11)).foregroundStyle(.secondary).lineLimit(1)
        }
        .frame(height: Theme.Control.rowHeight)
        .contentShape(.rect)
        .onTapGesture { open(.snippet(snippet.id)) }
        .swipeActions(edge: .trailing) {
            Button("Delete", role: .destructive) { Task { await model.delete(snippet: snippet) } }
        }
    }

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        if let onClose {
            ToolbarItem(placement: .cancellationAction) {
                InspectorCloseButton(action: onClose, help: "Close", label: "Close SSH library")
            }
        }
        ToolbarItem(placement: .primaryAction) {
            Menu {
                Button("Add \(section.rawValue.dropLast().lowercased())") { open(addRoute) }
                if section == .hosts {
                    Button("Add folder") { open(.newFolder(parent: nil)) }
                    Divider()
                    Button("Import from ssh config") { open(.importConfig) }
                    Button("Import cloud servers") { open(.importCloud) }
                    Button("Trusted servers") { open(.knownHosts) }
                }
            } label: {
                Label("Add", systemImage: "plus")
            }
        }
    }

    // MARK: - Plumbing

    /// Leave an editor: clear the detail pane on macOS, pop the push on iOS.
    /// One assignment does both, because both are driven by `route`.
    private func close() { route = nil }

    private func open(_ destination: SSHLibraryRoute) { route = destination }

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

    private var emptyTitle: String { "No \(section.rawValue.lowercased()) yet" }

    private var emptyMessage: String {
        switch section {
        case .hosts: "Add a server once, then connect without retyping its address and username."
        case .keys: "Generate or import an SSH key to authenticate without a password."
        case .snippets: "Save commands you use often and run them from a terminal."
        }
    }

    private var emptyActionTitle: String {
        switch section {
        case .hosts: "Add host"
        case .keys: "Add key"
        case .snippets: "Add snippet"
        }
    }

    @ViewBuilder
    private var vaultUpgrade: some View {
        #if os(macOS)
        EmptyState(
            symbol: "lock.shield",
            title: "Sync SSH between your devices",
            message: "An encrypted vault keeps hosts and keys on every computer and phone signed in to this account. Supporter and above."
        ) {
            Link("See plans", destination: URL(string: "https://tokenstat.ai/pricing")!)
                .buttonStyle(AccentButtonStyle())
        }
        .padding(Theme.Space.m)
        #else
        ClientEmptyState(
            kind: .needsAccount,
            title: "Sync SSH between your devices",
            message: "An encrypted vault keeps hosts and keys on every computer and phone signed in to this account. Supporter and above.",
            actionTitle: "See plans",
            actionIcon: .plans,
            action: { store.showPaywall = true },
            art: .vault
        )
        .padding(.horizontal, Theme.Space.m)
        #endif
    }
}

/// One server in the list.
///
/// Name in body weight, address in caption, folder colour as a leading bar, so
/// ten servers scan as a list rather than as ten paragraphs.
struct SSHHostRow: View {
    let host: SSHHost
    let folder: String?
    let searching: Bool

    var body: some View {
        HStack(spacing: Theme.Space.s) {
            RoundedRectangle(cornerRadius: 2)
                .fill(SSHColor.color(host.color))
                .frame(width: 3)
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: Theme.Space.xs) {
                    Text(host.label).lineLimit(1)
                    if host.favorite {
                        Image(systemName: "star.fill")
                            .font(.system(size: 9))
                            .foregroundStyle(Theme.warning)
                    }
                }
                HStack(spacing: Theme.Space.xs) {
                    Text(host.address)
                        .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    if searching, let folder {
                        Text(folder)
                            .font(.caption2)
                            .padding(.horizontal, 5).padding(.vertical, 1)
                            .background(Theme.rowHighlight, in: Capsule())
                            .foregroundStyle(.secondary)
                    }
                }
            }
            Spacer(minLength: 0)
        }
        .frame(height: Theme.Control.rowHeight)
    }
}

/// A search field that looks the same on both platforms.
///
/// `.searchable` puts the field somewhere different on each, and this screen
/// needs it above the list on both.
struct SearchField: View {
    @Binding var text: String
    let prompt: String

    var body: some View {
        HStack(spacing: Theme.Space.xs) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
            TextField(prompt, text: $text)
                .textFieldStyle(.plain)
            if !text.isEmpty {
                Button {
                    text = ""
                } label: {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Clear search")
            }
        }
        .padding(.horizontal, Theme.Space.s)
        .frame(height: Theme.Control.height)
        .background(Theme.panel, in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Theme.border))
    }
}

/// A message attached to the thing that produced it.
///
/// The old screen printed errors as loose red text between a picker and an
/// empty state, which reads as part of the layout rather than as a problem.
struct InlineBanner: View {
    enum Kind { case danger, info }
    let text: String
    var kind: Kind = .info
    var dismiss: (() -> Void)?

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: Theme.Space.s) {
            Image(systemName: kind == .danger ? "exclamationmark.triangle.fill" : "info.circle")
                .foregroundStyle(kind == .danger ? Theme.danger : Theme.accent)
            Text(text).font(.callout).fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
            if let dismiss {
                Button {
                    dismiss()
                } label: {
                    Image(systemName: "xmark").font(.system(size: 10))
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Dismiss")
            }
        }
        .padding(Theme.Space.s)
        .background(
            (kind == .danger ? Theme.danger : Theme.accent).opacity(0.08),
            in: RoundedRectangle(cornerRadius: 8)
        )
    }
}
