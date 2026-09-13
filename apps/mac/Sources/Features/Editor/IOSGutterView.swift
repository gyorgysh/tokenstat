// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
//
// Source-available for review, NOT open source. See LICENSE: no rights to
// redistribute, publish, or ship a build are granted. Read it, study it, run
// your own build of it.
// "tokenstat" is a trademark of pueev OU. See TRADEMARK.md.

#if !os(macOS)
import UIKit

/// Line numbers and change marks beside the iOS text view.
///
/// A floating overlay, not a sibling: the text view keeps its own scrolling,
/// selection and keyboard behavior, and the coordinator slides this to the
/// content offset on every scroll. Numbers come from the layout manager, so
/// wrapped lines share one number and Dynamic Type matches the editor font
/// it measures. Changed rows get an accent bar from the same diff the
/// Changes panel parsed; the current row's number reads accent.
///
/// Decorative for assistive tech: VoiceOver reads the text, not the numbers.
final class IOSGutterView: UIView {
    weak var textView: UITextView?
    var font: UIFont = AppFonts.terminal(size: 14)
    var lineStarts: [Int] = [0]
    var lineCount = 1
    var changedLines: Set<Int> = []
    var currentLine = 1

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = UIColor(Theme.background)
        isOpaque = true
        isAccessibilityElement = false
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func draw(_ rect: CGRect) {
        guard let textView else { return }
        let layout = textView.layoutManager
        let nsText = textView.text as NSString
        let offset = textView.contentOffset
        let inset = textView.textContainerInset
        // Visible glyphs in text-container coordinates.
        let visible = CGRect(
            x: 0,
            y: offset.y - inset.top,
            width: textView.textContainer.size.width,
            height: bounds.height
        )
        let glyphRange = layout.glyphRange(forBoundingRect: visible, in: textView.textContainer)
        let numbers = UIColor.secondaryLabel
        let accent = UIColor(Theme.accent)
        layout.enumerateLineFragments(forGlyphRange: glyphRange) { _, usedRect, _, fragmentRange, _ in
            let charIndex = layout.characterIndexForGlyph(at: fragmentRange.location)
            guard charIndex < nsText.length else { return }
            let line = EditorGutterMap.paragraph(for: charIndex, lineStarts: self.lineStarts)
            let top = usedRect.minY + inset.top - offset.y
            let isCurrent = line == self.currentLine
            if EditorGutterMap.isParagraphStart(charIndex, lineStarts: self.lineStarts) {
                let label = "\(line)" as NSString
                let attributes: [NSAttributedString.Key: Any] = [
                    .font: self.font,
                    .foregroundColor: isCurrent ? accent : numbers,
                ]
                let size = label.size(withAttributes: attributes)
                // Number block ends where the marker lane begins.
                label.draw(
                    at: CGPoint(x: self.bounds.width - 8 - size.width, y: top),
                    withAttributes: attributes
                )
            }
            if self.changedLines.contains(line) {
                accent.setFill()
                UIRectFill(CGRect(x: 6, y: top + 2, width: 3, height: self.font.capHeight))
            }
        }
    }
}
#endif
