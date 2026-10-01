// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
//
// Source-available for review, NOT open source. See LICENSE: no rights to
// redistribute, publish, or ship a build are granted. Read it, study it, run
// your own build of it.
// "tokenstat" is a trademark of pueev OU. See TRADEMARK.md.

// Registering a folder means `NSOpenPanel`, so the whole sheet is macOS, the
// same way `WorkspacesModel.addFolder` behind it already is. A client has no
// folders of its own to add.
import SwiftUI
#if os(macOS)
import AppKit

/// The onboarding sheet behind "Add project…".
///
/// The decision is which folder. Everything else is two facts about that
/// choice: agents work there, and adding it does not upload it. The folder
/// panel still does the picking.
struct AddWorkspaceSheet: View {
    @Bindable var model: WorkspacesModel
    /// Account machines, so the remote flow can tell computers from phones.
    /// Empty when unknown; the sheet then lists every peer as before.
    var machines: [Machine] = []
    @Environment(\.dismiss) private var dismiss
    @State private var picking = false
    @State private var remote = false

    var body: some View {
        if remote {
            RemoteWorkspaceSheet(model: model, machines: machines) {
                remote = false
            }
        } else {
            localSheet
        }
    }

    private var localSheet: some View {
        ThemedSheet(
            title: L10n.text("apple.addworkspacesheet.add_a_project.69c7be56"),
            subtitle: L10n.text("apple.addworkspacesheet.keep_chats_terminals_notes_and_tasks_toget.55a5f978"),
            icon: .create,
            onClose: { dismiss() }
        ) {
            VStack(alignment: .leading, spacing: Theme.Space.xl) {
                Text(L10n.text("apple.addworkspacesheet.choose_an_existing_folder_on_this_mac_or_o.4db7412d"))
                    .font(Theme.body)
                    .foregroundStyle(.primary)
                    .fixedSize(horizontal: false, vertical: true)

                VStack(alignment: .leading, spacing: Theme.Space.l) {
                    ModalInfoRow(
                        icon: .source,
                        title: L10n.text("apple.addworkspacesheet.one_home_for_your_work.0a838a44"),
                        text: L10n.text("apple.addworkspacesheet.new_chats_and_terminal_sessions_use_this_f.0398eac8")
                    )
                    ModalInfoRow(
                        icon: .security,
                        title: L10n.text("apple.addworkspacesheet.nothing_is_uploaded.3b1a51ef"),
                        text: L10n.text("apple.addworkspacesheet.adding_a_project_does_not_send_the_folder.7c3c576c")
                    )
                }
            }
        } actions: {
            Button(L10n.text("apple.addworkspacesheet.not_now.a0e63d7c"), .dismiss) { dismiss() }
                .buttonStyle(SecondaryButtonStyle())
                .keyboardShortcut(.cancelAction)
            Button(L10n.text("apple.addworkspacesheet.on_another_machine.6f3387cc"), .device) { remote = true }
                .buttonStyle(SecondaryButtonStyle())
            Spacer()
            Button {
                picking = true
                Task {
                    await model.addFolder()
                    picking = false
                    dismiss()
                }
            } label: {
                ZStack {
                    ActionIcon.reveal.label(L10n.text("apple.addworkspacesheet.choose_folder.6e8eb2b0"))
                        .opacity(picking ? 0 : 1)
                    if picking {
                        ProgressView()
                            .controlSize(.small)
                            .tint(Theme.accent)
                    }
                }
            }
            .buttonStyle(AccentButtonStyle())
            .disabled(picking)
            .keyboardShortcut(.defaultAction)
        }
        .modalFrame(width: 540, height: 440)
    }
}
#endif

/// Separate folders let parallel tasks use different branches without switching
/// the files under an existing terminal or chat.
struct ProjectWorktreeSheet: View {
    let folder: WorkspaceFolder
    let onCreated: (WorkspaceFolder) -> Void
    @Environment(\.dismiss) private var dismiss
    @AppStorage("projects.worktree.namespace") private var namespace = "work"
    @State private var name = ""
    @State private var parent = ""
    @State private var base = "HEAD"
    @State private var working = false
    @State private var error: String?
    @State private var existing: [ProjectWorktree] = []
    @State private var showingFolders = false
    @State private var pickingParent = false

