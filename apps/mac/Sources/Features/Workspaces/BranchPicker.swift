// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
//
// Source-available for review, NOT open source. See LICENSE: no rights to
// redistribute, publish, or ship a build are granted. Read it, study it, run
// your own build of it.
// "tokenstat" is a trademark of pueev OU. See TRADEMARK.md.

import SwiftUI

/// Owns branch-picker presentation while letting each platform supply the
/// surface that opens it: a compact chip on Mac and a full-width card on iOS.
struct BranchPickerPresentation<Label: View>: View {
    let workspaceID: String
    let currentBranch: String?
    /// The model, when the caller has one: a switch has to know about open
    /// editor buffers before it moves the branch under them.
    var model: WorkspacesModel? = nil
    /// Opens the project's worktrees, from the foot of the picker. Nil where
    /// the surface has no worktree screen to open.
    var onWorktrees: (() -> Void)? = nil
    let onChanged: () async -> Void
    @ViewBuilder let label: () -> Label

    @State private var isPresented = false

    var body: some View {
        Button { isPresented = true } label: { label() }
            .buttonStyle(.plain)
            .accessibilityLabel(L10n.text("apple.branchpicker.switch_branch.5051902c"))
            #if os(macOS)
            .popover(isPresented: $isPresented, arrowEdge: .bottom) {
                BranchPickerContent(
                    workspaceID: workspaceID,
                    currentBranch: currentBranch,
                    model: model,
                    onChanged: onChanged,
                    dismiss: { isPresented = false },
                    onWorktrees: onWorktrees
                )
                .frame(width: 390, height: 490)
            }
            #else
            .sheet(isPresented: $isPresented) {
                NavigationStack {
                    BranchPickerContent(
                        workspaceID: workspaceID,
                        currentBranch: currentBranch,
                        model: model,
                        onChanged: onChanged,
                        dismiss: { isPresented = false }
                    )
                    .navigationTitle(L10n.text("apple.branchpicker.branches.2eee037c"))
                    .navigationBarTitleDisplayMode(.inline)
                    .toolbar {
                        ToolbarItem(placement: .topBarTrailing) {
                            Button(L10n.text("common.done")) { isPresented = false }
                        }
                    }
                }
                .presentationDetents([.medium, .large])
                .presentationDragIndicator(.visible)
                .background(Theme.panel)
            }
            #endif
    }
}

/// The compact branch control in the Mac workspace header.
struct BranchChip: View {
    let workspaceID: String
    var git: GitStatus
    var compact = false
    /// The model, when the caller has one, so a switch can check for unsaved
    /// editor buffers first.
    var model: WorkspacesModel? = nil
    var onWorktrees: (() -> Void)? = nil
    let onChanged: () async -> Void

    var body: some View {
        BranchPickerPresentation(
            workspaceID: workspaceID,
            currentBranch: git.branch,
            model: model,
            onWorktrees: onWorktrees,
            onChanged: onChanged
        ) {
            HStack(spacing: Theme.Space.xs) {
                Image(systemName: "arrow.triangle.branch")
                    .font(Theme.font(9))
                if !compact {
                    Text(git.branch ?? L10n.text("apple.branchpicker.detached.88e34e4c"))
                        .font(Theme.mono(12))
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .frame(maxWidth: 140)
                        .fixedSize(horizontal: true, vertical: false)
                        .help(git.branch ?? L10n.text("apple.branchpicker.detached.88e34e4c"))
                    if git.ahead > 0 {
                        Text("↑\(git.ahead)")
                            .font(Theme.numeric(11))
                            .foregroundStyle(Theme.secondary)
                    }
                    if git.behind > 0 {
                        Text("↓\(git.behind)")
                            .font(Theme.numeric(11))
                            .foregroundStyle(Theme.warning)
                    }
                }
                Image(systemName: "chevron.down")
                    .font(Theme.font(8, weight: .semibold))
                    .foregroundStyle(.tertiary)
            }
            .foregroundStyle(.secondary)
            .padding(.horizontal, Theme.Space.s)
            .padding(.vertical, 5)
            .background(Theme.panel, in: Capsule())
            .overlay(Capsule().strokeBorder(Theme.border, lineWidth: 1))
            .contentShape(Capsule())
            .help(L10n.text("apple.branchpicker.switch_branch_0.6ce43b80", "\(git.branch ?? L10n.text("apple.branchpicker.detached.88e34e4c"))"))
        }
    }
}

