// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
//
// Source-available for review, NOT open source. See LICENSE: no rights to
// redistribute, publish, or ship a build are granted. Read it, study it, run
// your own build of it.
// "tokenstat" is a trademark of pueev OU. See TRADEMARK.md.

#if !os(macOS)
import SwiftUI

/// Every changed file's diff on one screen, for the final read before a
/// commit.
///
/// Bounded twice: at most twenty files, sixty lines each, with a Full diff
/// link per file for the rest. A generated file with oceans of output stays
/// a card with a link rather than a hang. File selection and the commit
/// draft live above this screen and are untouched by opening it.
struct ClientReviewAllView: View {
    let peer: String
    let workspaceID: String
    let hostName: String
    let files: [FileChange]

    static let maxFiles = 20
    static let linesPerFile = 60

    @Environment(\.fileContent) private var content
    @State private var diffs: [String: FileDiff] = [:]
    @State private var failures = 0
    @State private var loaded = false

    private var shown: [FileChange] { Array(files.prefix(Self.maxFiles)) }
    private var leftoverFiles: Int { max(0, files.count - shown.count) }

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: Theme.Space.m) {
                if !loaded {
                    ProgressView()
                        .frame(maxWidth: .infinity)
                        .padding(.top, Theme.Space.xl)
                } else {
                    if failures > 0 {
                        Text("\(failures) file\(failures == 1 ? "" : "s") did not load. Open \(failures == 1 ? "it" : "them") individually for the diff.")
                            .font(ClientType.caption)
                            .foregroundStyle(Theme.controlGlyph)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    ForEach(shown) { file in
                        fileCard(file)
                    }
                    if leftoverFiles > 0 {
                        Text("\(leftoverFiles) more file\(leftoverFiles == 1 ? "" : "s") changed. Open \(leftoverFiles == 1 ? "it" : "them") from Changes for the diff.")
                            .font(ClientType.caption)
                            .foregroundStyle(Theme.controlGlyph)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            .padding(.horizontal, Theme.Space.m)
            .padding(.top, Theme.Space.s)
            .padding(.bottom, 96)
        }
        .background(Theme.background)
        .navigationTitle("Review all")
        .navigationBarTitleDisplayMode(.inline)
        .refreshable {
            await ClientRefresh.pull("workspace-review-all-\(workspaceID)") { await load() }
        }
        .task { await load() }
    }

    @ViewBuilder
    private func fileCard(_ file: FileChange) -> some View {
        VStack(alignment: .leading, spacing: Theme.Space.s) {
            HStack(spacing: Theme.Space.s) {
                Text(file.path.split(separator: "/").last.map(String.init) ?? file.path)
                    .font(ClientType.label.weight(.semibold))
                    .lineLimit(1)
                    .truncationMode(.head)
                Spacer(minLength: 0)
                Text(file.kind.label)
                    .font(ClientType.caption.weight(.medium))
                    .foregroundStyle(file.kind.tint)
            }
            if let diff = diffs[file.path] {
                if diff.binary {
                    Text("A binary file. There is nothing to show line by line.")
                        .font(ClientType.caption)
                        .foregroundStyle(.secondary)
                } else if diff.hunks.isEmpty {
                    Text("No changes against HEAD.")
                        .font(ClientType.caption)
                        .foregroundStyle(.secondary)
                } else {
                    let total = diff.hunks.reduce(0) { $0 + $1.lines.count }
                    let (shown, cut) = diff.clipped(toLines: Self.linesPerFile)
                    ForEach(shown.hunks) { hunk in
                        ForEach(hunk.lines) { line in
                            DiffLineRow(line: line, minWidth: 0)
                        }
                    }
                    if cut > 0 {
                        Text("Showing \(total - cut) of \(total) lines here.")
                            .font(ClientType.caption)
                            .foregroundStyle(Theme.controlGlyph)
                    }
                }
            } else {
                Text("Still loading.")
                    .font(ClientType.caption)
                    .foregroundStyle(.tertiary)
            }
            NavigationLink {
                ClientDiffView(peer: peer, workspaceID: workspaceID, hostName: hostName, file: file)
            } label: {
                HStack {
                    Text("Full diff")
                        .font(ClientType.label.weight(.medium))
                        .foregroundStyle(Theme.accent)
                    Spacer(minLength: 0)
                    Image(systemName: "chevron.right")
                        .font(Theme.caption.weight(.semibold))
                        .foregroundStyle(Theme.controlGlyph)
                }
                .padding(.vertical, Theme.Space.xs)
                .contentShape(.rect)
            }
            .buttonStyle(.plain)
        }
        .padding(Theme.Space.m)
        .frame(maxWidth: .infinity, alignment: .leading)
        .cardSurface()
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(file.path). \(file.kind.label)")
    }

    private func load() async {
        var fresh: [String: FileDiff] = [:]
        var missed = 0
        for file in shown {
            do {
                fresh[file.path] = try await content.diff(peer: peer, workspace: workspaceID, path: file.path)
            } catch {
                missed += 1
            }
        }
        diffs = fresh
        failures = missed
        loaded = true
    }
}
#endif