    var body: some View {
        ThemedSheet(title: L10n.text("apple.addworkspacesheet.worktrees.aec2f93d"), subtitle: L10n.text("apple.addworkspacesheet.separate_working_folders_for_0.92b95d37", "\(folder.name)"),
                    icon: .source, onClose: { if !working { dismiss() } }) {
            ScrollView {
                VStack(alignment: .leading, spacing: Theme.Space.m) {
                    Text(L10n.text("apple.addworkspacesheet.work_on_another_branch_without_interruptin.b8b9fb64"))
                        .font(Theme.callout).foregroundStyle(.secondary)
                    Picker(L10n.text("apple.addworkspacesheet.worktree_view.47529948"), selection: $showingFolders) {
                        Text(L10n.text("apple.addworkspacesheet.new_worktree.4f210afe")).tag(false)
                        Text(L10n.text("apple.addworkspacesheet.working_folders_0.b9b73029", "\(existing.count)")).tag(true)
                    }.pickerStyle(.segmented).labelsHidden()
                    if showingFolders {
                        ForEach(existing) { tree in
                            VStack(alignment: .leading, spacing: 3) {
                                Text(tree.branch ?? L10n.text("apple.addworkspacesheet.detached_commit.05f9a89e")).font(Theme.callout)
                                Text(tree.path).font(Theme.caption).foregroundStyle(.secondary).textSelection(.enabled)
                                if tree.locked { Text(L10n.text("apple.addworkspacesheet.locked.a424e33d")).font(Theme.caption).foregroundStyle(Theme.warning) }
                                if tree.prunable { Text(L10n.text("apple.addworkspacesheet.folder_no_longer_available.c06a8a39")).font(Theme.caption).foregroundStyle(.secondary) }
                                if !tree.bare && !tree.prunable {
                                    Button(L10n.text("apple.addworkspacesheet.open_project.5e5eba7f"), .reveal) { openExisting(tree) }
                                        .buttonStyle(SecondaryButtonStyle(small: true))
                                }
                            }.padding(.vertical, Theme.Space.xs)
                        }
                    } else {
                    Text(L10n.text("apple.addworkspacesheet.new_worktree.4f210afe")).font(Theme.headline)
                    VStack(alignment: .leading, spacing: Theme.Space.xs) {
                        Text(L10n.text("apple.addworkspacesheet.name.dcd1d522")).font(Theme.caption).foregroundStyle(.secondary)
                        TextField(L10n.text("apple.addworkspacesheet.for_example_improved_search.ae407d65"), text: $name).textFieldStyle(.themed)
                    }
                    VStack(alignment: .leading, spacing: Theme.Space.xs) {
                        Text(L10n.text("apple.addworkspacesheet.branch_prefix.502ac088")).font(Theme.caption).foregroundStyle(.secondary)
                        TextField(L10n.text("apple.addworkspacesheet.optional.59be7133"), text: $namespace).textFieldStyle(.themed)
                    }
                    VStack(alignment: .leading, spacing: Theme.Space.xs) {
                        Text(L10n.text("apple.addworkspacesheet.start_from_branch_or_commit.1ab72550")).font(Theme.caption).foregroundStyle(.secondary)
                        TextField(L10n.text("apple.addworkspacesheet.head.b5180223"), text: $base).textFieldStyle(.themed)
                    }
                    VStack(alignment: .leading, spacing: Theme.Space.xs) {
                        Text(L10n.text("apple.addworkspacesheet.parent_folder.158f5a01")).font(Theme.caption).foregroundStyle(.secondary)
                        TextField(L10n.text("apple.addworkspacesheet.absolute_path.977f8f03"), text: $parent).textFieldStyle(.themed)
                    }
                    if folder.isRemote {
                        Button(L10n.text("apple.addworkspacesheet.choose_parent_folder.80d064c3"), .reveal) { pickingParent = true }
                            .buttonStyle(SecondaryButtonStyle(small: true))
                    }
                    #if os(macOS)
                    if !folder.isRemote {
                        Button(L10n.text("apple.addworkspacesheet.choose_parent_folder.80d064c3"), .reveal) {
                            let picker = NSOpenPanel()
                            picker.canChooseDirectories = true
                            picker.canChooseFiles = false
                            picker.allowsMultipleSelection = false
                            picker.begin { response in
                                if response == .OK, let url = picker.url { parent = url.path }
                            }
                        }.buttonStyle(SecondaryButtonStyle(small: true))
                    }
                    #endif
                    if !name.isEmpty {
                        Text(L10n.text("apple.addworkspacesheet.branch_0.1262f157", "\(namespace.isEmpty ? name : namespace + "/" + name)"))
                            .font(Theme.caption).foregroundStyle(.secondary)
                        Text(L10n.text("apple.addworkspacesheet.folder_0_1_2.28953d93", "\(parent)", "\(parent.hasSuffix("/") || parent.hasSuffix("\\") ? "" : parent.contains("\\") ? "\\" : "/")", "\(name)")).font(Theme.caption).foregroundStyle(.secondary)
                    }
                    }
                    if let error { Text(error).font(Theme.callout).foregroundStyle(Theme.warning).textSelection(.enabled) }
                }.disabled(working)
            }
        } actions: {
            Button(L10n.text("common.cancel"), .dismiss) { dismiss() }.buttonStyle(SecondaryButtonStyle()).disabled(working)
            Spacer()
            if !showingFolders {
            Button(working ? L10n.text("apple.addworkspacesheet.creating.c79ed949") : L10n.text("apple.addworkspacesheet.create_worktree.fdedbce2"), .create) {
                working = true
                error = nil
                let scope = WorkSessionContext.shared.scope
                Task {
                    do {
                        let created = try await Bridge.createWorktree(id: folder.id, parent: parent,
                            folderName: name, namespace: namespace, branch: name, from: base)
                        guard !Task.isCancelled, scope == WorkSessionContext.shared.scope else { return }
                        working = false
                        onCreated(created)
                    } catch {
                        guard !Task.isCancelled, scope == WorkSessionContext.shared.scope else { return }
                        self.error = error.localizedDescription
                        working = false
                    }
                }
            }
            .buttonStyle(AccentButtonStyle())
            .disabled(working || name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || parent.isEmpty || base.isEmpty)
            }
        }
        .modalFrame(width: 580, height: 610)
        .interactiveDismissDisabled(working)
        .sheet(isPresented: $pickingParent) {
            if let peer = folder.machineID {
                ProjectParentPicker(peer: peer, hostName: folder.machineLabel ?? "Computer") { path in
                    parent = path
                    pickingParent = false
                }
            }
        }
        .task {
            if let separator = folder.path.lastIndex(where: { $0 == "/" || $0 == "\\" }) {
                parent = String(folder.path[...separator])
            }
            do { existing = try await Bridge.worktrees(id: folder.id) }
            catch { self.error = error.localizedDescription }
        }
    }

