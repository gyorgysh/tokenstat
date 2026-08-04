// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
//
// Source-available for review, NOT open source. See LICENSE: no rights to
// redistribute, publish, or ship a build are granted. Read it, study it, run
// your own build of it.
// "tokenstat" is a trademark of pueev OU. See TRADEMARK.md.

#if os(macOS)
import AppKit
import SwiftUI

/// The editor's text surface.
///
/// `TextEditor` was here first and could not stay. It offers no access to its
/// text view, so there is nowhere to hang a ruler, a find bar, an undo manager
/// per document, syntax attributes or a current-line highlight. Every item in
/// this milestone needs the `NSTextView` underneath, so the wrapper goes.
///
/// # Who owns the text
///
/// The text view does, while editing. The document is told about each change
/// and never pushes back mid-edit: writing the string into the view on every
/// keystroke would reset the insertion point and discard the undo stack, which
/// is the classic way a SwiftUI-wrapped editor ends up fighting its user. The
/// view is only reloaded when the *document* changes, or when the file was
/// re-read from disk.
struct CodeTextView: NSViewRepresentable {
    let document: EditorDocument
    /// Called when the user asks to save, so the shortcut works with focus in
    /// the text view rather than only on the button.
    let onSave: () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(document: document, onSave: onSave)
    }

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSScrollView()
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = true
        scrollView.borderType = .noBorder
        scrollView.drawsBackground = false

        let textView = CodeNSTextView()
        textView.coordinator = context.coordinator
        textView.delegate = context.coordinator
        textView.allowsUndo = true
        textView.isRichText = false
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.isAutomaticSpellingCorrectionEnabled = false
        textView.isContinuousSpellCheckingEnabled = false
        textView.isGrammarCheckingEnabled = false
        // The native find bar, which is Cmd+F, Cmd+G and replace, for free and
        // behaving exactly as it does everywhere else on the system.
        textView.usesFindBar = true
        textView.isIncrementalSearchingEnabled = true
        textView.font = Coordinator.editorFont
        textView.textContainerInset = NSSize(width: 6, height: 8)
        textView.drawsBackground = false
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.textContainer?.widthTracksTextView = true
        textView.textContainer?.containerSize = NSSize(
            width: 0, height: CGFloat.greatestFiniteMagnitude
        )
        textView.maxSize = NSSize(
            width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude
        )

        scrollView.documentView = textView

        let ruler = LineNumberRuler(scrollView: scrollView, textView: textView)
        scrollView.verticalRulerView = ruler
        scrollView.hasVerticalRuler = true
        scrollView.rulersVisible = true

        context.coordinator.textView = textView
        context.coordinator.ruler = ruler
        context.coordinator.load(document, into: textView)
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        guard let textView = context.coordinator.textView else { return }
        context.coordinator.onSave = onSave
        context.coordinator.sync(document, into: textView)
    }

    @MainActor
    final class Coordinator: NSObject, NSTextViewDelegate {
        static let editorFont = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)

        private(set) var document: EditorDocument
        var onSave: () -> Void
        weak var textView: NSTextView?
        weak var ruler: LineNumberRuler?

        /// The spans version already applied, so a redraw does not re-attribute
        /// the whole file.
        private var appliedSpans = -1
        /// Set while this class is editing the text itself, so the edit is not
        /// reported back as if the user had typed it.
        private var isApplyingEdit = false

        init(document: EditorDocument, onSave: @escaping () -> Void) {
            self.document = document
            self.onSave = onSave
        }

        // MARK: - Loading

        func load(_ document: EditorDocument, into textView: NSTextView) {
            self.document = document
            isApplyingEdit = true
            textView.string = document.text
            isApplyingEdit = false
            // A freshly opened file has no undo history worth keeping, and
            // leaving the previous document's would let Cmd+Z type another
            // file's text into this one.
            textView.undoManager?.removeAllActions()
            appliedSpans = -1
            applyBaseAttributes(to: textView)
            applySpans(to: textView)
            refreshRuler(textView)
        }

        /// Reconcile the view with the model, on every SwiftUI update.
        func sync(_ next: EditorDocument, into textView: NSTextView) {
            if next.id != document.id {
                load(next, into: textView)
                return
            }
            document = next
            // The model's text and the view's disagree only when something
            // other than typing changed it: a save, or a re-read after the file
            // changed on disk. Typing is already in both.
            if next.text != textView.string {
                let selection = textView.selectedRange()
                isApplyingEdit = true
                textView.string = next.text
                isApplyingEdit = false
                textView.setSelectedRange(
                    NSRange(
                        location: min(selection.location, (next.text as NSString).length), length: 0
                    )
                )
                appliedSpans = -1
                applyBaseAttributes(to: textView)
            }
            applySpans(to: textView)
            refreshRuler(textView)
        }

        // MARK: - Attributes

        /// Font and colour for the whole file, under the syntax colours.
        ///
        /// Applied whenever the text is replaced wholesale. Without it, text
        /// typed after a span keeps that span's colour, because an
        /// `NSTextStorage` carries attributes forward from the character before
        /// the insertion point.
        private func applyBaseAttributes(to textView: NSTextView) {
            guard let storage = textView.textStorage else { return }
            let all = NSRange(location: 0, length: storage.length)
            storage.beginEditing()
            storage.setAttributes(
                [
                    .font: Self.editorFont,
                    .foregroundColor: NSColor.labelColor,
                ],
                range: all
            )
            storage.endEditing()
        }

        func applySpans(to textView: NSTextView, force: Bool = false) {
            guard force || document.spansVersion != appliedSpans else { return }
            guard let storage = textView.textStorage else { return }
            appliedSpans = document.spansVersion

            let length = storage.length
            storage.beginEditing()
            storage.setAttributes(
                [.font: Self.editorFont, .foregroundColor: NSColor.labelColor],
                range: NSRange(location: 0, length: length)
            )
            for span in document.spans {
                // A span measured against text that has since changed would
                // otherwise raise, and an out of range exception in an editor
                // loses the file the user was typing into.
                guard span.start >= 0, span.len > 0, span.start + span.len <= length else {
                    continue
                }
                storage.addAttribute(
                    .foregroundColor,
                    value: NSColor(Theme.syntax(span.kind)),
                    range: span.range
                )
            }
            storage.endEditing()
        }

        func refreshRuler(_ textView: NSTextView) {
            ruler?.changedLines = document.changedLines
            ruler?.sizeToFit(lineCount: textView.string.reduce(into: 1) { count, c in
                if c == "\n" { count += 1 }
            })
            ruler?.needsDisplay = true
        }

        // MARK: - NSTextViewDelegate

        func textDidChange(_ notification: Notification) {
            guard !isApplyingEdit, let textView = notification.object as? NSTextView else { return }
            document.setText(textView.string)
            refreshRuler(textView)
        }

        func textViewDidChangeSelection(_ notification: Notification) {
            // The gutter marks the caret's line, so it redraws when the caret
            // moves rather than only when the text does.
            guard let textView = notification.object as? NSTextView else { return }
            ruler?.needsDisplay = true
            textView.needsDisplay = true
        }

        /// Newline handling: keep the indentation of the line being left, and
        /// add one level after an opening brace.
        ///
        /// Done here rather than by overriding `insertNewline` so that the
        /// replacement is a single undo step with the newline itself. Splitting
        /// them means Cmd+Z removes the indent and leaves the line break, which
        /// takes two undos to do what looks like one thing.
        func textView(
            _ textView: NSTextView,
            shouldChangeTextIn range: NSRange,
            replacementString text: String?
        ) -> Bool {
            guard let text else { return true }
            let string = textView.string as NSString

            if text == "\n" {
                let lineRange = string.lineRange(for: NSRange(location: range.location, length: 0))
                let line = string.substring(with: lineRange)
                let indent = line.prefix { $0 == " " || $0 == "\t" }
                let beforeCaret = string.substring(
                    with: NSRange(
                        location: lineRange.location,
                        length: max(0, range.location - lineRange.location)
                    )
                ).trimmingCharacters(in: .whitespaces)

                var insert = "\n" + indent
                if beforeCaret.hasSuffix("{") || beforeCaret.hasSuffix("[")
                    || beforeCaret.hasSuffix("(") || beforeCaret.hasSuffix(":")
                {
                    insert += document.rules.indentUnit
                }
                if insert == "\n" { return true }
                replace(range, with: insert, in: textView)
                return false
            }

            // Wrap a selection in brackets or quotes rather than replacing it.
            // Typing a quote over selected text meaning "delete it" is a thing
            // nobody wants and every editor stopped doing.
            if range.length > 0, let closing = Self.pairs[text] {
                let selected = string.substring(with: range)
                replace(range, with: text + selected + closing, in: textView)
                textView.setSelectedRange(
                    NSRange(location: range.location + 1, length: range.length)
                )
                return false
            }

            // Type over a closing bracket the editor inserted, rather than
            // adding a second one.
            if range.length == 0, Self.closers.contains(text), range.location < string.length,
               string.substring(with: NSRange(location: range.location, length: 1)) == text
            {
                textView.setSelectedRange(NSRange(location: range.location + 1, length: 0))
                return false
            }

            if range.length == 0, let closing = Self.pairs[text], shouldPair(at: range.location, in: string) {
                replace(range, with: text + closing, in: textView)
                textView.setSelectedRange(NSRange(location: range.location + 1, length: 0))
                return false
            }

            return true
        }

        /// Only pair when the caret is at the end of a line or before something
        /// that closes. Pairing in front of a word turns `foo` into `(foo` plus
        /// a stray `)`, which is worse than not helping at all.
        private func shouldPair(at location: Int, in string: NSString) -> Bool {
            guard location < string.length else { return true }
            let next = string.substring(with: NSRange(location: location, length: 1))
            return next == "\n" || next == " " || next == "\t" || Self.closers.contains(next)
        }

        private static let pairs: [String: String] = [
            "(": ")", "[": "]", "{": "}", "\"": "\"", "'": "'", "`": "`",
        ]
        private static let closers: Set<String> = [")", "]", "}", "\"", "'", "`"]

        // MARK: - Commands from the text view

        func save() {
            onSave()
        }

        /// Comment or uncomment every line the selection touches.
        ///
        /// Uncomments when *every* touched line is already commented, which is
        /// what makes the key a toggle rather than two keys. A language with no
        /// line comment does nothing, rather than inserting a token that would
        /// not parse.
        func toggleComment() {
            guard let textView, let token = document.rules.lineComment else { return }
            let string = textView.string as NSString
            let selection = textView.selectedRange()
            let lineRange = string.lineRange(for: selection)
            let block = string.substring(with: lineRange)
            // A trailing newline would otherwise become an empty final line and
            // pick up a comment token of its own.
            let hasTrailingNewline = block.hasSuffix("\n")
            let body = hasTrailingNewline ? String(block.dropLast()) : block
            let lines = body.components(separatedBy: "\n")

            let meaningful = lines.filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
            let allCommented = !meaningful.isEmpty && meaningful.allSatisfy {
                $0.trimmingCharacters(in: .whitespaces).hasPrefix(token)
            }

            let updated: [String] = lines.map { line in
                if line.trimmingCharacters(in: .whitespaces).isEmpty { return line }
                if allCommented {
                    guard let found = line.range(of: token) else { return line }
                    var stripped = line
                    stripped.removeSubrange(found)
                    // The space this method adds when commenting comes back off
                    // when uncommenting, so a round trip is the identity.
                    if stripped[found.lowerBound...].hasPrefix(" ") {
                        stripped.remove(at: found.lowerBound)
                    }
                    return stripped
                }
                let indent = line.prefix { $0 == " " || $0 == "\t" }
                return indent + token + " " + line.dropFirst(indent.count)
            }

            let replacement = updated.joined(separator: "\n") + (hasTrailingNewline ? "\n" : "")
            replace(lineRange, with: replacement, in: textView)
            textView.setSelectedRange(
                NSRange(location: lineRange.location, length: (replacement as NSString).length)
            )
        }

        /// Indent or outdent the selected lines.
        func shiftIndent(_ direction: Int) {
            guard let textView else { return }
            let string = textView.string as NSString
            let selection = textView.selectedRange()
            let lineRange = string.lineRange(for: selection)
            let block = string.substring(with: lineRange)
            let hasTrailingNewline = block.hasSuffix("\n")
            let body = hasTrailingNewline ? String(block.dropLast()) : block
            let unit = document.rules.indentUnit

            let updated = body.components(separatedBy: "\n").map { line -> String in
                if direction > 0 { return line.isEmpty ? line : unit + line }
                if line.hasPrefix(unit) { return String(line.dropFirst(unit.count)) }
                if line.hasPrefix("\t") { return String(line.dropFirst()) }
                return String(line.drop { $0 == " " })
            }

            let replacement = updated.joined(separator: "\n") + (hasTrailingNewline ? "\n" : "")
            replace(lineRange, with: replacement, in: textView)
            textView.setSelectedRange(
                NSRange(location: lineRange.location, length: (replacement as NSString).length)
            )
        }

        /// Replace text so it lands on the undo stack as one action.
        ///
        /// `shouldChangeTextIn` before and `didChangeText` after is what
        /// registers the undo grouping. Setting `string` directly skips both,
        /// which is how an editor ends up with a Cmd+Z that does nothing.
        private func replace(_ range: NSRange, with text: String, in textView: NSTextView) {
            guard textView.shouldChangeText(in: range, replacementString: text) else { return }
            textView.textStorage?.replaceCharacters(in: range, with: text)
            textView.didChangeText()
        }
    }
}

