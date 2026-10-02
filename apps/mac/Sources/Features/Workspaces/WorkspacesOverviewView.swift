// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
//
// Source-available for review, NOT open source. See LICENSE: no rights to
// redistribute, publish, or ship a build are granted. Read it, study it, run
// your own build of it.
// "tokenstat" is a trademark of pueev OU. See TRADEMARK.md.

#if os(macOS)
import SwiftUI

/// Every registered folder on every machine, as cards.
///
/// The first row under the Workspaces heading, where a growing folder list
/// stays findable. One card carries what a scan looks for: folder, machine,
/// branch, dirty files, running sessions. A card opens the folder in the
/// existing workbench; nothing about the workbench changes.
///
/// Only drawn facts. A machine that is asleep keeps its last known folders
/// with quiet badges, and a missing badge means the host did not answer, not
/// zero. See `docs/plan-remote-expansion-1.0.md` workstream F.
struct WorkspacesOverviewView: View {
    var folders: [WorkspaceFolder]
    var summaries: [String: WorkspaceSummary]
    /// Live local sessions per folder id. Remote counts ride the summaries.
    var sessionsIn: (String) -> Int
    var onOpenFolder: (String) -> Void
    var onAdd: () -> Void

    /// Which machine's folders are showing. Nil is all of them.
    @State private var scope: String?
    @State private var search = ""
    @State private var alphabetical = false
    @AppStorage("workspaces.gridLayout") private var gridLayout = false

    private struct MachineScope: Hashable {
        var id: String?
        var label: String
    }

    private var scopes: [MachineScope] {
        var scopes = [MachineScope(id: nil, label: L10n.text("apple.workspacesoverviewview.all.a52ace42"))]
        if folders.contains(where: { !$0.isRemote }) {
            scopes.append(MachineScope(id: "local", label: L10n.text("apple.workspacesoverviewview.this_mac.79a4aefc")))
        }
        let remote = Dictionary(grouping: folders.filter(\.isRemote), by: \.machineID)
        for key in remote.keys.sorted(by: { ($0 ?? "") < ($1 ?? "") }) {
            let label = remote[key]?.first?.machineLabel?.trimmingCharacters(in: .whitespacesAndNewlines)
            scopes.append(MachineScope(
                id: key ?? "remote",
                label: (label?.isEmpty == false) ? label! : L10n.text("apple.workspacesoverviewview.remote_machine.d9dd1af3")
            ))
        }
        return scopes
    }

