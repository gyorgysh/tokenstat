// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
//
// Source-available for review, NOT open source. See LICENSE: no rights to
// redistribute, publish, or ship a build are granted. Read it, study it, run
// your own build of it.
// "tokenstat" is a trademark of pueev OU. See TRADEMARK.md.

#if !os(macOS)
import SwiftUI

/// Previous commits in this folder, newest first.
///
/// The Mac inspector's History tab, as a pushed section. Read-only: a phone
/// can browse what already landed, it cannot stage or commit. `workspace.log`
/// is empty both when the folder is not a repository and when it has no
/// commits yet, so this screen asks `status` as well and draws a different
/// picture for each.
struct ClientWorkspaceHistoryView: View {
    let peer: String
    let workspaceID: String
    let folder: WorkspaceFolder
    let hostName: String
    /// Inspector panes already name this surface. Compact pushes still need the title.
    var showsNavigationTitle: Bool = true

    @Environment(AccountModel.self) private var account: AccountModel?
    @State private var live: WorkspaceFolder?
    @State private var commits: [Commit] = []
    @State private var errorMessage: String?
    @State private var loaded = false
    @State private var pictures = HistoryAvatarIndex.empty

    private var current: WorkspaceFolder { live ?? folder }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.Space.s) {
                if let errorMessage {
                    ClientErrorCard(message: errorMessage) {
                        Task { await load() }
                    }
                }
                content
            }
            .padding(.horizontal, Theme.Space.m)
            .padding(.top, Theme.Space.s)
            .padding(.bottom, 96)
        }
        .background(Theme.background)
        .modifier(ClientOptionalNavigationTitle(showsNavigationTitle ? L10n.text("common.history") : nil))
        .refreshable {
            await ClientRefresh.pull("workspace-history-\(workspaceID)") { await load() }
        }
        .task { await load() }
        .task(id: pictureKey) {
            let from = commits.first(where: { !$0.unpushed })?.id ?? ""
            pictures = .empty
            let loaded = (try? await Bridge.commitAvatars(workspaceID: workspaceID, peer: peer, oid: from)) ?? .empty
            guard !Task.isCancelled else { return }
            pictures = loaded.normalized()
        }
        .onReceive(NotificationCenter.default.publisher(for: GitCommitTarget.didChange)) { note in
            guard note.object as? GitCommitTarget == GitCommitTarget(peer: peer, workspaceID: workspaceID) else { return }
            Task { await load() }
        }
    }

    @ViewBuilder
    private var content: some View {
        if !current.exists {
            ClientSectionEmpty(
                text: L10n.text("apple.clientworkspacehistoryview.folder_missing.f06c68a6"),
                message: L10n.text("apple.clientworkspacehistoryview.this_folder_is_no_longer_on_0.ccbb9519", "\(place)")
            )
        } else if loaded, current.git?.isRepo != true {
            ClientSectionEmpty(
                text: L10n.text("apple.clientworkspacehistoryview.not_a_git_repository.f903b388"),
                art: .notGit,
                message: L10n.text("apple.clientworkspacehistoryview.this_folder_has_no_commits_to_browse_make.9d24da5f", "\(place)")
            )
        } else if loaded, commits.isEmpty, errorMessage == nil {
            ClientSectionEmpty(
                text: L10n.text("apple.clientworkspacehistoryview.no_commits_yet.f17a8736"),
                art: .history,
                message: L10n.text("apple.clientworkspacehistoryview.commit_selected_files_in_changes_and_the_r.99826438")
            )
        } else if loaded {
            ForEach(commits) { commit in
                NavigationLink {
                    ClientCommitDetailView(
                        peer: peer,
                        workspaceID: workspaceID,
                        hostName: hostName,
                        commit: commit
                    )
                } label: {
                    ClientCommitRow(
                        commit: commit,
                        avatar: pictures.url(
                            commitID: commit.id,
                            email: commit.email,
                            mine: commit.mine == true,
                            accountAvatar: account?.account?.avatar
                        )
                    )
                }
                .buttonStyle(.plain)
            }
        } else if errorMessage == nil {
            ProgressView()
                .frame(maxWidth: .infinity)
                .padding(.top, Theme.Space.xl)
        }
    }

    /// Newest pushed commit, so a later unpushed commit can reuse that
    /// author's picture by email. The peer is part of the key because two
    /// machines can host the same workspace id.
    private var pictureKey: String {
        let from = commits.first(where: { !$0.unpushed })?.id ?? ""
        return "\(peer)|\(workspaceID)|\(from)"
    }

    private var place: String {
        hostName.isEmpty ? L10n.text("apple.clientworkspacehistoryview.the_computer.da52d93a") : hostName
    }

    private func load() async {
        async let status = try? ClientRemote.status(peer: peer, workspace: workspaceID)
        do {
            let log = try await ClientRemote.log(peer: peer, workspace: workspaceID)
            guard !Task.isCancelled else { return }
            if let fresh = await status { live = fresh }
            commits = log
            errorMessage = nil
        } catch {
            guard !Task.isCancelled else { return }
            if let fresh = await status { live = fresh }
            errorMessage = ClientTunnelCopy.display(error.localizedDescription, host: hostName)
        }
        guard !Task.isCancelled else { return }
        loaded = true
    }
}