/// The text view, subclassed only for the keys AppKit has no action for.
///
/// Cmd+/ and Cmd+] have no `NSResponder` selector to override, so they are
/// caught as key equivalents. Cmd+S is here too, because the toolbar button
/// alone means the shortcut does nothing while the caret is in the text, which
/// is where it always is when someone wants to save.
private final class CodeNSTextView: NSTextView {
    weak var coordinator: CodeTextView.Coordinator?

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard event.modifierFlags.contains(.command) else {
            return super.performKeyEquivalent(with: event)
        }
        switch event.charactersIgnoringModifiers {
        case "/":
            MainActor.assumeIsolated { coordinator?.toggleComment() }
            return true
        case "]":
            MainActor.assumeIsolated { coordinator?.shiftIndent(1) }
            return true
        case "[":
            MainActor.assumeIsolated { coordinator?.shiftIndent(-1) }
            return true
        case "s":
            MainActor.assumeIsolated { coordinator?.save() }
            return true
        default:
            return super.performKeyEquivalent(with: event)
        }
    }

    /// A wash across the line the caret is on.
    ///
    /// Drawn behind the text rather than as a background attribute on the
    /// range, which would be one more thing fighting the syntax attributes and
    /// would have to be removed and reapplied on every cursor move.
    override func drawBackground(in rect: NSRect) {
        super.drawBackground(in: rect)
        guard selectedRange().length == 0,
              let layoutManager, let container = textContainer
        else { return }

        let glyph = layoutManager.glyphIndexForCharacter(at: selectedRange().location)
        var line = layoutManager.lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil)
        line.origin.y += textContainerInset.height
        line.origin.x = 0
        line.size.width = max(bounds.width, container.size.width)

        NSColor(Theme.accent).withAlphaComponent(0.06).setFill()
        line.fill()
    }
}
#endif
