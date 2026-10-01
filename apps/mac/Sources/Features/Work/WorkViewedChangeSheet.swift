// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
import SwiftUI

/// A saved revision has no repository actions. Closing returns to the exact
/// query and selection that opened it, without contacting its host.
struct WorkViewedChangeSheet: View {
    let change: WorkViewedChange
    var ownsSession: () -> Bool = { true }
    @Environment(\.dismiss) private var dismiss
    @State private var paneWidth: CGFloat = 0

    private var current: Bool {
        WorkCacheAccess.canRead(change.reference) && ownsSession()
    }

    var body: some View {
        ThemedSheet(title: L10n.text("apple.workviewedchangesheet.saved_change.c2f6fdb4"), subtitle: L10n.text("apple.workviewedchangesheet.read_only_copy_on_this_device.d7843b34"),
                    icon: change.commit == nil ? .source : .commit, onClose: { dismiss() }) {
            if current {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: Theme.Space.m) {
                    metadata
                    if change.diffs.isEmpty {
                        Text(L10n.text("apple.workviewedchangesheet.this_saved_commit_has_no_file_changes_to_d.e10f1c5c"))
                            .font(Theme.callout).foregroundStyle(Theme.controlGlyph)
                    }
                    ForEach(change.diffs, id: \.path) { diff in
                        VStack(alignment: .leading, spacing: Theme.Space.s) {
                            Text(diff.path).font(Theme.mono(12)).textSelection(.enabled)
                                .fixedSize(horizontal: false, vertical: true)
                            if diff.binary {
                                Text(L10n.text("apple.workviewedchangesheet.binary_file_no_text_preview.a81c1111"))
                                    .font(Theme.caption).foregroundStyle(Theme.controlGlyph)
                            } else if diff.hunks.isEmpty {
                                Text(L10n.text("apple.workviewedchangesheet.no_text_changes_in_this_snapshot.e43c1a4a"))
                                    .font(Theme.caption).foregroundStyle(Theme.controlGlyph)
                            } else {
                                preview(diff)
                            }
                        }
                        .padding(Theme.Space.m)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(Theme.sidebar, in: RoundedRectangle(cornerRadius: 12))
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .background(GeometryReader { geometry in
                Color.clear.onAppear { paneWidth = geometry.size.width }
                    .onChange(of: geometry.size.width) { _, width in paneWidth = width }
            })
            } else { Text(L10n.text("apple.workviewedchangesheet.this_saved_work_is_no_longer_available_in.4fd19612")).font(Theme.callout) }
        }
        .onChange(of: current) { _, value in if !value { dismiss() } }
        .modalFrame(width: 800, height: 760)
        .presentationBackground(Theme.background)
        .presentationDetents([.large])
    }

    private var metadata: some View {
        VStack(alignment: .leading, spacing: Theme.Space.s) {
            Text(change.title).font(Theme.body.weight(.semibold)).textSelection(.enabled)
            Text(L10n.text("apple.workviewedchangesheet.saved_0.4f0424e4", "\(change.capturedAt.formatted(date: .abbreviated, time: .shortened))"))
                .font(Theme.caption).foregroundStyle(Theme.controlGlyph)
            if let commit = change.commit {
                Text("\(commit.author) · \(commit.shortID)")
                    .font(Theme.caption).foregroundStyle(Theme.controlGlyph).textSelection(.enabled)
                if !commit.body.isEmpty {
                    Text(commit.body).font(Theme.callout).textSelection(.enabled)
                }
            } else {
                Text(L10n.text("apple.workviewedchangesheet.the_working_tree_may_have_changed_since_th.5400e334"))
                    .font(Theme.caption).foregroundStyle(Theme.controlGlyph)
            }
        }
        .fixedSize(horizontal: false, vertical: true)
    }

    private func preview(_ diff: FileDiff) -> some View {
        let (shown, cut) = diff.clipped(toLines: 2000)
        return VStack(alignment: .leading, spacing: Theme.Space.s) {
            ScrollView(.horizontal) {
                #if os(macOS)
                DiffBody(diff: shown, minWidth: max(0, paneWidth - Theme.Space.m * 2), lazy: false)
                #else
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(shown.hunks) { hunk in
                        Text(hunk.header).font(ClientType.code).foregroundStyle(Theme.controlGlyph)
                            .padding(.vertical, Theme.Space.s)
                        ForEach(hunk.lines) { line in
                            DiffLineRow(line: line, minWidth: max(0, paneWidth - Theme.Space.m * 2))
                        }
                    }
                }
                #endif
            }
            if cut > 0 {
                Text(L10n.text("apple.workviewedchangesheet.0_more_lines_are_in_this_saved_copy_this_p.bad5235b", "\(cut)"))
                    .font(Theme.caption).foregroundStyle(Theme.controlGlyph)
            }
        }
    }
}
