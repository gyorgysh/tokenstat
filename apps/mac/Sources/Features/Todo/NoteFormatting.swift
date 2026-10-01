// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
import Foundation

/// Markdown authoring is a presentation action; the stored note stays plain text.
enum NoteFormatting: CaseIterable {
    case heading, bold, italic, bullet, checklist, quote, code

    var title: String {
        switch self {
        case .heading: L10n.text("apple.noteformatting.heading.b34f17f0")
        case .bold: L10n.text("apple.noteformatting.bold.94fee62e")
        case .italic: L10n.text("apple.noteformatting.italic.9bf37cb5")
        case .bullet: L10n.text("apple.noteformatting.bulleted_list.ce51b395")
        case .checklist: L10n.text("apple.noteformatting.checklist.73460304")
        case .quote: L10n.text("apple.noteformatting.quote.eb4cdebd")
        case .code: L10n.text("apple.noteformatting.code.340f4630")
        }
    }

    struct Edit {
        let range: NSRange
        let replacement: String
        let selection: NSRange
    }

    func edit(_ text: String, selection: NSRange) -> Edit {
        let source = text as NSString
        let start = min(selection.location, source.length)
        var range = NSRange(location: start, length: min(selection.length, source.length - start))
        let prefix: String
        let suffix: String
        let placeholder: String
        let lines: Bool
        switch self {
        case .heading: (prefix, suffix, placeholder, lines) = ("## ", "", L10n.text("apple.noteformatting.heading.b34f17f0"), true)
        case .bold: (prefix, suffix, placeholder, lines) = ("**", "**", "text", false)
        case .italic: (prefix, suffix, placeholder, lines) = ("*", "*", "text", false)
        case .bullet: (prefix, suffix, placeholder, lines) = ("- ", "", L10n.text("apple.noteformatting.list_item.201333ac"), true)
        case .checklist: (prefix, suffix, placeholder, lines) = ("- [ ] ", "", L10n.text("apple.noteformatting.to_do.100ec1bc"), true)
        case .quote: (prefix, suffix, placeholder, lines) = ("> ", "", L10n.text("apple.noteformatting.quote.eb4cdebd"), true)
        case .code: (prefix, suffix, placeholder, lines) = ("`", "`", "code", false)
        }
        if lines {
            range = source.lineRange(for: range)
            // Keep the final line break outside the replacement/selection.
            while range.length > 0 && [10, 13].contains(source.character(at: NSMaxRange(range) - 1)) {
                range.length -= 1
            }
        }
        let selected = range.length == 0 ? placeholder : source.substring(with: range)
        let replacement = lines
            ? selected.components(separatedBy: "\n").map { prefix + $0 }.joined(separator: "\n")
            : prefix + selected + suffix
        return Edit(range: range, replacement: replacement, selection: NSRange(
            location: range.location + (prefix as NSString).length,
            length: (replacement as NSString).length - (prefix as NSString).length - (suffix as NSString).length))
    }
}
