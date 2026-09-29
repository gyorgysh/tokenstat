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
            title: "Add a project",
            subtitle: "Keep chats, terminals, notes and tasks together in one project.",
            icon: .create,
            onClose: { dismiss() }
        ) {
            VStack(alignment: .leading, spacing: Theme.Space.xl) {
                Text("Choose an existing folder on this Mac, or open a project on another computer.")
                    .font(Theme.body)
                    .foregroundStyle(.primary)
                    .fixedSize(horizontal: false, vertical: true)

                VStack(alignment: .leading, spacing: Theme.Space.l) {
                    ModalInfoRow(
                        icon: .source,
                        title: "One home for your work",
                        text: "New chats and terminal sessions use this folder. If it is a Git repository, changes and history appear automatically."
                    )
                    ModalInfoRow(
                        icon: .security,
                        title: "Nothing is uploaded",
                        text: "Adding a project does not send the folder anywhere. Only usage counters are eligible for sync."
                    )
                }
            }
        } actions: {
            Button("Not now", .dismiss) { dismiss() }
                .buttonStyle(SecondaryButtonStyle())
                .keyboardShortcut(.cancelAction)
            Button("On another machine…", .device) { remote = true }
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
                    ActionIcon.reveal.label("Choose folder…")
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
        ThemedSheet(title: "Worktrees", subtitle: "Separate working folders for \(folder.name)",
                    icon: .source, onClose: { if !working { dismiss() } }) {
            ScrollView {
                VStack(alignment: .leading, spacing: Theme.Space.m) {
                    Text("Work on another branch without interrupting the chats or terminals in this project.")
                        .font(Theme.callout).foregroundStyle(.secondary)
                    Picker("Worktree view", selection: $showingFolders) {
                        Text("New worktree").tag(false)
                        Text("Working folders (\(existing.count))").tag(true)
                    }.pickerStyle(.segmented).labelsHidden()
                    if showingFolders {
                        ForEach(existing) { tree in
                            VStack(alignment: .leading, spacing: 3) {
                                Text(tree.branch ?? "Detached commit").font(Theme.callout)
                                Text(tree.path).font(Theme.caption).foregroundStyle(.secondary).textSelection(.enabled)
                                if tree.locked { Text("Locked").font(Theme.caption).foregroundStyle(Theme.warning) }
                                if tree.prunable { Text("Folder no longer available").font(Theme.caption).foregroundStyle(.secondary) }
                                if !tree.bare && !tree.prunable {
                                    Button("Open project", .reveal) { openExisting(tree) }
                                        .buttonStyle(SecondaryButtonStyle(small: true))
                                }
                            }.padding(.vertical, Theme.Space.xs)
                        }
                    } else {
                    Text("New worktree").font(Theme.headline)
                    TextField("Name, for example improved-search", text: $name).textFieldStyle(.themed)
                    LabeledContent("Branch prefix") { TextField("Optional", text: $namespace).textFieldStyle(.themed) }
                    LabeledContent("Start from") { TextField("HEAD", text: $base).textFieldStyle(.themed) }
                    LabeledContent("Parent folder") { TextField("Absolute path", text: $parent).textFieldStyle(.themed) }
                    if folder.isRemote {
                        Button("Choose parent folder…", .reveal) { pickingParent = true }
                            .buttonStyle(SecondaryButtonStyle(small: true))
                    }
                    #if os(macOS)
                    if !folder.isRemote {
                        Button("Choose parent folder…", .reveal) {
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
                        Text("Branch: \(namespace.isEmpty ? name : namespace + "/" + name)")
                            .font(Theme.caption).foregroundStyle(.secondary)
                        Text("Folder: \(parent)\(parent.hasSuffix("/") || parent.hasSuffix("\\") ? "" : parent.contains("\\") ? "\\" : "/")\(name)").font(Theme.caption).foregroundStyle(.secondary)
                    }
                    }
                    if let error { Text(error).font(Theme.callout).foregroundStyle(Theme.warning).textSelection(.enabled) }
                }.disabled(working)
            }
        } actions: {
            Button("Cancel", .dismiss) { dismiss() }.buttonStyle(SecondaryButtonStyle()).disabled(working)
            Spacer()
            if !showingFolders {
            Button(working ? "Creating…" : "Create worktree", .create) {
                working = true
                error = nil
                Task {
                    do {
                        let created = try await Bridge.createWorktree(id: folder.id, parent: parent,
                            folderName: name, namespace: namespace, branch: name, from: base)
                        working = false
                        onCreated(created)
                    } catch { self.error = error.localizedDescription; working = false }
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
        Task {
            do {
                let project: WorkspaceFolder
                if let peer = folder.machineID {
                    project = try await Bridge.addWorkspace(peer: peer, path: tree.path)
                } else {
                    project = try await Bridge.addWorkspace(path: tree.path)
                }
                working = false
                onCreated(project)
            } catch { self.error = error.localizedDescription; working = false }
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
        ThemedSheet(title: "Choose parent folder", subtitle: hostName, icon: .reveal, onClose: { dismiss() }) {
            VStack(alignment: .leading, spacing: Theme.Space.m) {
                if let listing {
                    HStack {
                        if let parent = listing.parent {
                            Button("Up", .back) { path = parent }.buttonStyle(SecondaryButtonStyle(small: true))
                        }
                        Text(listing.path).font(Theme.caption).lineLimit(2).truncationMode(.middle)
                    }
                }
                if loading { ProgressView("Reading folders…") }
                if let error {
                    Text(error).foregroundStyle(Theme.warning)
                    Button("Home folder", .reveal) { path = nil; retry += 1 }.buttonStyle(SecondaryButtonStyle(small: true))
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
            Button("Cancel", .dismiss) { dismiss() }.buttonStyle(SecondaryButtonStyle())
            Spacer()
            Button("Use this folder", .approve) { if let listing { onSelect(listing.path) } }
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
