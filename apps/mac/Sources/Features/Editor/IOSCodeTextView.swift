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
    var find: EditorFindSession?

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
        context.coordinator.attach(view, find: find)
        let savedSelection = document.selection
        context.coordinator.sync(document, into: view)
        let length = (document.text as NSString).length
        let location = min(savedSelection.location, length)
        view.selectedRange = NSRange(location: location, length: min(savedSelection.length, length - location))
        // No scrollRangeToVisible: this runs on every recreation (rotation,
        // cell reuse), and yanking the scroll to the cursor each time is not
        // restoring anything. Selection alone is the restore.
        return view
    }

    func updateUIView(_ view: UITextView, context: Context) {
        context.coordinator.attach(view, find: find)
        context.coordinator.sync(document, into: view)
    }

    @MainActor
    final class Coordinator: NSObject, UITextViewDelegate {
        static let editorFont = AppFonts.terminal(size: 14)

        private var document: EditorDocument
        private var syncedText = ""
        private var appliedSpans = -1
        private var applying = false
        private weak var view: UITextView?
        private var find: EditorFindSession?
        private var appliedFindRevision = -1
        private var gutter: IOSGutterView?
        private var gutterWidth: CGFloat = 0
        private var gutterStarts: [Int] = [0]

        init(document: EditorDocument) {
            self.document = document
        }

        func attach(_ view: UITextView, find: EditorFindSession?) {
            self.view = view
            if self.find !== find {
                self.find = find
                appliedFindRevision = -1
            }
            find?.handler = { [weak self] action in
                guard let view = self?.view else { return }
                self?.perform(action, in: view)
            }
            if gutter == nil {
                let gutter = IOSGutterView()
                gutter.textView = view
                view.addSubview(gutter)
                self.gutter = gutter
                view.registerForTraitChanges([UITraitUserInterfaceStyle.self]) { [weak self] (_: UITraitEnvironment, _: UITraitCollection) in
                    self?.gutter?.setNeedsDisplay()
                }
            }
            layoutGutter(beside: view)
        }

        /// The gutter floats over the leading inset, so the text view keeps
        /// its own scrolling, selection and keyboard behavior untouched.
        private func layoutGutter(beside view: UITextView) {
            let text = view.text as NSString
            gutterStarts = EditorGutterMap.lineStarts(in: text)
            let digitAdvance = ("8" as NSString).size(withAttributes: [.font: Self.editorFont]).width
            let width = EditorGutterMap.width(
                digitAdvance: digitAdvance,
                lineCount: max(1, gutterStarts.count)
            )
            if width != gutterWidth {
                gutterWidth = width
                var inset = view.textContainerInset
                inset.left = width + 8
                view.textContainerInset = inset
            }
            gutter?.font = Self.editorFont
            gutter?.frame = CGRect(
                x: 0,
                y: view.contentOffset.y,
                width: width,
                height: view.bounds.height
            )
            refreshGutterState(beside: view)
        }

        private func refreshGutterState(beside view: UITextView) {
            gutter?.lineStarts = gutterStarts
            gutter?.lineCount = max(1, gutterStarts.count)
            gutter?.changedLines = document.changedLines
            gutter?.currentLine = EditorGutterMap.paragraph(
                for: min(max(view.selectedRange.location, 0), max((view.text as NSString).length - 1, 0)),
                lineStarts: gutterStarts
            )
            gutter?.setNeedsDisplay()
        }

        func scrollViewDidScroll(_ scrollView: UIScrollView) {
            guard let view = view, scrollView === view else { return }
            gutter?.frame.origin.y = view.contentOffset.y
            gutter?.setNeedsDisplay()
        }

        func sync(_ next: EditorDocument, into view: UITextView) {
            document = next
            find?.composing = view.markedTextRange != nil
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
                find?.refresh(text: next.text)
                applyFindHighlights(to: view, force: true)
                layoutGutter(beside: view)
                return
            }
            guard next.spansVersion != appliedSpans else {
                applyFindHighlights(to: view, force: false)
                refreshGutterState(beside: view)
                return
            }
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
            applyFindHighlights(to: view, force: false)
            refreshGutterState(beside: view)
        }

        /// Match backgrounds over the buffer. Foreground colours belong to
        /// the syntax pass, which never touches the background, so the two
        /// do not fight. The current match needs no paint: the selection
        /// itself is its highlight.
        private func applyFindHighlights(to view: UITextView, force: Bool) {
            guard let find, find.showing, find.hasQuery else { return }
            guard view.markedTextRange == nil else { return }
            guard force || find.revision != appliedFindRevision else { return }
            appliedFindRevision = find.revision
            let storage = view.textStorage
            storage.beginEditing()
            storage.removeAttribute(.backgroundColor, range: NSRange(location: 0, length: storage.length))
            let tint = UIColor(Theme.accent.opacity(0.22))
            for range in find.matches {
                guard range.location + range.length <= storage.length else { continue }
                if find.current == range { continue }
                storage.addAttribute(.backgroundColor, value: tint, range: range)
            }
            storage.endEditing()
        }

        private func perform(_ action: EditorFindSession.Action, in view: UITextView) {
            guard let find else { return }
            switch action {
            case .next, .previous:
                guard let range = find.current else { return }
                applying = true
                view.selectedRange = range
                applying = false
                view.scrollRangeToVisible(range)
                document.selection = range
            case .replaceCurrent:
                guard !isComposing(view), let range = find.current,
                      let textRange = textRange(range, in: view) else { return }
                // `applying` stays off the delegate while replacing would
                // swallow the edit. Push the result to the document by hand:
                // the replacement is user text, not a sync reset.
                view.selectedRange = range
                view.replace(textRange, withText: find.replaceText)
                syncedText = view.text
                document.setText(view.text)
                document.selection = view.selectedRange
                find.refresh(text: view.text)
                applyFindHighlights(to: view, force: true)
                if let next = find.current {
                    applying = true
                    view.selectedRange = next
                    applying = false
                    view.scrollRangeToVisible(next)
                    document.selection = next
                }
            case .replaceAll:
                guard !isComposing(view), !find.matches.isEmpty else { return }
                // One undo for the whole scope, which is this open document.
                view.undoManager?.beginUndoGrouping()
                for range in find.matches.reversed() {
                    view.selectedRange = range
                    if let textRange = textRange(range, in: view) {
                        view.replace(textRange, withText: find.replaceText)
                    }
                }
                view.undoManager?.endUndoGrouping()
                syncedText = view.text
                document.setText(view.text)
                document.selection = NSRange(location: 0, length: 0)
                find.refresh(text: view.text)
                applyFindHighlights(to: view, force: true)
            }
        }

        private func textRange(_ range: NSRange, in view: UITextView) -> UITextRange? {
            guard let start = view.position(from: view.beginningOfDocument, offset: range.location),
                  let end = view.position(from: start, offset: range.length) else { return nil }
            return view.textRange(from: start, to: end)
        }

        private func isComposing(_ view: UITextView) -> Bool {
            let composing = view.markedTextRange != nil
            find?.composing = composing
            return composing
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

        func textViewDidChangeSelection(_ textView: UITextView) {
            guard !applying else { return }
            document.selection = textView.selectedRange
            refreshGutterState(beside: textView)
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
