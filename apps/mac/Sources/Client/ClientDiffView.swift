// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
//
// Source-available for review, NOT open source. See LICENSE: no rights to
// redistribute, publish, or ship a build are granted. Read it, study it, run
// your own build of it.
// "tokenstat" is a trademark of pueev OU. See TRADEMARK.md.

#if !os(macOS)
import SwiftUI

/// One file's changes, read from the machine that owns the folder.
///
/// The thing this app is for on a phone: an agent worked while you were away,
/// and this is what it did. Read-only, deliberately. Staging, editing and
/// committing are decisions that want the diff and the repository in front of
/// you, and `docs/mobile-workflow.md` sequences them after this.
///
/// Not `DiffView`, which compiles here but is built for a Mac pane: its two
/// 44pt gutters and marker spend 102 points of chrome before a character of
/// code, which is a quarter of a phone's width. One gutter instead, and the
/// `+` or `−` carries which side of the change the line is on.
struct ClientDiffView: View {
    let peer: String
    let workspaceID: String
    let hostName: String
    let file: FileChange

    @State private var diff: FileDiff?
    @State private var errorMessage: String?
    @State private var loaded = false
    /// The width of the screen, measured.
    ///
    /// Inside a horizontally scrolling container `maxWidth: .infinity` means
    /// *unbounded* rather than "fill", so rows grow enormous and the content
    /// ends up somewhere off to the right. `DiffView` on the Mac learned this
    /// the same way. A row takes it as a minimum instead, which is also what
    /// makes the tint behind a short line span the screen rather than stop at
    /// the last character.
    @State private var paneWidth: CGFloat = 0

