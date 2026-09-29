// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
import SwiftUI

struct NoteMarkdownEditor: View {
    @Binding var text: String

    var body: some View {
        if #available(macOS 15, iOS 18, *) {
            SelectedNoteEditor(text: $text)
        } else {
            TextEditor(text: $text).accessibilityLabel("Note body")
        }
    }
}

@available(macOS 15, iOS 18, *)
private struct SelectedNoteEditor: View {
    @Binding var text: String
    @State private var selection: TextSelection?
    @FocusState private var writing: Bool
    @Environment(\.undoManager) private var undoManager
    @State private var history = NoteFormattingHistory()

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.xs) {
            Menu {
                ForEach(NoteFormatting.allCases, id: \.self) { style in
                    Button(style.title, .edit) { apply(style) }
                }
            } label: {
                Label("Format", systemImage: "textformat")
            }
            .fixedSize()
            TextEditor(text: $text, selection: $selection)
                .focused($writing)
                .accessibilityLabel("Note body")
                .overlay(alignment: .topLeading) {
                    if text.isEmpty {
                        Text("Note").foregroundStyle(.tertiary)
                            .padding(.horizontal, Theme.Space.xs)
                            .padding(.vertical, Theme.Space.s)
                            .allowsHitTesting(false)
                    }
                }
        }
        .onAppear {
            let value = $text
            let selected = $selection
            history.read = { value.wrappedValue }
            history.write = { replacement in
                selected.wrappedValue = nil
                value.wrappedValue = replacement
            }
        }
        .onDisappear {
            undoManager?.removeAllActions(withTarget: history)
            history.read = nil
            history.write = nil
        }
    }

    private func apply(_ style: NoteFormatting) {
        let range: NSRange
        if let selection, case .selection(let selected) = selection.indices {
            range = NSRange(selected, in: text)
        } else {
            range = NSRange(location: (text as NSString).length, length: 0)
        }
        let edit = style.edit(text, selection: range)
        history.replace((text as NSString).replacingCharacters(in: edit.range, with: edit.replacement), manager: undoManager)
        undoManager?.setActionName("Format Note")
        if let selected = Range(edit.selection, in: text) {
            selection = TextSelection(range: selected)
        }
        writing = true
    }
}

/// A stable undo target whose bindings are detached when the note closes.
@MainActor
private final class NoteFormattingHistory {
    var read: (() -> String)?
    var write: ((String) -> Void)?

    func replace(_ text: String, manager: UndoManager?) {
        guard let previous = read?(), let write, previous != text else { return }
        manager?.registerUndo(withTarget: self) { [weak manager] target in
            target.replace(previous, manager: manager)
        }
        write(text)
    }
}
