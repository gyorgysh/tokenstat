// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
// Compile with EditorGutterMap.swift.
import Foundation

@main
struct EditorGutterMapTests {
    static func main() {
        func check(_ condition: Bool, _ message: String) {
            assert(condition, message)
        }
        do {
            let starts = EditorGutterMap.lineStarts(in: "a\nbb\nccc" as NSString)
            check(starts == [0, 2, 5], "line starts")
            check(EditorGutterMap.paragraph(for: 0, lineStarts: starts) == 1, "first char")
            check(EditorGutterMap.paragraph(for: 1, lineStarts: starts) == 1, "newline itself")
            check(EditorGutterMap.paragraph(for: 2, lineStarts: starts) == 2, "second line")
            check(EditorGutterMap.paragraph(for: 7, lineStarts: starts) == 3, "last char")
            check(EditorGutterMap.isParagraphStart(0, lineStarts: starts), "file start")
            check(!EditorGutterMap.isParagraphStart(1, lineStarts: starts), "mid line")
            check(EditorGutterMap.isParagraphStart(2, lineStarts: starts), "line start")
            check(EditorGutterMap.isParagraphStart(5, lineStarts: starts), "third line")
        }
        do {
            // UTF-16 units, like the text view: emoji count two.
            let text = "a😀\nbc" as NSString
            check(text.length == 6, "emoji is two units")
            let starts = EditorGutterMap.lineStarts(in: text)
            check(starts == [0, 4], "starts past the emoji")
            check(EditorGutterMap.paragraph(for: 1, lineStarts: starts) == 1, "inside the emoji")
            check(EditorGutterMap.paragraph(for: 5, lineStarts: starts) == 2, "after the break")
        }
        do {
            let starts = EditorGutterMap.lineStarts(in: "" as NSString)
            check(starts == [0], "empty file is one line")
            check(EditorGutterMap.paragraph(for: 0, lineStarts: starts) == 1, "empty paragraph")
            let trailing = EditorGutterMap.lineStarts(in: "a\n" as NSString)
            check(trailing == [0, 2], "trailing break opens a line")
        }
        do {
            let narrow = EditorGutterMap.width(digitAdvance: 8, lineCount: 9)
            let wide = EditorGutterMap.width(digitAdvance: 8, lineCount: 120_000)
            check(wide > narrow, "width grows with digits")
            check(narrow >= 36, "two digits still fit a finger")
            check(
                EditorGutterMap.width(digitAdvance: 8, lineCount: 0)
                    == EditorGutterMap.width(digitAdvance: 8, lineCount: 1),
                "empty clamps to one line"
            )
        }
        print("EditorGutterMapTests passed")
    }
}