    private var shown: [WorkspaceFolder] {
        let query = search.trimmingCharacters(in: .whitespacesAndNewlines)
        let result = folders.filter { folder in
            let matchesScope = scope == nil || (scope == "local" ? !folder.isRemote : folder.isRemote && (folder.machineID ?? "remote") == scope)
            return matchesScope && (query.isEmpty || folder.name.localizedCaseInsensitiveContains(query)
                || folder.path.localizedCaseInsensitiveContains(query)
                || (folder.machineLabel?.localizedCaseInsensitiveContains(query) ?? false))
        }
        return alphabetical ? result.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending } : result
    }

    var body: some View {
        VStack(spacing: 0) {
        DetailChromeBar {
            EmptyView()
        }
        // One row: find a folder, pick a machine, order, add. The summary
        // tiles that stood here counted what the grid below already shows.
        HStack(spacing: Theme.Space.s) {
            SearchField(text: $search, prompt: L10n.text("apple.workspacesoverviewview.search_projects.9e079c7d"))
                .frame(maxWidth: 300)
            if scopes.count > 2 {
                Picker(L10n.text("apple.workspacesoverviewview.machine.8f1cc42d"), selection: $scope) {
                    ForEach(scopes, id: \.id) { scope in
                        Text(scope.label).tag(scope.id as String?)
                    }
                }
                .pickerStyle(.menu)
                .labelsHidden()
                .fixedSize()
            }
            Picker(L10n.text("apple.workspacesoverviewview.sort.bec69036"), selection: $alphabetical) {
                Text(L10n.text("apple.workspacesoverviewview.your_order.f159e18f")).tag(false)
                Text(L10n.text("apple.workspacesoverviewview.name_a_z.7ed96629")).tag(true)
            }
            .pickerStyle(.menu)
            .labelsHidden()
            .fixedSize()
            Spacer(minLength: Theme.Space.s)
            ToolbarIconButton(systemImage: gridLayout ? "list.bullet" : "square.grid.2x2",
                help: gridLayout ? L10n.text("apple.workspacesoverviewview.show_workspaces_as_a_list.deeb9b94") : L10n.text("apple.workspacesoverviewview.show_workspaces_as_cards.45515189")) { gridLayout.toggle() }
            Button(L10n.text("common.add_project"), .create) { onAdd() }
                .buttonStyle(AccentButtonStyle(small: true))
        }
        .padding(.horizontal, Theme.Space.m)
        .padding(.vertical, Theme.Space.s)
        ThemeRule()
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.Space.m) {
                if folders.isEmpty {
                    emptyState
                } else if shown.isEmpty {
                    ContentUnavailableView.search(text: search)
                } else if !gridLayout {
                    LazyVStack(spacing: 0) {
                        ForEach(shown) { folder in
                            folderRow(folder)
                            ThemeRule()
                        }
                    }
                } else {
                    LazyVGrid(
                        columns: [GridItem(.adaptive(minimum: 300), spacing: Theme.Space.m)],
                        spacing: Theme.Space.m
                    ) {
                        ForEach(shown) { folder in
                            folderCard(folder)
                        }
                    }
                }
            }
            .padding(Theme.Space.m)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        }
        .background(Theme.background)
        .onChange(of: folders.map(\.id)) { _, _ in
            // The machine a filter named can leave while the filter stays.
            // Fall back to all rather than an empty grid.
            if let scope, !scopes.contains(where: { $0.id == scope }) {
                self.scope = nil
            }
        }
    }

    private var summaryLine: String {
        let remote = folders.filter(\.isRemote).count
        switch (folders.count, remote) {
        case (0, _): return L10n.text("apple.workspacesoverviewview.nothing_registered_yet.84c3bf04")
        case let (all, 0): return L10n.text("apple.workspacesoverviewview.0_on_this_mac.bb17ca22", "\(all)")
        case let (all, _) where all == remote: return L10n.text("apple.workspacesoverviewview.0_on_remote_machines.a32076a4", "\(all)")
        case let (all, r): return L10n.text("apple.workspacesoverviewview.0_here_1_remote.fb100df4", "\(all - r)", "\(r)")
        }
    }

    private var emptyState: some View {
        FirstProjectPrompt(onAdd: onAdd)
            .frame(maxWidth: .infinity)
    }

    private func folderRow(_ folder: WorkspaceFolder) -> some View {
        Button { onOpenFolder(folder.id) } label: {
            HStack(spacing: Theme.Space.m) {
                Image(systemName: "folder")
                    .font(Theme.font(20)).foregroundStyle(Theme.accent)
                VStack(alignment: .leading, spacing: 4) {
                    Text(folder.name).font(Theme.callout.weight(.semibold)).lineLimit(1)
                    Text("\(machineLine(for: folder) ?? "") · \(folder.path)")
                        .font(Theme.caption).foregroundStyle(.secondary)
                        .lineLimit(1).truncationMode(.middle)
                    if !folder.exists {
                        Text(L10n.text("apple.workspacesoverviewview.folder_missing.f06c68a6")).font(Theme.caption).foregroundStyle(Theme.warning)
                    } else if let activity = activityLine(for: folder) {
                        Text(activity).font(Theme.caption).foregroundStyle(.secondary).lineLimit(1)
                    }
                }
                Spacer(minLength: Theme.Space.s)
                if let summary = summaries[folder.id] {
                    Text((summary.tasks == 1 ? L10n.text("apple.workspacesoverviewview.0_task_1.d478181b.one", "\(summary.tasks)") : L10n.text("apple.workspacesoverviewview.0_task_1.d478181b.other", "\(summary.tasks)")))
                        .font(Theme.caption).foregroundStyle(.secondary).fixedSize()
                }
                Image(systemName: "chevron.right")
                    .font(Theme.font(11, weight: .medium)).foregroundStyle(.tertiary)
            }
            .padding(Theme.Space.m)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .help(folder.path)
    }

    private func folderCard(_ folder: WorkspaceFolder) -> some View {
        Button {
            onOpenFolder(folder.id)
        } label: {
            Card(
                title: folder.name,
                subtitle: machineLine(for: folder),
                mark: "mark_archive",
                fillsHeight: true
            ) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(folder.path)
                        .font(Theme.caption)
                        .foregroundStyle(.tertiary)
                        .lineLimit(1).truncationMode(.middle)
                        .help(folder.path)
                        .padding(.bottom, Theme.Space.s)
                    if !folder.exists {
                        Text(L10n.text("apple.workspacesoverviewview.folder_missing.f06c68a6"))
                            .font(Theme.callout.weight(.medium))
                            .foregroundStyle(Theme.warning)
                    } else if let gitLine = gitLine(for: folder) {
                        HStack(spacing: 5) {
                            // The same glyph the sidebar rows use, for the
                            // same reason: a bare branch reads as a count.
                            if hasBranch(folder) {
                                Image(systemName: "arrow.triangle.branch")
                                    .font(Theme.mono(11, weight: .medium))
                            }
                            Text(gitLine)
                                .lineLimit(1)
                        }
                        .font(Theme.mono(12))
                        .foregroundStyle(.secondary)
                    }
                    if let activity = activityLine(for: folder) {
                        Text(activity)
                            .font(Theme.callout)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    if let summary = summaries[folder.id] {
                        HStack(spacing: Theme.Space.m) {
                            Label(L10n.text("apple.workspacesoverviewview.0_tasks.5076ea6e", "\(summary.tasks)"), systemImage: "checklist")
                            if let notes = summary.notes {
                                Label(L10n.text("apple.workspacesoverviewview.0_notes.8da860e0", "\(notes)"), systemImage: "note.text")
                            }
                        }
                        .font(Theme.caption).foregroundStyle(.secondary)
                        .padding(.top, Theme.Space.s)
                    }
                    ThemeRule().padding(.vertical, Theme.Space.s)
                    HStack {
                        if let changed = summaries[folder.id]?.changed {
                            Text(changed == 0 ? L10n.text("apple.workspacesoverviewview.no_pending_changes.069d0076") : L10n.text("apple.workspacesoverviewview.0_changed_files.dd8411f2", "\(changed)"))
                                .foregroundStyle(changed == 0 ? Theme.accent : Theme.secondary)
                        }
                        Spacer(minLength: 0)
                        Label(L10n.text("apple.workspacesoverviewview.open_workspace.b3e34b18"), systemImage: "arrow.up.right")
                            .foregroundStyle(Theme.accent)
                    }.font(Theme.caption.weight(.medium))
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(folder.name), \(machineLine(for: folder) ?? L10n.text("apple.workspacesoverviewview.folder.034a0062"))")
    }

    private func machineLine(for folder: WorkspaceFolder) -> String? {
        if folder.isRemote {
            let label = folder.machineLabel?.trimmingCharacters(in: .whitespacesAndNewlines)
            return (label?.isEmpty == false) ? label : L10n.text("apple.workspacesoverviewview.remote_machine.d9dd1af3")
        }
        return L10n.text("apple.workspacesoverviewview.this_mac.79a4aefc")
    }

    private func hasBranch(_ folder: WorkspaceFolder) -> Bool {
        folder.git?.isRepo == true && folder.git?.branch?.isEmpty == false
    }

    private func gitLine(for folder: WorkspaceFolder) -> String? {
        guard let git = folder.git, git.isRepo else { return nil }
        var parts: [String] = []
        if let branch = git.branch, !branch.isEmpty { parts.append(branch) }
        if git.ahead > 0 { parts.append("⇡\(git.ahead)") }
        if git.behind > 0 { parts.append("⇣\(git.behind)") }
        if let stat = folder.diffStat { parts.append(stat) }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    private func activityLine(for folder: WorkspaceFolder) -> String? {
        let sessions = folder.isRemote
            ? (summaries[folder.id]?.sessions ?? 0)
            : sessionsIn(folder.id)
        let chats = summaries[folder.id]?.chats
        var parts: [String] = []
        if sessions > 0 {
            parts.append((sessions == 1 ? L10n.text("apple.workspacesoverviewview.0_session_1.aa4d5aa6.one", "\(sessions)") : L10n.text("apple.workspacesoverviewview.0_session_1.aa4d5aa6.other", "\(sessions)")))
        }
        if let chats, chats > 0 {
            parts.append((chats == 1 ? L10n.text("apple.workspacesoverviewview.0_chat_1.2838f969.one", "\(chats)") : L10n.text("apple.workspacesoverviewview.0_chat_1.2838f969.other", "\(chats)")))
        }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }
}

/// The inspector column while the overview is showing.
///
/// The column exists here, so it says what it is waiting for rather than
/// standing blank: pick a card and this becomes that folder's inspector.
struct WorkspacesOverviewPlaceholder: View {
    var onClose: () -> Void
    var body: some View {
        VStack(spacing: 0) {
            InspectorChromeBar(onClose: onClose) {
                InspectorTitle(title: L10n.text("apple.workspacesoverviewview.project.98595978"), symbol: "folder")
                Spacer(minLength: 0)
            }
            InspectorEmptyState(mark: "mark_archive", title: L10n.text("apple.workspacesoverviewview.pick_a_folder.2226bfe1"), subtitle: L10n.text("apple.workspacesoverviewview.open_a_workspace_to_see_its_details_and_to.63f8fdb0"))
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Theme.background)
    }
}

#endif