private struct BranchPickerContent: View {
    let workspaceID: String
    let currentBranch: String?
    /// Nil on surfaces that have no model, where there is no buffer state to
    /// check; those callers keep the old behaviour.
    var model: WorkspacesModel?
    let onChanged: () async -> Void
    let dismiss: () -> Void
    var onWorktrees: (() -> Void)? = nil

    @State private var branches: [GitBranch] = []
    @State private var query = ""
    @State private var isLoading = true
    @State private var workingID: String?
    @State private var outcome: GitOutcome?
    @State private var isCreating = false
    @State private var newName = ""
    /// A switch parked while the unsaved-work prompt is up.
    @State private var pendingAction: PendingBranchAction?
    @State private var confirmingUnsaved = false

    /// A branch switch waiting on the user's answer about unsaved buffers.
    private enum PendingBranchAction {
        case checkout(GitBranch)
        case create(String)
    }

    private var filtered: [GitBranch] {
        guard !query.isEmpty else { return branches }
        return branches.filter { $0.name.localizedCaseInsensitiveContains(query) }
    }

    private var locals: [GitBranch] { filtered.filter { !$0.remote } }
    private var remotes: [GitBranch] { filtered.filter(\.remote) }

    var body: some View {
        VStack(spacing: 0) {
            #if os(macOS)
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(L10n.text("apple.branchpicker.switch_branch.5051902c")).font(Theme.headline)
                    Text(L10n.text("apple.branchpicker.local_work_first_remote_branches_create_a.d96bd8e1"))
                        .font(Theme.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }
            .padding(Theme.Space.m)
            #endif

            searchField
                .padding(.horizontal, Theme.Space.m)
                .padding(.bottom, Theme.Space.s)

            ThemeRule()

            Group {
                if isLoading {
                    ProgressView(L10n.text("apple.branchpicker.reading_branches.6868e26a"))
                        .tint(Theme.accent)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if filtered.isEmpty {
                    VStack(spacing: Theme.Space.s) {
                        Image(systemName: "arrow.triangle.branch")
                            .font(Theme.font(28, weight: .light))
                            .foregroundStyle(Theme.accent)
                        Text(query.isEmpty ? L10n.text("apple.branchpicker.no_branches.77cec90a") : L10n.text("apple.branchpicker.no_matching_branches.68f9e0ee"))
                            .font(Theme.headline)
                        if !query.isEmpty {
                            Text(L10n.text("apple.branchpicker.try_another_part_of_the_branch_name.aff30449"))
                                .font(Theme.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 2) {
                            branchSection(L10n.text("apple.branchpicker.local.8c31e6e7"), branches: locals)
                            branchSection(L10n.text("apple.branchpicker.remote.ffa98e02"), branches: remotes)
                        }
                        .padding(Theme.Space.s)
                    }
                }
            }

            if let outcome, !outcome.ok {
                HStack(alignment: .top, spacing: Theme.Space.s) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(Theme.warning)
                    Text(outcome.message)
                        .font(Theme.caption)
                        .textSelection(.enabled)
                    Spacer(minLength: 0)
                }
                .padding(Theme.Space.s)
                .background(Theme.warning.opacity(0.10))
                .overlay(alignment: .top) { ThemeRule() }
            }

            ThemeRule()
            createRow
            if let onWorktrees {
                ThemeRule()
                // Worktrees live here, beside the branches, because a
                // worktree is a branch with a folder of its own. A toolbar
                // button of their own put a word most people never need
                // beside the project name.
                Button(L10n.text("apple.branchpicker.work_on_a_branch_in_its_own_folder.0d37adc5"), .source) {
                    dismiss()
                    // The popover has to be gone before a sheet can open.
                    Task { @MainActor in
                        try? await Task.sleep(for: .milliseconds(200))
                        onWorktrees()
                    }
                }
                .buttonStyle(.plain)
                .foregroundStyle(Theme.accent)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(Theme.Space.m)
                .help(L10n.text("apple.branchpicker.worktrees_a_separate_folder_for_another_br.d86cd8e4"))
            }
        }
        .background(Theme.panel)
        .task { await load() }
        // Three answers, because Cancel and Discard are different: one keeps
        // the buffers, the other lets the switch drop them. Without this a
        // branch move silently left editor buffers holding the old branch's
        // text, one Save away from overwriting the new branch's file.
        .confirmationDialog(
            L10n.text("apple.branchpicker.save_changes_before_switching_branches.df86487d"),
            isPresented: $confirmingUnsaved,
            titleVisibility: .visible
        ) {
            Button(L10n.text("apple.branchpicker.save_and_switch.b341e4a5")) {
                guard let action = pendingAction else { return }
                Task { await perform(action, saveFirst: true, reloadAfter: false) }
            }
            Button(L10n.text("apple.branchpicker.discard_and_switch.2c900860"), role: .destructive) {
                guard let action = pendingAction else { return }
                Task { await perform(action, saveFirst: false, reloadAfter: true) }
            }
            Button(L10n.text("common.cancel"), role: .cancel) { pendingAction = nil }
        } message: {
            Text(L10n.text("apple.branchpicker.files_open_in_this_workspace_have_changes.c74ba1e6"))
        }
    }

    private var searchField: some View {
        HStack(spacing: Theme.Space.s) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.tertiary)
            TextField(L10n.text("apple.branchpicker.filter_branches.cc9f20c6"), text: $query)
                .textFieldStyle(.plain)
            if !query.isEmpty {
                Button { query = "" } label: {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(.tertiary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(L10n.text("apple.branchpicker.clear_branch_filter.91702c83"))
            }
        }
        .padding(.horizontal, Theme.Space.s)
        .frame(minHeight: 36)
        .background(Theme.background, in: RoundedRectangle(cornerRadius: Theme.Space.s))
        .overlay(RoundedRectangle(cornerRadius: Theme.Space.s).strokeBorder(Theme.border))
    }

    @ViewBuilder
    private func branchSection(_ title: String, branches: [GitBranch]) -> some View {
        if !branches.isEmpty {
            Text(title.uppercased())
                .font(Theme.caption2.weight(.semibold))
                .foregroundStyle(.tertiary)
                .tracking(0.7)
                .padding(.horizontal, Theme.Space.s)
                .padding(.top, Theme.Space.xs)
            ForEach(branches) { branch in
                Button { Task { await checkout(branch) } } label: {
                    BranchRow(branch: branch, isWorking: workingID == branch.id)
                }
                .buttonStyle(BranchRowButtonStyle(selected: branch.current))
                .disabled(workingID != nil || branch.current)
                .accessibilityHint(branch.remote ? L10n.text("apple.branchpicker.creates_a_local_tracking_branch.062a62b7") : L10n.text("apple.branchpicker.switches_this_workspace.fbaa348e"))
            }
        }
    }

    @ViewBuilder
    private var createRow: some View {
        if isCreating {
            HStack(spacing: Theme.Space.s) {
                TextField(L10n.text("apple.branchpicker.feature_name.1f69ba4a"), text: $newName)
                    .textFieldStyle(.plain)
                    .padding(.horizontal, Theme.Space.s)
                    .frame(minHeight: 34)
                    .background(Theme.background, in: RoundedRectangle(cornerRadius: Theme.Space.s))
                    .overlay(RoundedRectangle(cornerRadius: Theme.Space.s).strokeBorder(Theme.border))
                    .onSubmit { Task { await create() } }
                Button(L10n.text("apple.branchpicker.create.4759498a"), .create) { Task { await create() } }
                    .buttonStyle(.borderedProminent)
                    .disabled(newName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || workingID != nil)
                Button(L10n.text("common.cancel"), .dismiss) {
                    isCreating = false
                    newName = ""
                }
                    .buttonStyle(.borderless)
            }
            .padding(Theme.Space.s)
        } else {
            Button(L10n.text("apple.branchpicker.new_branch_from_0.b6ff75b5", "\(currentBranch ?? L10n.text("apple.branchpicker.head.b5180223"))"), .create) {
                outcome = nil
                isCreating = true
            }
            .buttonStyle(.plain)
            .foregroundStyle(Theme.accent)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(Theme.Space.m)
        }
    }

    private func load() async {
        isLoading = true
        defer { isLoading = false }
        do {
            branches = try await Bridge.branches(id: workspaceID)
            outcome = nil
        } catch {
            outcome = GitOutcome(ok: false, message: error.localizedDescription)
        }
    }

    private func checkout(_ branch: GitBranch) async {
        guard confirmUnsavedWork(.checkout(branch)) else { return }
        await perform(.checkout(branch), saveFirst: false, reloadAfter: false)
    }

    private func create() async {
        let name = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return }
        guard confirmUnsavedWork(.create(name)) else { return }
        await perform(.create(name), saveFirst: false, reloadAfter: false)
    }