/// One commit: subject, then who and when.
private struct ClientCommitRow: View {
    let commit: Commit
    var avatar: String?

    private var identity: String {
        commit.email ?? commit.author
    }

    var body: some View {
        HStack(alignment: .top, spacing: Theme.Space.s) {
            Avatar(
                url: avatar,
                name: commit.author,
                handle: commit.author,
                size: 28,
                tint: Avatar.tint(for: identity)
            )
            .padding(.top, 1)
            VStack(alignment: .leading, spacing: 3) {
                Text(commit.subject)
                    .font(ClientType.label.weight(.medium))
                    .foregroundStyle(.primary)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                CommitTagPills(tags: commit.tagList)
                HStack(spacing: 5) {
                    Text(commit.author)
                        .lineLimit(1)
                    Text("·")
                    RelativeTimeText(date: commit.date, unitsStyle: .abbreviated)
                    Text("·")
                    Text(commit.shortID)
                        .font(ClientType.code)
                    if commit.unpushed {
                        Image(systemName: "arrow.up.circle")
                            .foregroundStyle(Theme.accent)
                            .accessibilityLabel(L10n.text("apple.clientworkspacehistoryview.not_pushed_yet.06de6fec"))
                    }
                }
                .font(ClientType.caption)
                .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
            Image(systemName: "chevron.right")
                .font(Theme.caption.weight(.semibold))
                .foregroundStyle(.tertiary)
                .padding(.top, 6)
        }
        .padding(Theme.Space.m)
        .frame(maxWidth: .infinity, alignment: .leading)
        .cardSurface()
        .contentShape(.rect)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(commit.subject)
        .accessibilityHint(L10n.text("apple.clientworkspacehistoryview.open_this_commit.1459225a"))
    }
}

/// One commit in full: what it says, then every file it changed.
struct ClientCommitDetailView: View {
    let peer: String
    let workspaceID: String
    let hostName: String
    let commit: Commit

    @State private var detail: CommitDetail?
    @State private var errorMessage: String?
    @State private var loaded = false
    @State private var revision = UUID()
    @State private var loadRevision = UUID()
    @State private var showingMessage = false

    var body: some View {
        GeometryReader { geometry in
            ClientDiffDocumentView(diffs: detail?.diffs ?? [], revision: revision) {
                if let errorMessage {
                    ClientErrorCard(message: errorMessage) { Task { await load() } }
                }
                metadata(expanded: false, compact: geometry.size.height < 500)
                if !loaded {
                    ProgressView().frame(maxWidth: .infinity, minHeight: 80)
                } else if let detail, detail.diffs.isEmpty {
                    ClientSectionEmpty(
                        text: detail.isMerge ? L10n.text("apple.clientworkspacehistoryview.a_merge_with_no_patch_of_its_own.862cd9e3") : L10n.text("apple.clientworkspacehistoryview.no_files_in_this_commit.db8823ee"),
                        art: .history,
                        message: detail.isMerge ? L10n.text("apple.clientworkspacehistoryview.the_changes_live_on_the_parents.24d17008") : nil
                    )
                }
            }
        }
        .background(Theme.background)
        .navigationTitle(commit.shortID)
        .navigationBarTitleDisplayMode(.inline)
        .refreshable {
            await ClientRefresh.pull("workspace-commit-\(workspaceID)-\(commit.id)") {
                await load()
            }
        }
        .task { await load() }
        .sheet(isPresented: $showingMessage) {
            ThemedSheet(title: L10n.text("apple.clientworkspacehistoryview.commit_message"),
                        subtitle: commit.shortID, icon: .commit, scrolls: true,
                        onClose: { showingMessage = false }) {
                metadata(expanded: true)
            }
            .presentationBackground(Theme.background)
            .presentationDetents([.large])
        }
    }

