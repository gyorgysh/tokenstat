// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
// Compile with NoteFormatting.swift.
import Foundation

@main struct NoteFormattingTests {
    static func main() {
        func applying(_ style: NoteFormatting, _ text: String, _ range: NSRange) -> (String, String) {
            let edit = style.edit(text, selection: range)
            let result = (text as NSString).replacingCharacters(in: edit.range, with: edit.replacement)
            return (result, (result as NSString).substring(with: edit.selection))
        }
        let unicode = applying(.bold, "A 🐈 sleeps", NSRange(location: 2, length: 2))
        precondition(unicode.0 == "A **🐈** sleeps" && unicode.1 == "🐈")
        precondition(applying(.checklist, "first\nsecond\nthird", NSRange(location: 2, length: 11)).0 == "- [ ] first\n- [ ] second\nthird")
        precondition(applying(.quote, "one\ntwo\nthree", NSRange(location: 5, length: 0)).0 == "one\n> two\nthree")
        let empty = applying(.bold, "", NSRange(location: 0, length: 0))
        precondition(empty.0 == "**text**" && empty.1 == "text")
        precondition(applying(.bullet, "one\n", NSRange(location: 4, length: 0)).0 == "one\n- List item")
        print("PASS: note formatting selection, Unicode, paragraphs and empty insertion")
    }
}