    private var name: String {
        file.path.split(separator: "/").last.map(String.init) ?? file.path
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.Space.s) {
                if let errorMessage {
                    ClientErrorCard(message: errorMessage) {
                        Task { await load() }
                    }
                }
                header
                body(for: diff)
            }
            .padding(.horizontal, Theme.Space.m)
            .padding(.top, Theme.Space.s)
            .padding(.bottom, 96)
        }
        .background(Theme.background)
        .background(
            GeometryReader { proxy in
                Color.clear
                    // Quantised: `minWidth` relays every row in the diff, and
                    // a rotation or a split-view drag would otherwise deliver
                    // a new width, and a full relayout, on every frame.
                    .onAppear { paneWidth = (proxy.size.width / 8).rounded(.down) * 8 }
                    .onChange(of: (proxy.size.width / 8).rounded(.down) * 8) { _, new in
                        paneWidth = new
                    }
            }
        )
        .navigationTitle(name)
        .navigationBarTitleDisplayMode(.inline)
        .refreshable {
            // Its own key. `ClientRefresh` throttles by key, so a diff sharing
            // one with the file list it was pushed from would swallow a pull.
            await ClientRefresh.pull("workspace-diff-\(workspaceID)-\(file.path)") {
                await load()
            }
        }
        .task { await load() }
    }

    /// What file, where, and how much of it moved. The path is here rather
    /// than in the title, which only has room for the name.
    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(file.path)
                .font(ClientType.caption)
                .foregroundStyle(.secondary)
                .lineLimit(2)
                .truncationMode(.head)
            HStack(spacing: Theme.Space.s) {
                Text(file.kind.label)
                    .font(ClientType.caption.weight(.medium))
                    .foregroundStyle(file.kind.tint)
                if let added = file.added, added > 0 {
                    Text("+\(added)")
                        .font(ClientType.rowFigure)
                        .foregroundStyle(Theme.diffAdded)
                }
                if let removed = file.removed, removed > 0 {
                    Text("−\(removed)")
                        .font(ClientType.rowFigure)
                        .foregroundStyle(Theme.diffRemoved)
                }
            }
        }
        .padding(Theme.Space.m)
        .frame(maxWidth: .infinity, alignment: .leading)
        .cardSurface()
    }

    /// Every way this can have nothing to draw says which way it is. An empty
    /// screen is the one answer that tells a person nothing.
    @ViewBuilder
    private func body(for diff: FileDiff?) -> some View {
        if !loaded {
            ProgressView()
                .frame(maxWidth: .infinity)
                .padding(.top, Theme.Space.xl)
        } else if let diff {
            if diff.binary {
                note("This is a binary file. There is nothing to show line by line.")
            } else if diff.hunks.isEmpty {
                note(diff.untracked
                     ? "This file is not tracked yet and is empty."
                     : "No changes against HEAD.")
            } else {
                hunks(of: diff)
            }
        } else if errorMessage == nil {
            note("That file is not in this folder any more.")
        }
    }

    /// The width a row should fill, less the card's own horizontal padding.
    private var rowWidth: CGFloat {
        max(0, paneWidth - Theme.Space.m * 2)
    }

    /// One horizontal scroll around the whole diff, not one per row, so the
    /// gutter and the code cannot slide out of step with each other.
    private func hunks(of diff: FileDiff) -> some View {
        ScrollView(.horizontal, showsIndicators: true) {
            LazyVStack(alignment: .leading, spacing: 0) {
                ForEach(diff.hunks) { hunk in
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
        .cardSurface()
    }

    private func note(_ text: String) -> some View {
        Text(text)
            .font(ClientType.body)
            .foregroundStyle(.secondary)
            .padding(Theme.Space.m)
            .frame(maxWidth: .infinity, alignment: .leading)
            .cardSurface()
    }

    private func load() async {
        do {
            diff = try await ClientRemote.diff(
                peer: peer,
                workspace: workspaceID,
                path: file.path
            )
            errorMessage = nil
        } catch {
            errorMessage = ClientTunnelCopy.display(error.localizedDescription, host: hostName)
        }
        loaded = true
    }
}

/// One line of a diff, sized for a phone.
///
/// One number column, not two. A line is on one side or the other, the `+` or
/// `−` says which, and a second column of dashes would spend width saying what
/// the marker already said. The number is the line's position on whichever
/// side it belongs to.
private struct DiffLineRow: View {
    let line: DiffLine
    /// At least this wide, so the tint behind a short line spans the screen
    /// rather than stopping at the last character. Zero sizes to content.
    let minWidth: CGFloat

    /// Both the gutter and the code scale with Dynamic Type, and they scale
    /// together because they share a font, so the columns stay aligned at
    /// every size.
    private var number: String {
        (line.newLine ?? line.oldLine).map(String.init) ?? "·"
    }

    private var marker: String {
        switch line.kind {
        case .added: return "+"
        case .removed: return "−"
        case .context: return " "
        }
    }

    private var tint: Color {
        switch line.kind {
        case .added: return Theme.diffAdded
        case .removed: return Theme.diffRemoved
        case .context: return .primary
        }
    }

    private var wash: Color {
        switch line.kind {
        case .added: return Theme.diffAdded.opacity(0.12)
        case .removed: return Theme.diffRemoved.opacity(0.12)
        case .context: return .clear
        }
    }

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            Text(number)
                .font(ClientType.code)
                .foregroundStyle(.tertiary)
                .frame(minWidth: 34, alignment: .trailing)
                .padding(.trailing, Theme.Space.xs)
            Text(marker)
                .font(ClientType.code)
                .foregroundStyle(tint)
                .frame(width: 12, alignment: .center)
            Text(line.text.isEmpty ? " " : line.text)
                .font(ClientType.code)
                .foregroundStyle(tint)
                .textSelection(.enabled)
                // Never wrap: a wrapped line loses its place against the
                // gutter, and long lines are what the horizontal scroll is for.
                .fixedSize(horizontal: true, vertical: false)
                .padding(.trailing, Theme.Space.m)
        }
        .padding(.leading, Theme.Space.xs)
        .frame(minWidth: minWidth, alignment: .leading)
        .background(wash)
    }
}

#endif
