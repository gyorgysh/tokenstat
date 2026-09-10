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
        ThemedSheet(title: "Saved change", subtitle: "Read-only copy on this device",
                    icon: change.commit == nil ? .source : .commit, onClose: { dismiss() }) {
            if current {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: Theme.Space.m) {
                    metadata
                    if change.diffs.isEmpty {
                        Text("This saved commit has no file changes to display.")
                            .font(Theme.callout).foregroundStyle(Theme.controlGlyph)
                    }
                    ForEach(change.diffs, id: \.path) { diff in
                        VStack(alignment: .leading, spacing: Theme.Space.s) {
                            Text(diff.path).font(Theme.mono(12)).textSelection(.enabled)
                                .fixedSize(horizontal: false, vertical: true)
                            if diff.binary {
                                Text("Binary file · No text preview")
                                    .font(Theme.caption).foregroundStyle(Theme.controlGlyph)
                            } else if diff.hunks.isEmpty {
                                Text("No text changes in this snapshot")
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
            } else { Text("This saved work is no longer available in the current account.").font(Theme.callout) }
        }
        .onChange(of: current) { _, value in if !value { dismiss() } }
        .modalFrame(width: 800, height: 760)
        .presentationBackground(Theme.background)
        .presentationDetents([.large])
    }

    private var metadata: some View {
        VStack(alignment: .leading, spacing: Theme.Space.s) {
            Text(change.title).font(Theme.body.weight(.semibold)).textSelection(.enabled)
            Text("Saved \(change.capturedAt.formatted(date: .abbreviated, time: .shortened))")
                .font(Theme.caption).foregroundStyle(Theme.controlGlyph)
            if let commit = change.commit {
                Text("\(commit.author) · \(commit.shortID)")
                    .font(Theme.caption).foregroundStyle(Theme.controlGlyph).textSelection(.enabled)
                if !commit.body.isEmpty {
                    Text(commit.body).font(Theme.callout).textSelection(.enabled)
                }
            } else {
                Text("The working tree may have changed since this copy was saved. Open the folder to review its current changes.")
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
                Text("\(cut) more lines are in this saved copy. This preview shows the first 2,000 lines.")
                    .font(Theme.caption).foregroundStyle(Theme.controlGlyph)
            }
        }
    }
}
