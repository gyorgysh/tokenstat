// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
//
// Source-available: source sharing and own builds are permitted.
// Store and commercial distribution of builds is reserved. See LICENSE.
// "tokenstat" is a trademark of pueev OU. See TRADEMARK.md.

#if os(macOS)
import AppKit

final class LineNumberRuler: NSRulerView {
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
        fatalError(L10n.text("apple.linenumberruler.not_loaded_from_a_nib.658eb5f1"))
    }

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

    private var cachedText = ""
    private var cachedLength = -1
    private var cachedLineStarts: [Int] = [0]

    private func lineNumber(for location: Int, in text: NSString) -> Int {
        guard location > 0, location <= text.length else { return 1 }
        let starts = lineStarts(in: text)
        var low = 0
        var high = starts.count - 1
        while low < high {
            let mid = (low + high + 1) / 2
            if starts[mid] <= location {
                low = mid
            } else {
                high = mid - 1
            }
        }
        return low + 1
    }

    private func lineStarts(in text: NSString) -> [Int] {
        if text.length == cachedLength, cachedText == (text as String) {
            return cachedLineStarts
        }
        var starts: [Int] = [0]
        var from = 0
        while from < text.length {
            let found = text.range(
                of: "\n", options: [], range: NSRange(location: from, length: text.length - from)
            )
            guard found.location != NSNotFound else { break }
            from = found.location + 1
            starts.append(from)
        }
        cachedText = text as String
        cachedLength = text.length
        cachedLineStarts = starts
        return starts
    }
}
#endif
