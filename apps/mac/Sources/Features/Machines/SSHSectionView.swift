// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
//
// Source-available for review, NOT open source. See LICENSE: no rights to
// redistribute, publish, or ship a build are granted. Read it, study it, run
// your own build of it.
// "tokenstat" is a trademark of pueev OU. See TRADEMARK.md.

import SwiftUI

#if os(macOS)
/// One SSH section in the content column.
///
/// The list only. What is being edited is the inspector's job, and which
/// section is in front is the sidebar's, so this view has the whole width for
/// the thing it is actually for: finding a server in a list of forty.
///
/// Four sections share one view because they are one screen with a different
/// list in it. Splitting them would be four copies of the same header, the same
/// search field, the same empty state and the same add button.
struct SSHSectionView: View {
    @Bindable var model: SSHLibraryModel
    let section: SSHSection
    /// The account tier, unfiltered. What may write the vault is decided by
    /// `SSHLibraryModel.paidTier(for:)`, in one place.
    var vaultTier: String?
    /// Open a folder in the sidebar's own selection, so clicking a folder in
    /// the list and clicking it in the sidebar mean the same thing.
    var onOpenFolder: (String) -> Void

    @State private var expanded: Set<String> = []
    private var vault: SSHVaultModel { model.vault }
    @State private var showingVault = false

    private var paidVaultTier: String? { SSHLibraryModel.paidTier(for: vaultTier) }
    private var signedInUnpaid: Bool { vaultTier != nil && paidVaultTier == nil }

    var body: some View {
        VStack(spacing: 0) {
            DetailChromeBar {
                addMenu
            }
            // Full width, like the search box on Automations. Capped at 420
            // with a spacer after it, this was the one search field in the app
            // that stopped halfway across its column and left a strip of empty
            // background beside itself.
            SearchField(text: $model.search, prompt: L10n.text("apple.sshsectionview.search_0.09ee1648", "\(section.label.lowercased())"))
                .padding(.horizontal, Theme.Space.m)
                .padding(.bottom, Theme.Space.s)
            // The vault belongs to hosts and keys, not to a fingerprint list,
            // and only when there is an account to hold one.
            if vaultTier != nil, section != .knownHosts {
                SSHVaultRow(vault: vault, canWrite: paidVaultTier != nil) { showingVault = true }
                    .padding(.horizontal, Theme.Space.m)
                    .padding(.bottom, Theme.Space.s)
                // A vault that could not take a copy is a sync problem, and it
                // belongs on the vault's own row. Across the top of the screen
                // it read as "your server was not saved", which was never true.
                if let vaultError = model.vaultError {
                    let friendly = FriendlyError.from(vaultError)
                    InlineBanner(text: L10n.text("apple.sshsectionview.saved_on_this_mac_but_not_synced_0.0300d4b9", "\(friendly.message)")) {
                        model.vaultError = nil
                    }
                    .padding(.horizontal, Theme.Space.m)
                    .padding(.bottom, Theme.Space.s)
                }
            }
            if let error = model.error {
                InlineBanner(text: FriendlyError.from(error).message, kind: .danger) { model.error = nil }
                    .padding(.horizontal, Theme.Space.m)
                    .padding(.bottom, Theme.Space.s)
            }
            content
        }
        .background(Theme.background)
        // The connect sheet is presented by the window, not by this screen.
        // Connecting starts from the tab strip and the sidebar as well, and
        // neither of those is on screen at the same time as this list.
        .sheet(isPresented: $showingVault) {
            SSHVaultScreen(vault: vault, tier: vaultTier ?? "", canWrite: paidVaultTier != nil, library: model)
        }
        .task(id: vaultTier) {
            guard vaultTier != nil else { return }
            await vault.refresh()
        }
        // Opening the screen loads it. The shell warms the same model at
        // launch so the sidebar has counts, but that pass waits on the archive
        // and can fail, and a library that is empty because nothing loaded
        // must not look like a library with nothing in it.
        .task(id: vaultTier) {
            await model.ensureLoaded(vaultTier: SSHLibraryModel.paidTier(for: vaultTier))
        }
    }

