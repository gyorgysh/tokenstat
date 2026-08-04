// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
//
// Source-available for review, NOT open source. See LICENSE: no rights to
// redistribute, publish, or ship a build are granted. Read it, study it, run
// your own build of it.
// "tokenstat" is a trademark of pueev OU. See TRADEMARK.md.

#if os(macOS)
import AppKit

/// The gutter: line numbers, and a mark on lines this change touched.
///
/// An `NSRulerView` rather than a column of text beside the editor, because a
/// second text view has to be kept scrolled to the same place as the first and
/// never quite is. The ruler is drawn by the scroll view that owns the text, so
/// it cannot drift.
final class LineNumberRuler: NSRulerView {
    /// One-based lines that differ from HEAD.
    var changedLines: Set<Int> = [] {
        didSet {
            guard changedLines != oldValue else { return }
            needsDisplay = true
        }
    }

    private var textView: NSTextView? { clientView as? NSTextView }

    init(scrollView: NSScrollView, textView: NSTextView) {
        super.init(scrollView: scrollView, orientation: .verticalRuler)
        clientView = textView
        ruleThickness = 44
    }

    @available(*, unavailable)
    required init(coder: NSCoder) {
        fatalError("not loaded from a nib")
    }

    /// Widen for a file with more lines than the gutter can show.
    ///
    /// Measured from the digit count rather than from a fixed width: a 12,000
    /// line file otherwise draws its numbers over the first column of code.
    func sizeToFit(lineCount: Int) {
        let digits = max(2, String(max(1, lineCount)).count)
        let width = CGFloat(digits) * 8 + 22
        if abs(width - ruleThickness) > 0.5 {
            ruleThickness = width
        }
    }

    override func drawHashMarksAndLabels(in rect: NSRect) {
        guard let textView,
              let layoutManager = textView.layoutManager,
              let container = textView.textContainer
        else { return }

        let text = textView.string as NSString
        let inset = textView.textContainerInset.height
        let font = NSFont.monospacedDigitSystemFont(ofSize: 10, weight: .regular)
        let attributes: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: NSColor.tertiaryLabelColor,
        ]
        let currentAttributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 10, weight: .semibold),
            .foregroundColor: NSColor.secondaryLabelColor,
        ]

        // Only the visible rows are drawn. Walking every line of a large file
        // on each scroll event is the difference between smooth and not.
        let visible = scrollView?.contentView.bounds ?? .zero
        let glyphRange = layoutManager.glyphRange(forBoundingRect: visible, in: container)
        let characterRange = layoutManager.characterRange(
            forGlyphRange: glyphRange, actualGlyphRange: nil
        )

        let cursorLine = lineNumber(for: textView.selectedRange().location, in: text)
        var line = lineNumber(for: characterRange.location, in: text)
        var index = characterRange.location

        while index < NSMaxRange(characterRange) || (index == text.length && line == 1) {
            let lineRange = text.lineRange(for: NSRange(location: index, length: 0))
            var fragment = layoutManager.lineFragmentRect(
                forGlyphAt: layoutManager.glyphIndexForCharacter(at: lineRange.location),
                effectiveRange: nil
            )
            fragment.origin.y += inset - visible.origin.y

            if changedLines.contains(line) {
                NSColor(Theme.accent).withAlphaComponent(0.7).setFill()
                NSBezierPath(
                    roundedRect: NSRect(
                        x: ruleThickness - 5, y: fragment.minY + 2,
                        width: 2.5, height: max(2, fragment.height - 4)
                    ),
                    xRadius: 1.25, yRadius: 1.25
                ).fill()
            }

            let label = "\(line)" as NSString
            let isCurrent = line == cursorLine
            let attrs = isCurrent ? currentAttributes : attributes
            let size = label.size(withAttributes: attrs)
            label.draw(
                at: NSPoint(
                    x: ruleThickness - 12 - size.width,
                    y: fragment.minY + (fragment.height - size.height) / 2
                ),
                withAttributes: attrs
            )

            if NSMaxRange(lineRange) <= index { break }
            index = NSMaxRange(lineRange)
            line += 1
        }
    }

    /// One-based line for a character offset.
    ///
    /// Counts newlines rather than enumerating lines. `enumerateSubstrings`
    /// with `.byLines` yields a substring for the partial line the offset sits
    /// inside, so counting those puts every caret one line too far down except
    /// when it happens to sit exactly on a line break.
    private func lineNumber(for location: Int, in text: NSString) -> Int {
        guard location > 0, location <= text.length else { return 1 }
        var line = 1
        var index = 0
        while index < location {
            let found = text.range(
                of: "\n", range: NSRange(location: index, length: location - index)
            )
            guard found.location != NSNotFound else { break }
            line += 1
            index = found.location + 1
        }
        return line
    }
}
#endif
