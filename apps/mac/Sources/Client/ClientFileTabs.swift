// SPDX-License-Identifier: LicenseRef-tokenstat-source-available

#if !os(macOS)
import SwiftUI

/// The iPad files section fills the workspace detail, with persistent documents.
struct ClientFileTabs<Files: View>: View {
    let peer: String
    let workspace: String
    let folderName: String
    @ViewBuilder var files: () -> Files
    @Environment(ClientEditorStore.self) private var editors
    @State private var closing: ClientEditorTab?
    @State private var find = EditorFindSession()

    private var selected: ClientEditorTab? { editors.selected(peer: peer, workspace: workspace) }
    private var tabs: [ClientEditorTab] { editors.tabs(peer: peer, workspace: workspace) }

    var body: some View {
        VStack(spacing: 0) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: Theme.Space.s) {
                    Button(L10n.text("common.files"), .source) { editors.showFiles(peer: peer, workspace: workspace) }
                        .padding(Theme.Space.s)
                        .background(selected == nil ? Theme.accent.opacity(0.12) : .clear, in: Capsule())
                    ForEach(tabs) { tab in
                        HStack(spacing: Theme.Space.xs) {
                            Button { editors.select(tab) } label: {
                                Label((tab.id.path as NSString).lastPathComponent, systemImage: "doc.text")
                                    .lineLimit(1)
                            }
                            .accessibilityLabel(tab.id.path + (tab.document.isDirty ? L10n.text("apple.clientfiletabs.unsaved_changes.1a0f14bf") : ""))
                            .accessibilityAddTraits(selected?.id == tab.id ? .isSelected : [])
                            if tab.document.isDirty {
                                Circle().fill(Theme.accent).frame(width: 6, height: 6)
                                    .accessibilityHidden(true)
                            }
                            Button { requestClose(tab) } label: {
                                Image(systemName: "xmark")
                                    .frame(minWidth: 32, minHeight: 32)
                            }
                            .accessibilityLabel(L10n.text("apple.clientfiletabs.close_0.59546c79", "\(tab.id.path)"))
                            .disabled(tab.isSaving)
                        }
                        .padding(.leading, Theme.Space.s)
                        .background(selected?.id == tab.id ? Theme.accent.opacity(0.12) : .clear, in: Capsule())
                    }
                }
                .buttonStyle(.plain)
                .font(ClientType.caption)
                .padding(Theme.Space.s)
            }
            ThemeRule()
            if let tab = selected {
                editor(tab)
                    .id(tab.id)
            } else {
                files()
            }
        }
        .background(Theme.background)
        .navigationTitle(folderName)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if let tab = selected {
                ToolbarItem(placement: .topBarLeading) {
                    Button(L10n.text("common.files")) { editors.showFiles(peer: peer, workspace: workspace) }
                }
                ToolbarItem {
                    Button(L10n.text("apple.clientfiletabs.find_in_file.214c422e"), .search) { find.showing.toggle() }
                        .labelStyle(.iconOnly)
                        .keyboardShortcut("f", modifiers: .command)
                }
                ToolbarItem(placement: .primaryAction) {
                    Button(tab.isSaving ? L10n.text("apple.clientfiletabs.saving.23e39291") : L10n.text("common.save")) { Task { await editors.save(tab) } }
                        .keyboardShortcut("s", modifiers: .command)
                        .disabled(tab.isSaving || !tab.document.isDirty || tab.conflictHostContent != nil)
                }
                ToolbarItem(placement: .secondaryAction) {
                    Button(L10n.text("apple.clientfiletabs.close_file.bd9c76ec")) { requestClose(tab) }
                        .keyboardShortcut("w", modifiers: .command)
                        .disabled(tab.isSaving)
                }
            }
        }
        .confirmationDialog(L10n.text("apple.clientfiletabs.discard_changes.85bcf416"), isPresented: Binding(
            get: { closing != nil },
            set: { if !$0 { closing = nil } }
        ), titleVisibility: .visible) {
            Button(L10n.text("apple.clientfiletabs.discard.eb1a70e3"), role: .destructive) {
                if let closing { editors.close(closing, discard: true) }
                closing = nil
            }
            Button(L10n.text("apple.clientfiletabs.keep_editing.e76fd2ad"), role: .cancel) { closing = nil }
        } message: {
            Text(L10n.text("apple.clientfiletabs.0_has_edits_that_are_not_saved_on_that_com.97573681", "\(closing?.id.path ?? L10n.text("apple.clientfiletabs.this_file.eb43df97"))"))
        }
        // Next/previous match stay discoverable when the bar is hidden: the
        // same chord opens the bar, and navigates once it is open with
        // matches. Save and Find ride on their toolbar buttons above.
        .clientShortcuts(findShortcuts)
    }

    /// The find chords for the open tab, routed to the same session the bar
    /// drives. Hidden presses open the bar; open presses move the match.
    private var findShortcuts: [ClientShortcut] {
        let state = EditorShortcutState(
            canNavigate: find.canNavigate,
            findShowing: find.showing
        )
        return [
            .workbench(.findNext, id: "find-next", title: L10n.text("apple.clientfiletabs.find_next.664d6cdf"),
                       enabled: WorkbenchShortcutPolicy.canFindNext(state)) {
                if find.showing {
                    find.goNext()
                } else {
                    find.showing = true
                }
            },
            .workbench(.findPrevious, id: "find-previous", title: L10n.text("apple.clientfiletabs.find_previous.bf0e5179"),
                       enabled: WorkbenchShortcutPolicy.canFindPrevious(state)) {
                if find.showing {
                    find.goPrevious()
                } else {
                    find.showing = true
                }
            },
        ]
    }

    private func editor(_ tab: ClientEditorTab) -> some View {
        VStack(spacing: 0) {
            HStack(spacing: Theme.Space.s) {
                Text(tab.id.path)
                    .font(ClientType.caption.monospaced())
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.head)
                if tab.document.isDirty {
                    Label(L10n.text("apple.clientfiletabs.unsaved.6250d572"), systemImage: "circle.fill")
                        .font(ClientType.caption)
                        .foregroundStyle(Theme.warning)
                } else if let savedAt = tab.document.savedAt {
                    Text(L10n.text("apple.clientfiletabs.saved_0.4f0424e4", "\(savedAt.formatted(date: .omitted, time: .shortened))"))
                        .font(ClientType.caption)
                        .foregroundStyle(Theme.controlGlyph)
                }
                if !tab.document.changedLines.isEmpty {
                    Text(L10n.text("apple.clientfiletabs.0_changed.d85c3eae", "\(tab.document.changedLines.count)"))
                        .font(ClientType.caption.monospacedDigit())
                        .foregroundStyle(.tertiary)
                }
                Spacer(minLength: 0)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(Theme.Space.s)
            if find.showing {
                EditorFindBar(find: find)
            }
            if let host = tab.conflictHostContent {
                EditorConflictCard(document: tab.document, hostContent: host) {
                    Task { await editors.resolveConflict(tab, keepMine: false) }
                } onKeep: {
                    Task { await editors.resolveConflict(tab, keepMine: true) }
                }
                .padding(.horizontal, Theme.Space.m)
            }
            IOSCodeTextView(document: tab.document, find: find)
                .editorChangedLines(peer: peer, workspace: workspace, document: tab.document)
            if let error = tab.errorMessage {
                ClientErrorCard(message: error) { Task { await editors.save(tab) } }
                    .padding(Theme.Space.s)
            } else if let note = tab.document.highlightNote {
                Text(note)
                    .font(ClientType.caption)
                    .foregroundStyle(.secondary)
                    .padding(Theme.Space.s)
            }
        }
        .task { await tab.document.highlightNow() }
    }

    private func requestClose(_ tab: ClientEditorTab) {
        guard !tab.isSaving else { return }
        if !editors.close(tab) { closing = tab }
    }
}
#endif