    /// The fixed summary reserves room for code; its message and tags remain
    /// available in full through a separate sheet, including in landscape.
    private func metadata(expanded: Bool, compact: Bool = false) -> some View {
        VStack(alignment: .leading, spacing: Theme.Space.s) {
            Text(commit.subject)
                .font(ClientType.sectionTitle)
                .lineLimit(expanded ? nil : (compact ? 1 : 2))
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
            if let body = detail?.body, !body.isEmpty, expanded || !compact {
                Text(body)
                    .font(ClientType.body)
                    .foregroundStyle(.secondary)
                    .lineLimit(expanded ? nil : 2)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
            }
            if expanded { CommitTagPills(tags: detail?.tagList ?? commit.tagList) }
            HStack(spacing: Theme.Space.s) {
                Text(commit.author)
                    .font(ClientType.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                RelativeTimeText(date: commit.date, unitsStyle: .abbreviated)
                    .font(ClientType.caption)
                    .foregroundStyle(.tertiary)
                Text(commit.shortID)
                    .font(ClientType.code)
                    .foregroundStyle(.tertiary)
                    .textSelection(.enabled)
                if detail?.isMerge == true {
                    Text(L10n.text("apple.clientworkspacehistoryview.merge.283128ac"))
                        .font(ClientType.caption.weight(.medium))
                        .foregroundStyle(Theme.secondary)
                }
                Spacer(minLength: 0)
            }
            HStack(spacing: Theme.Space.s) {
                if let detail {
                    if detail.added > 0 {
                        Text("+\(detail.added)")
                            .font(ClientType.diffFigure)
                            .foregroundStyle(Theme.diffAdded)
                    }
                    if detail.removed > 0 {
                        Text("−\(detail.removed)")
                            .font(ClientType.diffFigure)
                            .foregroundStyle(Theme.diffRemoved)
                    }
                    Text((detail.files.count == 1 ? L10n.text("apple.clientworkspacehistoryview.0_file_1.ac7c9517.one", "\(detail.files.count)") : L10n.text("apple.clientworkspacehistoryview.0_file_1.ac7c9517.other", "\(detail.files.count)")))
                        .font(ClientType.caption)
                        .foregroundStyle(.secondary)
                }
                if !expanded {
                    Spacer(minLength: 0)
                    Button(L10n.text("apple.clientworkspacehistoryview.read_full_message"), .reveal) { showingMessage = true }
                        .font(ClientType.caption)
                        .buttonStyle(.plain)
                        .foregroundStyle(Theme.accent)
                        .disabled(!loaded)
                }
            }
        }
        .padding(Theme.Space.m)
        .frame(maxWidth: .infinity, alignment: .leading)
        .cardSurface()
    }

    private func load() async {
        let request = UUID()
        loadRevision = request
        let owner = WorkViewedChange.owner(folderID: workspaceID, peer: peer)
        do {
            let fresh = try await ClientRemote.showCommit(
                peer: peer,
                workspace: workspaceID,
                commit: commit.id
            )
            guard !Task.isCancelled, request == loadRevision,
                  owner?.scope == WorkSessionContext.shared.scope else { return }
            detail = fresh
            revision = UUID()
            errorMessage = nil
            loaded = true
            await WorkViewedChange.save(owner: owner, commit: fresh)
        } catch {
            guard !Task.isCancelled, request == loadRevision,
                  owner?.scope == WorkSessionContext.shared.scope else { return }
            errorMessage = ClientTunnelCopy.display(error.localizedDescription, host: hostName)
        }
        loaded = true
    }
}

#endif
