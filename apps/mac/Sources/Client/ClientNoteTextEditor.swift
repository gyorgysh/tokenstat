// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
#if !os(macOS)
import SwiftUI
import UIKit

/// Native selection and undo work on iOS 17 as well as newer releases.
struct ClientNoteTextEditor: UIViewRepresentable {
    @Binding var text: String
    var enabled: Bool = true

    func makeUIView(context: Context) -> NoteTextSurface {
        let surface = NoteTextSurface()
        surface.editor.delegate = context.coordinator
        surface.editor.text = text
        return surface
    }

    func updateUIView(_ surface: NoteTextSurface, context: Context) {
        context.coordinator.parent = self
        if surface.editor.text != text {
            let selection = surface.editor.selectedRange
            surface.editor.text = text
            let length = (text as NSString).length
            surface.editor.selectedRange = NSRange(location: min(selection.location, length), length: 0)
        }
        surface.editor.isEditable = enabled
        surface.formatButton.isEnabled = enabled
    }

    func makeCoordinator() -> Coordinator { Coordinator(self) }
    final class Coordinator: NSObject, UITextViewDelegate {
        var parent: ClientNoteTextEditor
        init(_ parent: ClientNoteTextEditor) { self.parent = parent }
        func textViewDidChange(_ textView: UITextView) { parent.text = textView.text }
    }
}

final class NoteTextSurface: UIView {
    let editor = UITextView()
    let formatButton = UIButton(type: .system)

    override init(frame: CGRect) {
        super.init(frame: frame)
        editor.backgroundColor = .clear
        editor.font = .preferredFont(forTextStyle: .body)
        editor.adjustsFontForContentSizeCategory = true
        editor.accessibilityLabel = "Note body"
        editor.textContainerInset = UIEdgeInsets(top: 8, left: 0, bottom: 8, right: 0)
        var configuration = UIButton.Configuration.plain()
        configuration.title = "Format"
        configuration.image = UIImage(systemName: "textformat")
        configuration.imagePadding = 6
        formatButton.configuration = configuration
        formatButton.contentHorizontalAlignment = .leading
        formatButton.showsMenuAsPrimaryAction = true
        formatButton.menu = UIMenu(children: NoteFormatting.allCases.map { style in
            UIAction(title: style.title) { [weak self] _ in self?.apply(style) }
        })
        for view in [formatButton, editor] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
        }
        NSLayoutConstraint.activate([
            formatButton.leadingAnchor.constraint(equalTo: leadingAnchor),
            formatButton.topAnchor.constraint(equalTo: topAnchor),
            formatButton.heightAnchor.constraint(greaterThanOrEqualToConstant: 44),
            formatButton.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor),
            editor.topAnchor.constraint(equalTo: formatButton.bottomAnchor),
            editor.leadingAnchor.constraint(equalTo: leadingAnchor),
            editor.trailingAnchor.constraint(equalTo: trailingAnchor),
            editor.bottomAnchor.constraint(equalTo: bottomAnchor)
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    private func apply(_ style: NoteFormatting) {
        let edit = style.edit(editor.text, selection: editor.selectedRange)
        guard let start = editor.position(from: editor.beginningOfDocument, offset: edit.range.location),
              let end = editor.position(from: start, offset: edit.range.length),
              let range = editor.textRange(from: start, to: end) else { return }
        editor.becomeFirstResponder()
        editor.replace(range, withText: edit.replacement)
        editor.selectedRange = edit.selection
        editor.delegate?.textViewDidChange?(editor)
    }
}
#endif