    /// Park the action and raise the prompt when this workspace has unsaved
    /// buffers; true means the caller may go straight ahead.
    private func confirmUnsavedWork(_ action: PendingBranchAction) -> Bool {
        guard model?.hasUnsavedWork(in: workspaceID) == true else { return true }
        pendingAction = action
        confirmingUnsaved = true
        return false
    }

    /// Switch branch or create one, with the user's answer about unsaved
    /// buffers applied.
    ///
    /// `reloadAfter` is the discard path: the buffers are read back once the
    /// branch has moved, so a later save cannot write the old branch's text
    /// over the new branch's file.
    private func perform(
        _ action: PendingBranchAction, saveFirst: Bool, reloadAfter: Bool
    ) async {
        pendingAction = nil
        workingID = workingID(for: action)
        defer { workingID = nil }
        if saveFirst, let model {
            guard await model.saveAllDirty(in: workspaceID) else {
                outcome = GitOutcome(
                    ok: false,
                    message: L10n.text("apple.branchpicker.the_open_files_could_not_be_saved_so_the_b.111513f4")
                )
                return
            }
        }
        do {
            let result: GitOutcome
            switch action {
            case let .checkout(branch):
                result = try await Bridge.checkout(id: workspaceID, branch: branch)
            case let .create(name):
                result = try await Bridge.createBranch(
                    id: workspaceID, name: name, from: currentBranch
                )
            }
            outcome = result
            guard result.ok else { return }
            await onChanged()
            if let model {
                if reloadAfter {
                    await model.discardUnsavedBuffers(in: workspaceID)
                } else if saveFirst {
                    for path in model.openFiles(in: workspaceID) {
                        await model.loadText(path, in: workspaceID)
                    }
                }
            }
            dismiss()
        } catch {
            outcome = GitOutcome(ok: false, message: error.localizedDescription)
        }
    }

