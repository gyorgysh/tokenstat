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
    }

    private func apply(_ style: NoteFormatting) {
        let range: NSRange
        if let selection, case .selection(let selected) = selection.indices {
            range = NSRange(selected, in: text)
        } else {
            range = NSRange(location: (text as NSString).length, length: 0)
        }
        let edit = style.edit(text, selection: range)
        text = (text as NSString).replacingCharacters(in: edit.range, with: edit.replacement)
        if let selected = Range(edit.selection, in: text) {
            selection = TextSelection(range: selected)
        }
        writing = true
    }
}