    // MARK: - Chrome

    @ViewBuilder
    private var addMenu: some View {
        if case .hosts = section {
            Menu {
                Button(L10n.text("apple.sshsectionview.add_host.7da3f6f4"), .create) { model.selection = .newHost(folder: section.folderID) }
                Button(L10n.text("apple.sshsectionview.add_folder.5bbfc5a6"), .create) { model.selection = .newFolder(parent: section.folderID) }
                ThemeRule()
                Button(L10n.text("apple.sshsectionview.import_from_ssh_config.1b6e8c38"), .download) { model.selection = .importConfig }
                Button(L10n.text("apple.sshsectionview.import_cloud_servers.34d6891a"), .download) { model.selection = .importCloud }
            } label: {
                Label(L10n.text("common.add"), systemImage: "plus")
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
        } else if section != .knownHosts {
            Button(section.addLabel, .create) { model.selection = addSelection }
                .buttonStyle(AccentButtonStyle(small: true))
        }
    }

    // MARK: - Lists

    @ViewBuilder
    private var content: some View {
        if signedInUnpaid, model.hosts.isEmpty, case .hosts = section {
            vaultUpgrade
            Spacer(minLength: 0)
        } else if isEmpty {
            EmptyState(symbol: section.symbol, title: emptyTitle, message: emptyMessage) {
                if section != .knownHosts {
                    Button(section.addLabel, .create) { model.selection = addSelection }
                        .buttonStyle(AccentButtonStyle())
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if searchedOut {
            EmptyState(
                symbol: "magnifyingglass",
                title: L10n.text("apple.sshsectionview.nothing_matched.ddc7629c"),
                message: L10n.text("apple.sshsectionview.no_0_match_1.4602a1ef", "\(section.label.lowercased())", "\(model.search)")
            ) {
                Button(L10n.text("apple.sshsectionview.clear_search.3b7ea517"), .dismiss) { model.search = "" }
                    .buttonStyle(SecondaryButtonStyle())
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if section == .snippets {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: Theme.Space.s) {
                    HStack {
                        Text(L10n.text("apple.sshsectionview.saved_commands.dadf29f0")).font(Theme.headline)
                        Spacer()
                        Text(L10n.text("apple.sshsectionview.0_snippets.bff110dd", "\(model.visibleSnippets.count)")).font(Theme.caption).foregroundStyle(.secondary)
                    }
                    .padding(.bottom, Theme.Space.s)
                    ForEach(model.visibleSnippets) { snippet in snippetRow(snippet) }
                }
                .padding(Theme.Space.l)
                .frame(maxWidth: ReadingRoom.listWidth, alignment: .leading)
                .frame(maxWidth: .infinity, alignment: .topLeading)
            }
        } else {
            list
        }
    }

    @ViewBuilder
    private var list: some View {
        List {
            switch section {
            case .hosts:
                hostsList
            case .keys:
                ForEach(model.visibleKeys) { key in keyRow(key) }
            case .snippets:
                ForEach(model.visibleSnippets) { snippet in snippetRow(snippet) }
            case .knownHosts:
                ForEach(model.knownHosts) { known in knownHostRow(known) }
            }
        }
        .listStyle(.inset)
        .scrollContentBackground(.hidden)
        .background(Theme.background)
    }

    @ViewBuilder
    private var hostsList: some View {
        // The handful somebody actually returns to, above the tree. Skipped
        // while searching: a search has already said what it wants.
        if !model.searching, !recentHosts.isEmpty {
            SwiftUI.Section(L10n.text("apple.sshsectionview.recent.690dbe9d")) {
                ForEach(recentHosts) { host in hostRow(host, depth: 0) }
            }
        }
        SwiftUI.Section(model.searching ? L10n.text("apple.sshsectionview.results.219c4a6c") : sectionTitle) {
            ForEach(rows) { row in
                switch row.kind {
                case let .folder(folder):
                    folderRow(folder, depth: row.depth)
                case let .host(host):
                    hostRow(host, depth: row.depth)
                }
            }
        }
    }

    /// The heading over the tree. A folder route says which folder, because the
    /// list is filtered to it and a heading saying "All servers" over one
    /// folder's worth of them is a heading that lies.
    private var sectionTitle: String {
        guard let folderID = section.folderID else { return L10n.text("apple.sshsectionview.all_servers.3205261a") }
        return model.folderName(folderID) ?? L10n.text("apple.sshsectionview.folder.74ccd433")
    }

    /// Favourites first, then most recently connected. Scoped to the folder
    /// when the route names one.
    private var recentHosts: [SSHHost] {
        model.recentHosts.filter { section.folderID == nil || $0.folderID == section.folderID }
    }

    // MARK: - The host tree

    private struct Row: Identifiable {
        enum Kind {
            case folder(SSHFolder)
            case host(SSHHost)
        }

        let id: String
        let kind: Kind
        let depth: Int
    }

    /// One row per visible line, with its depth.
    ///
    /// Flattened rather than nested disclosure groups: a view that contains
    /// itself cannot be typed, and indentation reads the same to a person.
    private var rows: [Row] {
        // A folder route is that folder's contents, flat. The sidebar already
        // says where you are, so repeating the parent chain here would be the
        // same information twice.
        if let folderID = section.folderID {
            var out: [Row] = []
            for folder in model.folders(in: folderID) {
                out.append(Row(id: "folder:\(folder.id)", kind: .folder(folder), depth: 0))
            }
            // Scoped to the folder even while searching. `hosts(in:)` drops
            // its folder argument once a query is running, which is right at
            // the root and wrong here: the sidebar still lights this folder,
            // so a list holding somebody else's servers is a list that lies.
            for host in model.hosts(in: folderID) where host.folderID == folderID {
                out.append(Row(id: "host:\(host.id)", kind: .host(host), depth: 0))
            }
            return out
        }

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

    // MARK: - Rows

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
            Text("\(model.hosts.filter { $0.folderID == folder.id }.count)")
                .font(Theme.caption).foregroundStyle(.secondary)
        }
        .padding(.leading, CGFloat(depth) * 14)
        .frame(minHeight: 48)
        .contentShape(.rect)
        .onTapGesture {
            if expanded.contains(folder.id) { expanded.remove(folder.id) } else { expanded.insert(folder.id) }
        }
        .contextMenu {
            Button(L10n.text("apple.sshsectionview.open_folder.6a908402")) { onOpenFolder(folder.id) }
            Button(L10n.text("apple.sshsectionview.rename_folder.7249f19c")) { model.selection = .folder(folder.id) }
            Button(L10n.text("apple.sshsectionview.add_server_here.a85b2f00")) { model.selection = .newHost(folder: folder.id) }
            Button(L10n.text("apple.sshsectionview.add_sub_folder.768dadd9")) { model.selection = .newFolder(parent: folder.id) }
            ThemeRule()
            Button(L10n.text("apple.sshsectionview.delete_folder.39f35f2d"), role: .destructive) {
                Task { await model.delete(folder: folder) }
            }
        }
    }

    private func hostRow(_ host: SSHHost, depth: Int) -> some View {
        SSHHostRow(
            host: host,
            folder: model.folderName(host.folderID),
            searching: model.searching,
            onConnect: { model.connectRequest = host }
        )
            .padding(.leading, CGFloat(depth) * 14)
            .listRowBackground(rowBackground(selected: model.selection == .host(host.id)))
            .contentShape(.rect)
            // Double click connects, single click selects. Declared in this
            // order because the two-tap gesture has to be offered first or the
            // single one swallows every click before it can count to two.
            .onTapGesture(count: 2) { model.connectRequest = host }
            .onTapGesture { model.selection = .host(host.id) }
        .accessibilityAction(named: L10n.text("apple.sshsectionview.open_details.67d16bb1")) { model.selection = .host(host.id) }
            .contextMenu {
                Button(L10n.text("common.connect")) { model.connectRequest = host }
                Button(host.favorite ? L10n.text("apple.sshsectionview.remove_from_favourites.a5bdeced") : L10n.text("apple.sshsectionview.add_to_favourites.9e619bff")) {
                    var updated = host
                    updated.favorite.toggle()
                    Task { _ = await model.save(host: updated) }
                }
                Button(L10n.text("common.edit")) { model.selection = .host(host.id) }
                ThemeRule()
                Button(L10n.text("common.delete"), role: .destructive) { Task { await model.delete(host: host) } }
            }
    }

    private func keyRow(_ key: SSHKeyRecord) -> some View {
        Label {
            VStack(alignment: .leading, spacing: 2) {
                Text(key.label)
                Text(key.fingerprint.isEmpty ? key.algorithm : key.fingerprint)
                    .font(Theme.mono(11)).foregroundStyle(.secondary).lineLimit(1)
                if SSHSecretStore.requiresBiometrics(key.secretRef) {
                    Text(L10n.text("apple.sshsectionview.touch_id_this_device_only_not_synced.221d3d91"))
                        .font(Theme.caption2).foregroundStyle(Theme.accent)
                }
            }
        } icon: {
            Image(systemName: key.hardwareBacked ? "key.radiowaves.forward" : "key.fill")
                .foregroundStyle(Theme.accent)
        }
        .frame(minHeight: 48)
        .listRowBackground(rowBackground(selected: model.selection == .key(key.id)))
        .contentShape(.rect)
        .onTapGesture { model.selection = .key(key.id) }
        .accessibilityAction(named: L10n.text("apple.sshsectionview.open_details.67d16bb1")) { model.selection = .key(key.id) }
        .contextMenu {
            Button(L10n.text("common.delete"), role: .destructive) { Task { await model.delete(key: key) } }
        }
    }

    private func snippetRow(_ snippet: SSHSnippet) -> some View {
        Button { model.selection = .snippet(snippet.id) } label: {
            HStack(alignment: .top, spacing: Theme.Space.m) {
                Image(systemName: "terminal")
                    .font(Theme.font(15))
                    .foregroundStyle(Theme.accent)
                    .frame(width: 32, height: 32)
                    .background(Theme.accentSoft, in: RoundedRectangle(cornerRadius: 8))
                VStack(alignment: .leading, spacing: Theme.Space.s) {
                    HStack {
                        Text(snippet.title).font(Theme.body.weight(.medium)).foregroundStyle(.primary)
                        Spacer(minLength: Theme.Space.s)
                        if snippet.runOnConnect {
                            Label(L10n.text("apple.sshsectionview.on_connect.e32909a7"), systemImage: "bolt")
                                .font(Theme.caption2).foregroundStyle(Theme.warning)
                        }
                    }
                    Text(snippet.command)
                        .font(Theme.mono(11)).foregroundStyle(.secondary).lineLimit(2)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    if !snippet.tags.isEmpty {
                        Text(snippet.tags.prefix(4).joined(separator: " · "))
                            .font(Theme.caption2).foregroundStyle(Theme.accent).lineLimit(1)
                    }
                }
                Image(systemName: "chevron.right").font(Theme.caption).foregroundStyle(.tertiary)
            }
            .padding(Theme.Space.m)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(model.selection == .snippet(snippet.id) ? Theme.rowSelected : Theme.panel,
                        in: RoundedRectangle(cornerRadius: Theme.cardRadius))
            .overlay(RoundedRectangle(cornerRadius: Theme.cardRadius)
                .strokeBorder(model.selection == .snippet(snippet.id) ? Theme.accent.opacity(0.5) : Theme.border))
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .accessibilityHint(L10n.text("apple.sshsectionview.open_this_saved_command_for_editing_does_n.e50141e1"))
        .contextMenu {
            Button(L10n.text("apple.sshsectionview.copy_command.9a01feec"), .copy) {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(snippet.command, forType: .string)
            }
            Button(L10n.text("common.delete"), role: .destructive) { Task { await model.delete(snippet: snippet) } }
        }
    }

    private func knownHostRow(_ known: SSHKnownHost) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(known.label)
            Text("\(known.hostname):\(known.port)")
                .font(Theme.caption).foregroundStyle(.secondary)
        }
        .frame(minHeight: 48)
        .listRowBackground(rowBackground(selected: model.selection == .knownHost(known.id)))
        .contentShape(.rect)
        .onTapGesture { model.selection = .knownHost(known.id) }
        .accessibilityAction(named: L10n.text("apple.sshsectionview.open_details.67d16bb1")) { model.selection = .knownHost(known.id) }
        .contextMenu {
            Button(L10n.text("apple.sshsectionview.forget.a6bd489d"), role: .destructive) {
                Task { await model.forgetKnownHost(known) }
            }
        }
    }

    /// Selection is the accent wash the sidebar uses, so a selected row means
    /// the same thing in both columns.
    @ViewBuilder
    private func rowBackground(selected: Bool) -> some View {
        if selected {
            Theme.rowSelected
        } else {
            Color.clear
        }
    }

    // MARK: - States

    private var addSelection: SSHLibraryRoute {
        switch section {
        case let .hosts(folder): .newHost(folder: folder)
        case .keys: .newKey
        case .snippets: .newSnippet
        // Trust is earned by connecting, not by typing a fingerprint in. The
        // add button is hidden for this section, and this is the unreachable
        // arm the compiler still wants an answer for.
        case .knownHosts: .knownHosts
        }
    }

    /// Whether this section has nothing in it at all.
    ///
    /// Counted from the unfiltered lists on purpose. `hosts(in:)` and
    /// `folders(in:)` narrow to the search, so asking them would tell somebody
    /// whose query matched nothing that they have never added a server, and
    /// offer to add their first one over the forty they already have.
    private var isEmpty: Bool {
        switch section {
        case let .hosts(folder):
            if let folder {
                return !model.hosts.contains { $0.folderID == folder }
                    && !model.folders.contains { $0.parentID == folder }
            }
            return model.hosts.isEmpty && model.folders.isEmpty
        case .keys: return model.keys.isEmpty
        case .snippets: return model.snippets.isEmpty
        case .knownHosts: return model.knownHosts.isEmpty
        }
    }

    /// The list has rows in it, but the search hid all of them.
    private var searchedOut: Bool {
        guard model.searching, !isEmpty else { return false }
        switch section {
        case .hosts: return rows.isEmpty && recentHosts.isEmpty
        case .keys: return model.visibleKeys.isEmpty
        case .snippets: return model.visibleSnippets.isEmpty
        case .knownHosts: return false
        }
    }

    private var emptyTitle: String {
        switch section {
        case .hosts: L10n.text("apple.sshsectionview.no_servers_yet.7846930c")
        case .keys: L10n.text("apple.sshsectionview.no_keys_yet.3e5039d1")
        case .snippets: L10n.text("apple.sshsectionview.no_snippets_yet.6e213185")
        case .knownHosts: L10n.text("apple.sshsectionview.no_trusted_servers_yet.c7540d35")
        }
    }

    private var emptyMessage: String {
        switch section {
        case .hosts: L10n.text("apple.sshsectionview.add_a_server_once_then_connect_without_ret.ceca4076")
        case .keys: L10n.text("apple.sshsectionview.generate_or_import_an_ssh_key_to_authentic.406e6d7d")
        case .snippets: L10n.text("apple.sshsectionview.save_commands_you_use_often_and_run_them_f.a621eb59")
        case .knownHosts: L10n.text("apple.sshsectionview.the_first_time_you_connect_to_a_server_you.379e18b6")
        }
    }

    private var vaultUpgrade: some View {
        EmptyState(
            symbol: "lock.shield",
            title: L10n.text("apple.sshsectionview.sync_ssh_between_your_devices.8bd160ae"),
            message: L10n.text("apple.sshsectionview.an_encrypted_vault_keeps_hosts_and_keys_on.75c5e63a"),
            mark: "mark_plan"
        ) {
            Link(L10n.text("apple.sshsectionview.see_plans.d9898933"), destination: URL(string: "https://tokenstat.ai/pricing")!)
                .buttonStyle(AccentButtonStyle())
        }
        .padding(Theme.Space.m)
    }
}
#endif
