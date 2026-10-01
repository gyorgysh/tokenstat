// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
import SwiftUI

struct NoteMarkdownEditor: View {
    @Binding var text: String

    var body: some View {
        if #available(macOS 15, iOS 18, *) {
            SelectedNoteEditor(text: $text)
        } else {
            #if os(macOS)
            LegacyMacNoteEditor(text: $text)
            #else
            TextEditor(text: $text).accessibilityLabel(L10n.text("apple.notemarkdowneditor.note_body.39ff9bdc"))
            #endif
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
                Label(L10n.text("apple.notemarkdowneditor.format.2f343666"), systemImage: "textformat")
            }
            .fixedSize()
            TextEditor(text: $text, selection: $selection)
                .focused($writing)
                .accessibilityLabel(L10n.text("apple.notemarkdowneditor.note_body.39ff9bdc"))
                .overlay(alignment: .topLeading) {
                    if text.isEmpty {
                        Text(L10n.text("apple.notemarkdowneditor.note.d8da2c49")).foregroundStyle(.tertiary)
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
        undoManager?.setActionName(L10n.text("apple.notemarkdowneditor.format_note.20003a9e"))
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

#if os(macOS)
import AppKit

/// macOS 14 has no SwiftUI TextSelection. AppKit provides selection-aware
/// formatting and the editor's normal typing/formatting undo history there.
private struct LegacyMacNoteEditor: View {
    @Binding var text: String
    @State private var target = MacNoteFormattingTarget()

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.xs) {
            Menu {
                ForEach(NoteFormatting.allCases, id: \.self) { style in
                    Button(style.title, .edit) { target.apply(style) }
                }
            } label: {
                Label(L10n.text("apple.notemarkdowneditor.format.2f343666"), systemImage: "textformat")
            }
            .fixedSize()
            LegacyMacNoteSurface(text: $text, target: target)
        }
    }
}

@MainActor
final class MacNoteFormattingTarget {
    weak var editor: NSTextView?

    func apply(_ style: NoteFormatting) {
        guard let editor else { return }
        let edit = style.edit(editor.string, selection: editor.selectedRange())
        guard editor.shouldChangeText(in: edit.range, replacementString: edit.replacement) else { return }
        editor.textStorage?.replaceCharacters(in: edit.range, with: edit.replacement)
        editor.didChangeText()
        editor.setSelectedRange(edit.selection)
        editor.undoManager?.setActionName(L10n.text("apple.notemarkdowneditor.format_note.20003a9e"))
        editor.window?.makeFirstResponder(editor)
    }
}

private struct LegacyMacNoteSurface: NSViewRepresentable {
    @Binding var text: String
    let target: MacNoteFormattingTarget

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSTextView.scrollableTextView()
        let editor = scroll.documentView as! NSTextView
        editor.isRichText = false
        editor.allowsUndo = true
        editor.drawsBackground = false
        editor.font = .preferredFont(forTextStyle: .body)
        editor.textColor = .labelColor
        editor.textContainerInset = NSSize(width: 4, height: 8)
        editor.isHorizontallyResizable = false
        editor.textContainer?.widthTracksTextView = true
        editor.setAccessibilityLabel(L10n.text("apple.notemarkdowneditor.note_body.39ff9bdc"))
        scroll.drawsBackground = false
        editor.string = text
        editor.delegate = context.coordinator
        target.editor = editor
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        context.coordinator.parent = self
        guard let editor = scroll.documentView as? NSTextView else { return }
        target.editor = editor
        if editor.string != text {
            // A different note or an external revision must not inherit undo
            // operations that could restore the previous note's contents.
            editor.undoManager?.removeAllActions()
            editor.string = text
            editor.setSelectedRange(NSRange(location: (text as NSString).length, length: 0))
        }
    }

    static func dismantleNSView(_ scroll: NSScrollView, coordinator: Coordinator) {
        guard let editor = scroll.documentView as? NSTextView else { return }
        editor.undoManager?.removeAllActions()
        editor.delegate = nil
        coordinator.parent.target.editor = nil
    }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: LegacyMacNoteSurface
        private let history = UndoManager()
        init(_ parent: LegacyMacNoteSurface) { self.parent = parent }
        func undoManager(for view: NSTextView) -> UndoManager? { history }
        func textDidChange(_ notification: Notification) {
            guard let editor = notification.object as? NSTextView else { return }
            parent.text = editor.string
        }
    }
}
#endif
