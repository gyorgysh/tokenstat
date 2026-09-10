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

    private struct MachineScope: Hashable {
        var id: String?
        var label: String
    }

    private var scopes: [MachineScope] {
        var scopes = [MachineScope(id: nil, label: "All")]
        if folders.contains(where: { !$0.isRemote }) {
            scopes.append(MachineScope(id: "local", label: "This Mac"))
        }
        let remote = Dictionary(grouping: folders.filter(\.isRemote), by: \.machineID)
        for key in remote.keys.sorted(by: { ($0 ?? "") < ($1 ?? "") }) {
            let label = remote[key]?.first?.machineLabel?.trimmingCharacters(in: .whitespacesAndNewlines)
            scopes.append(MachineScope(
                id: key ?? "remote",
                label: (label?.isEmpty == false) ? label! : "Remote machine"
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
            ToolbarIconButton(systemImage: "plus", help: "Add folder") { onAdd() }
        }
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.Space.m) {
                HStack(alignment: .center, spacing: Theme.Space.m) {
                    FeatureMark(name: "mark_archive", tint: Theme.accent, size: 28)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("All folders")
                            .font(Theme.font(24, weight: .semibold))
                        Text(summaryLine)
                            .font(Theme.callout)
                            .foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 0)
                    if scopes.count > 2 {
                        Picker("Machine", selection: $scope) {
                            ForEach(scopes, id: \.id) { scope in
                                Text(scope.label).tag(scope.id as String?)
                            }
                        }
                        .pickerStyle(.menu)
                        .fixedSize()
                    }
                    Button("Add folder", .create) { onAdd() }
                        .buttonStyle(AccentButtonStyle(small: true))
                }
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: Theme.Space.s), count: 3), spacing: Theme.Space.s) {
                    ActivitySummaryTile(title: "Workspaces", value: folders.count, symbol: "folder")
                    ActivitySummaryTile(title: "Local folders", value: folders.filter { !$0.isRemote }.count, symbol: "laptopcomputer")
                    ActivitySummaryTile(title: "Remote folders", value: folders.filter(\.isRemote).count, symbol: "network")
                }
                HStack(spacing: Theme.Space.s) {
                    HStack(spacing: Theme.Space.s) {
                        Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                        TextField("Search folders, paths, or machines", text: $search).textFieldStyle(.plain)
                    }
                    .padding(Theme.Space.s)
                    .background(Theme.panel, in: RoundedRectangle(cornerRadius: Theme.Space.s))
                    .overlay(RoundedRectangle(cornerRadius: Theme.Space.s).strokeBorder(Theme.border))
                    Picker("Sort", selection: $alphabetical) {
                        Text("Your order").tag(false)
                        Text("Name A–Z").tag(true)
                    }.labelsHidden().frame(width: 135)
                }
                if folders.isEmpty {
                    emptyState
                } else if shown.isEmpty {
                    ContentUnavailableView.search(text: search)
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
        case (0, _): return "Nothing registered yet"
        case let (all, 0): return "\(all) on this Mac"
        case let (all, _) where all == remote: return "\(all) on remote machines"
        case let (all, r): return "\(all - r) here · \(r) remote"
        }
    }

    private var emptyState: some View {
        Card(
            title: "Give this sidebar something to open.",
            subtitle: "Register a folder on this Mac or on a paired machine, or clone a repository onto either.",
            mark: "mark_archive"
        ) {
            Button("Add folder", .create) { onAdd() }
                .buttonStyle(AccentButtonStyle(small: true))
        }
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
                        Text("Folder missing")
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
                            Label("\(summary.tasks) tasks", systemImage: "checklist")
                            if let notes = summary.notes {
                                Label("\(notes) notes", systemImage: "note.text")
                            }
                        }
                        .font(Theme.caption).foregroundStyle(.secondary)
                        .padding(.top, Theme.Space.s)
                    }
                    ThemeRule().padding(.vertical, Theme.Space.s)
                    HStack {
                        if let changed = summaries[folder.id]?.changed {
                            Text(changed == 0 ? "No pending changes" : "\(changed) changed files")
                                .foregroundStyle(changed == 0 ? Theme.accent : Theme.secondary)
                        }
                        Spacer(minLength: 0)
                        Label("Open workspace", systemImage: "arrow.up.right")
                            .foregroundStyle(Theme.accent)
                    }.font(Theme.caption.weight(.medium))
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(folder.name), \(machineLine(for: folder) ?? "folder")")
    }

    private func machineLine(for folder: WorkspaceFolder) -> String? {
        if folder.isRemote {
            let label = folder.machineLabel?.trimmingCharacters(in: .whitespacesAndNewlines)
            return (label?.isEmpty == false) ? label : "Remote machine"
        }
        return "This Mac"
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
            parts.append("\(sessions) session\(sessions == 1 ? "" : "s")")
        }
        if let chats, chats > 0 {
            parts.append("\(chats) chat\(chats == 1 ? "" : "s")")
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
                InspectorTitle(title: "Workspace", symbol: "folder")
                Spacer(minLength: 0)
            }
            InspectorEmptyState(mark: "mark_archive", title: "Pick a folder", subtitle: "Open a workspace to see its details and tools here.")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Theme.background)
    }
}

#endif
