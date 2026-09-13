// SPDX-License-Identifier: LicenseRef-tokenstat-source-available

import Foundation
import CoreGraphics

/// Line math for the iOS gutter, without any view code.
///
/// Everything is in UTF-16 units, the same units `UITextView` ranges use, so
/// emoji and other multi-unit characters number the same row the text view
/// draws. Wrapped lines share their paragraph's number: only the first
/// fragment of a paragraph is numbered.
enum EditorGutterMap {
    /// UTF-16 offsets where each one-based line starts. Always starts with 0.
    static func lineStarts(in text: NSString) -> [Int] {
        var starts = [0]
        var index = 0
        while index < text.length {
            if text.character(at: index) == 0x0A {
                starts.append(index + 1)
            }
            index += 1
        }
        return starts
    }

    /// One-based paragraph number for a UTF-16 character index.
    static func paragraph(for index: Int, lineStarts: [Int]) -> Int {
        var line = 1
        var low = 0
        var high = lineStarts.count - 1
        while low <= high {
            let mid = (low + high) / 2
            if lineStarts[mid] <= index {
                line = mid + 1
                low = mid + 1
            } else {
                high = mid - 1
            }
        }
        return line
    }

    /// Whether a UTF-16 index starts its paragraph.
    static func isParagraphStart(_ index: Int, lineStarts: [Int]) -> Bool {
        guard index > 0 else { return true }
        return paragraph(for: index, lineStarts: lineStarts) != paragraph(for: index - 1, lineStarts: lineStarts)
    }

    /// Gutter width: a marker lane plus the digits the file needs, with room
    /// to breathe on a phone. The text view insets by this exact width.
    static func width(digitAdvance: CGFloat, lineCount: Int) -> CGFloat {
        let digits = max(2, String(max(1, lineCount)).count)
        return ceil(CGFloat(digits) * digitAdvance + 22)
    }
}
