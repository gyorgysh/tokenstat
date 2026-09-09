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

    @Environment(AccountModel.self) private var account
    @State private var live: WorkspaceFolder?
    @State private var commits: [Commit] = []
    @State private var errorMessage: String?
    @State private var loaded = false

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
        .navigationTitle("History")
        .navigationBarTitleDisplayMode(.inline)
        .refreshable {
            await ClientRefresh.pull("workspace-history-\(workspaceID)") { await load() }
        }
        .task { await load() }
    }

    @ViewBuilder
    private var content: some View {
        if !current.exists {
            ClientSectionEmpty(
                text: "Folder missing",
                message: "This folder is no longer on \(place)."
            )
        } else if loaded, current.git?.isRepo != true {
            ClientSectionEmpty(
                text: "Not a git repository",
                art: .notGit,
                message: "This folder has no commits to browse. Make it a repository on \(place) and they will appear here."
            )
        } else if loaded, commits.isEmpty, errorMessage == nil {
            ClientSectionEmpty(
                text: "No commits yet",
                art: .history,
                message: "Make the first commit on \(place) and it will appear here."
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
                        avatar: commit.mine == true ? account.account?.avatar : nil
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

    private var place: String {
        hostName.isEmpty ? "the computer" : hostName
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
                            .accessibilityLabel("Not pushed yet")
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
        .accessibilityHint("Open this commit")
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
    @State private var paneWidth: CGFloat = 0

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.Space.s) {
                if let errorMessage {
                    ClientErrorCard(message: errorMessage) {
                        Task { await load() }
                    }
                }
                header
                body(for: detail)
            }
            .padding(.horizontal, Theme.Space.m)
            .padding(.top, Theme.Space.s)
            .padding(.bottom, 96)
        }
        .background(Theme.background)
        .background(
            GeometryReader { proxy in
                Color.clear
                    .onAppear { paneWidth = (proxy.size.width / 8).rounded(.down) * 8 }
                    .onChange(of: (proxy.size.width / 8).rounded(.down) * 8) { _, new in
                        paneWidth = new
                    }
            }
        )
        .navigationTitle(commit.shortID)
        .navigationBarTitleDisplayMode(.inline)
        .refreshable {
            await ClientRefresh.pull("workspace-commit-\(workspaceID)-\(commit.id)") {
                await load()
            }
        }
        .task { await load() }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: Theme.Space.s) {
            Text(commit.subject)
                .font(ClientType.sectionTitle)
            if let body = detail?.body, !body.isEmpty {
                Text(body)
                    .font(ClientType.body)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
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
                    Text("merge")
                        .font(ClientType.caption.weight(.medium))
                        .foregroundStyle(Theme.secondary)
                }
                Spacer(minLength: 0)
            }
            if let detail {
                HStack(spacing: Theme.Space.s) {
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
                    Text("\(detail.files.count) file\(detail.files.count == 1 ? "" : "s")")
                        .font(ClientType.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding(Theme.Space.m)
        .frame(maxWidth: .infinity, alignment: .leading)
        .cardSurface()
    }

    @ViewBuilder
    private func body(for detail: CommitDetail?) -> some View {
        if !loaded {
            ProgressView()
                .frame(maxWidth: .infinity)
                .padding(.top, Theme.Space.xl)
        } else if let detail {
            if detail.diffs.isEmpty {
                ClientSectionEmpty(
                    text: detail.isMerge ? "A merge with no patch of its own" : "No files in this commit",
                    art: .history,
                    message: detail.isMerge
                        ? "The changes live on the parents."
                        : nil
                )
            } else {
                ForEach(detail.diffs, id: \.path) { diff in
                    fileCard(diff)
                }
            }
        }
    }

    private func fileCard(_ diff: FileDiff) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: Theme.Space.s) {
                Text(diff.fileName)
                    .font(ClientType.label.weight(.medium))
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: 0)
                Text(diff.path)
                    .font(ClientType.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.head)
            }
            .padding(Theme.Space.m)
            if diff.binary {
                note("This is a binary file. There is nothing to show line by line.")
            } else if diff.hunks.isEmpty {
                note("No line changes in this file.")
            } else {
                hunks(of: diff)
            }
        }
        .cardSurface()
    }

    private var rowWidth: CGFloat {
        max(0, paneWidth - Theme.Space.m * 2)
    }

    /// Eager, like the file diff: a lazy stack widens as rows materialize and
    /// the widening drags a horizontal scroll back to the start. Capped for
    /// the same reason, with the count said out loud.
    private static let maxLines = 2000

    private func hunks(of diff: FileDiff) -> some View {
        let total = diff.hunks.reduce(0) { $0 + $1.lines.count }
        let (shown, cut) = diff.clipped(toLines: Self.maxLines)
        return VStack(alignment: .leading, spacing: 0) {
            ScrollView(.horizontal, showsIndicators: true) {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(shown.hunks) { hunk in
                        Text(hunk.header)
                            .font(ClientType.code)
                            .foregroundStyle(.tertiary)
                            .lineLimit(1)
                            .padding(.horizontal, Theme.Space.s)
                            .padding(.vertical, 6)
                            .frame(minWidth: rowWidth, alignment: .leading)
                            .background(Theme.panel)
                        ForEach(hunk.lines) { line in
                            DiffLineRow(line: line, minWidth: rowWidth)
                        }
                    }
                }
                .padding(.vertical, Theme.Space.xs)
            }
            if cut > 0 {
                note("Showing the first \(total - cut) of \(total) lines.")
            }
        }
    }

    private func note(_ text: String) -> some View {
        Text(text)
            .font(ClientType.caption)
            .foregroundStyle(.secondary)
            .padding(.horizontal, Theme.Space.m)
            .padding(.bottom, Theme.Space.m)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func load() async {
        do {
            detail = try await ClientRemote.showCommit(
                peer: peer,
                workspace: workspaceID,
                commit: commit.id
            )
            errorMessage = nil
        } catch {
            errorMessage = ClientTunnelCopy.display(error.localizedDescription, host: hostName)
        }
        loaded = true
    }
}

#endif