    private func openExisting(_ tree: ProjectWorktree) {
        working = true
        error = nil
        let scope = WorkSessionContext.shared.scope
        Task {
            do {
                let project: WorkspaceFolder
                if let peer = folder.machineID {
                    project = try await Bridge.addWorkspace(peer: peer, path: tree.path)
                } else {
                    project = try await Bridge.addWorkspace(path: tree.path)
                }
                guard !Task.isCancelled, scope == WorkSessionContext.shared.scope else { return }
                working = false
                onCreated(project)
            } catch {
                guard !Task.isCancelled, scope == WorkSessionContext.shared.scope else { return }
                self.error = error.localizedDescription
                working = false
            }
        }
    }

}

/// A path-only picker: choosing a destination never registers its parent as a project.
private struct ProjectParentPicker: View {
    let peer: String
    let hostName: String
    let onSelect: (String) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var path: String?
    @State private var listing: RemoteListing?
    @State private var error: String?
    @State private var loading = true
    @State private var retry = 0

    var body: some View {
        ThemedSheet(title: L10n.text("apple.addworkspacesheet.choose_parent_folder.c1b4bfea"), subtitle: hostName, icon: .reveal, onClose: { dismiss() }) {
            VStack(alignment: .leading, spacing: Theme.Space.m) {
                if let listing {
                    HStack {
                        if let parent = listing.parent {
                            Button(L10n.text("apple.addworkspacesheet.up.55490a4b"), .back) { path = parent }.buttonStyle(SecondaryButtonStyle(small: true))
                        }
                        Text(listing.path).font(Theme.caption).lineLimit(2).truncationMode(.middle)
                    }
                }
                if loading { ProgressView(L10n.text("apple.addworkspacesheet.reading_folders.66f40f96")) }
                if let error {
                    Text(error).foregroundStyle(Theme.warning)
                    Button(L10n.text("apple.addworkspacesheet.home_folder.6772da55"), .reveal) { path = nil; retry += 1 }.buttonStyle(SecondaryButtonStyle(small: true))
                }
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: Theme.Space.s) {
                        ForEach((listing?.entries ?? []).filter { $0.isDirectory && !$0.hidden }) { entry in
                            Button {
                                if let next = entry.path { path = next }
                            } label: {
                                HStack {
                                    Image(systemName: "folder")
                                    Text(entry.name).lineLimit(1)
                                    Spacer()
                                    Image(systemName: "chevron.right")
                                }.padding(Theme.Space.s).contentShape(.rect)
                            }.buttonStyle(.plain).disabled(loading)
                        }
                    }
                }
            }
        } actions: {
            Button(L10n.text("common.cancel"), .dismiss) { dismiss() }.buttonStyle(SecondaryButtonStyle())
            Spacer()
            Button(L10n.text("apple.addworkspacesheet.use_this_folder.30cbaeca"), .approve) { if let listing { onSelect(listing.path) } }
                .buttonStyle(AccentButtonStyle()).disabled(loading || error != nil || listing == nil)
        }
        .modalFrame(width: 540, height: 560)
        .task(id: [path ?? "", String(retry)]) {
            loading = true
            error = nil
            do {
                let answer = try await Bridge.browse(peer: peer, path: path)
                guard !Task.isCancelled else { return }
                listing = answer
            } catch {
                guard !Task.isCancelled else { return }
                self.error = error.localizedDescription
            }
            loading = false
        }
    }
}
