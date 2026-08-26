// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
//
// Source-available for review, NOT open source. See LICENSE: no rights to
// redistribute, publish, or ship a build are granted. Read it, study it, run
// your own build of it.
// "tokenstat" is a trademark of pueev OU. See TRADEMARK.md.

#if !os(macOS)
import SwiftUI
import UIKit

/// The iPhone and iPad editor, using the same bridge spans as the Mac editor.
/// It stays a native text view so selection, undo and keyboard editing work
/// naturally instead of turning the file into a read-only coloured preview.
struct IOSCodeTextView: UIViewRepresentable {
    let document: EditorDocument

    func makeCoordinator() -> Coordinator {
        Coordinator(document: document)
    }

    func makeUIView(context: Context) -> UITextView {
        let view = UITextView()
        view.delegate = context.coordinator
        view.font = Coordinator.editorFont
        view.textColor = .label
        view.backgroundColor = .clear
        view.autocorrectionType = .no
        view.autocapitalizationType = .none
        view.smartDashesType = .no
        view.smartQuotesType = .no
        view.textContainerInset = UIEdgeInsets(top: 12, left: 12, bottom: 12, right: 12)
        view.alwaysBounceVertical = true
        context.coordinator.sync(document, into: view)
        return view
    }

    func updateUIView(_ view: UITextView, context: Context) {
        context.coordinator.sync(document, into: view)
    }

    @MainActor
    final class Coordinator: NSObject, UITextViewDelegate {
        static let editorFont = AppFonts.terminal(size: 14)

        private var document: EditorDocument
        private var syncedText = ""
        private var appliedSpans = -1
        private var applying = false

        init(document: EditorDocument) {
            self.document = document
        }

        func sync(_ next: EditorDocument, into view: UITextView) {
            document = next
            if next.text != syncedText {
                let selection = view.selectedRange
                applying = true
                view.attributedText = attributedText(next)
                applying = false
                syncedText = next.text
                appliedSpans = next.spansVersion
                view.selectedRange = NSRange(
                    location: min(selection.location, (next.text as NSString).length),
                    length: 0
                )
                return
            }
            guard next.spansVersion != appliedSpans else { return }
            // Not while an input method is composing. Marked text is a live
            // editing session the text view owns, and rewriting the storage
            // underneath it destroys the composition mid-word, which is every
            // character for somebody typing Japanese or Chinese, or
            // dictating. The colours can wait for the commit, and the next
            // sync applies them.
            guard view.markedTextRange == nil else { return }
            let selection = view.selectedRange
            applying = true
            // Colours over the text that is already there, not a replacement
            // for it. `setAttributedString` throws away the view's typing
            // attributes and undo coalescing along with the string it was
            // going to put back unchanged.
            applyColours(next, to: view.textStorage)
            applying = false
            appliedSpans = next.spansVersion
            view.selectedRange = selection
        }

        /// Repaint an existing storage in place: one edit transaction, the
        /// base colour reset across the whole range, then each span.
        private func applyColours(_ document: EditorDocument, to storage: NSTextStorage) {
            let full = NSRange(location: 0, length: storage.length)
            storage.beginEditing()
            storage.addAttribute(.foregroundColor, value: UIColor.label, range: full)
            for span in document.spans {
                guard span.start >= 0, span.len > 0, span.start + span.len <= storage.length else {
                    continue
                }
                storage.addAttribute(
                    .foregroundColor,
                    value: UIColor(Theme.syntax(span.kind)),
                    range: span.range
                )
            }
            storage.endEditing()
        }

        func textViewDidChange(_ textView: UITextView) {
            guard !applying else { return }
            syncedText = textView.text
            document.setText(textView.text)
        }

        private func attributedText(_ document: EditorDocument) -> NSAttributedString {
            let result = NSMutableAttributedString(
                string: document.text,
                attributes: [
                    .font: Self.editorFont,
                    .foregroundColor: UIColor.label,
                ]
            )
            let length = result.length
            for span in document.spans {
                guard span.start >= 0, span.len > 0, span.start + span.len <= length else {
                    continue
                }
                result.addAttribute(
                    .foregroundColor,
                    value: UIColor(Theme.syntax(span.kind)),
                    range: span.range
                )
            }
            return result
        }
    }
}

#endif