    private func workingID(for action: PendingBranchAction) -> String {
        switch action {
        case let .checkout(branch): return branch.id
        case .create: return "create"
        }
    }
}

private struct BranchRow: View {
    let branch: GitBranch
    let isWorking: Bool

    var body: some View {
        HStack(spacing: Theme.Space.s) {
            ZStack {
                Circle()
                    .fill(branch.current ? Theme.accent : Theme.accent.opacity(0.10))
                    .frame(width: 26, height: 26)
                if isWorking {
                    ProgressView().controlSize(.small).tint(branch.current ? Theme.panel : Theme.accent)
                } else {
                    Image(systemName: branch.current ? "checkmark" : "arrow.triangle.branch")
                        .font(Theme.font(10, weight: .semibold))
                        .foregroundStyle(branch.current ? Theme.panel : Theme.accent)
                }
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(branch.name)
                    .font(Theme.mono(12, weight: branch.current ? .semibold : .regular))
                    .lineLimit(1)
                    .truncationMode(.middle)
                HStack(spacing: Theme.Space.xs) {
                    if branch.ahead > 0 {
                        Text("↑\(branch.ahead)").foregroundStyle(Theme.secondary)
                    }
                    if branch.behind > 0 {
                        Text("↓\(branch.behind)").foregroundStyle(Theme.warning)
                    }
                    if let date = branch.date {
                        RelativeTimeText(date: date, unitsStyle: .abbreviated)
                    }
                }
                .font(Theme.caption2)
                .foregroundStyle(.tertiary)
            }
            Spacer(minLength: Theme.Space.s)
            if branch.remote {
                Text(L10n.text("apple.branchpicker.track.9a0019c1"))
                    .font(Theme.caption2.weight(.semibold))
                    .foregroundStyle(Theme.accent)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 3)
                    .background(Theme.accent.opacity(0.10), in: Capsule())
            }
        }
        .padding(.horizontal, Theme.Space.s)
        .padding(.vertical, 7)
        .contentShape(.rect)
    }
}

private struct BranchRowButtonStyle: ButtonStyle {
    let selected: Bool

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background(
                selected ? Theme.rowSelected : (configuration.isPressed ? Theme.rowHighlight : Color.clear),
                in: RoundedRectangle(cornerRadius: Theme.Space.s)
            )
    }
}
