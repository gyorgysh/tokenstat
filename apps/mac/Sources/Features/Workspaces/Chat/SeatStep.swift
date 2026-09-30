// SPDX-License-Identifier: LicenseRef-tokenstat-source-available

import Foundation

/// Words for the live seat, a tool row, and a permission chip.
///
/// The same sentences are used on every client. The seat names the whole
/// step in one line. A row keeps the path or the command beside a shorter
/// word: present while the step runs, past once it has finished. A name
/// this list does not know stays as the tool wrote it. The permission
/// chip uses that same word. The Always allow line names the rule that
/// is stored, which is a command prefix or a tool name, never the chip.
enum SeatStep {
    static let detailCap = 32
    static let scanCap = 4096

    static func phrase(verb: String?, target: String?) -> String {
        let name = trimVerb(verb)
        let line = firstLine(scan(target))
        let collapsed = collapse(line)
        switch name {
        case "Read":
            return labeled("Reading", fileName(line))
        case "Write":
            return labeled("Writing", fileName(line))
        case "Edit", "NotebookEdit":
            return labeled("Editing", fileName(line))
        case "Diff":
            return labeled("Comparing", fileName(line))
        case "Shell", "Bash":
            return labeled("Running", collapsed)
        case "Grep", "Search":
            return labeled("Searching", collapsed)
        case "Glob", "Find":
            let file = fileName(line)
            if file.isEmpty { return "Looking" }
            return labeled("Looking through", file)
        case "WebFetch":
            return labeled("Opening", site(collapsed))
        case "WebSearch":
            return "Searching the web"
        case "Task", "Subagent":
            return "Asking another agent"
        case "TodoWrite":
            return "Updating the list"
        default:
            // A path with nothing left after the slashes is just work.
            // "Working on" with an empty name reads as a broken sentence.
            let edges = trimEdges(line)
            if edges.contains("/") || edges.contains("\\") {
                let file = fileName(line)
                if file.isEmpty { return "Working" }
                return labeled("Working on", file)
            }
            if collapsed.isEmpty { return "Working" }
            return labeled("Working on", collapsed)
        }
    }

    /// Waiting wins. A real step is shown as written. Speaking is a reply.
    /// Everything else is thought.
    static func seatLabel(waiting: Bool, step: String?, speaking: Bool) -> String {
        if waiting { return "Waiting" }
        if let step, !step.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return step
        }
        if speaking { return "Replying" }
        return "Thinking"
    }

    /// Present while the step runs, past once it has finished.
    /// An unknown name is returned unchanged, once trimmed.
    static func word(verb: String?, running: Bool) -> String {
        switch trimVerb(verb) {
        case "Read": return running ? "Reading" : "Read"
        case "Write": return running ? "Writing" : "Wrote"
        case "Edit", "NotebookEdit": return running ? "Editing" : "Edited"
        case "Diff": return running ? "Comparing" : "Compared"
        case "Shell", "Bash": return running ? "Running" : "Ran"
        case "Grep", "Search": return running ? "Searching" : "Searched"
        case "Glob", "Find": return running ? "Looking" : "Looked"
        case "WebFetch": return running ? "Opening" : "Opened"
        case "WebSearch": return running ? "Searching the web" : "Searched the web"
        case "Task", "Subagent": return running ? "Asking another agent" : "Asked another agent"
        case "TodoWrite": return running ? "Updating the list" : "Updated the list"
        case "": return running ? "Working" : "Worked"
        case let name: return name
        }
    }

    /// The running word already says what is happening, so a Running chip
    /// beside it would repeat the same news.
    static func speaks(verb: String?) -> Bool {
        let name = trimVerb(verb)
        return word(verb: name, running: true) != name
    }

    /// The chip on a permission card. Pending is present tense, a decision
    /// is past tense, and a blank name stays Approval.
    static func approvalWord(verb: String?, pending: Bool) -> String {
        let name = trimVerb(verb)
        if name.isEmpty { return "Approval" }
        return word(verb: name, running: pending)
    }

    /// What Always allow will store for the rest of this chat.
    /// A command prefix is that prefix. A plain tool is its own name.
    /// A command with no safe prefix is not stored, so the line says so
    /// instead of naming the tool.
    static func allowAlwaysNote(verb: String?, shellPrefix: String?) -> String? {
        let prefix = trimVerb(shellPrefix)
        if !prefix.isEmpty {
            return "Always allow remembers \(prefix) for this chat only."
        }
        if isShell(verb: verb) {
            return "Always allow answers this request only. Nothing is saved for later."
        }
        let name = trimVerb(verb)
        if name.isEmpty { return nil }
        return "Always allow remembers \(name) for this chat only."
    }

    /// Same rule as the host: a shell tool is never remembered by its name.
    static func isShell(verb: String?) -> Bool {
        let name = trimVerb(verb).lowercased()
        if name.contains("bash") || name.contains("shell")
            || name.contains("command") || name.contains("terminal")
        {
            return true
        }
        var token = ""
        for character in name {
            if character.isASCII, character.isLetter || character.isNumber {
                token.append(character)
            } else if token == "sh" || token == "zsh" || token == "exec" || token == "run" {
                return true
            } else {
                token = ""
            }
        }
        return token == "sh" || token == "zsh" || token == "exec" || token == "run"
    }

    private static func trimVerb(_ verb: String?) -> String {
        verb?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }

    private static func scan(_ target: String?) -> String {
        guard let target, !target.isEmpty else { return "" }
        return String(target.prefix(scanCap))
    }

    private static func firstLine(_ text: String) -> String {
        guard let range = text.rangeOfCharacter(from: CharacterSet(charactersIn: "\r\n")) else {
            return text
        }
        return String(text[..<range.lowerBound])
    }

    /// Space and tab only. A newline is already gone, and other whitespace
    /// stays so a name is not quietly rewritten.
    private static func trimEdges(_ text: String) -> String {
        var start = text.startIndex
        var end = text.endIndex
        while start < end, text[start] == " " || text[start] == "\t" {
            start = text.index(after: start)
        }
        while end > start {
            let previous = text.index(before: end)
            if text[previous] != " " && text[previous] != "\t" { break }
            end = previous
        }
        return String(text[start..<end])
    }

    private static func collapse(_ line: String) -> String {
        let trimmed = trimEdges(line)
        var out = ""
        var pending = false
        for character in trimmed {
            if character == " " || character == "\t" {
                pending = true
                continue
            }
            if pending, !out.isEmpty { out.append(" ") }
            pending = false
            out.append(character)
        }
        return out
    }

    private static func fileName(_ line: String) -> String {
        var name = trimEdges(line)
        while let last = name.last, last == "/" || last == "\\" {
            name.removeLast()
        }
        guard !name.isEmpty else { return "" }
        let slash = name.lastIndex(of: "/")
        let back = name.lastIndex(of: "\\")
        let cut: String.Index?
        switch (slash, back) {
        case let (left?, right?):
            cut = left > right ? left : right
        case let (left?, nil):
            cut = left
        case let (nil, right?):
            cut = right
        default:
            cut = nil
        }
        guard let cut else { return name }
        return String(name[name.index(after: cut)...])
    }

    private static func clip(_ detail: String) -> String {
        if detail.count <= detailCap { return detail }
        return String(detail.prefix(detailCap - 1)) + "…"
    }

    private static func labeled(_ gerund: String, _ detail: String) -> String {
        if detail.isEmpty { return gerund }
        return gerund + " " + clip(detail)
    }

    private static func site(_ collapsed: String) -> String {
        if collapsed.isEmpty { return "" }
        var host = collapsed
        if let marker = host.range(of: "://") {
            host = String(host[marker.upperBound...])
        }
        if let cut = host.rangeOfCharacter(from: CharacterSet(charactersIn: "/?#")) {
            host = String(host[..<cut.lowerBound])
        }
        if let at = host.lastIndex(of: "@") {
            host = String(host[host.index(after: at)...])
        }
        host = stripPort(host)
        if host.isEmpty { return clip(collapsed) }
        return clip(host)
    }

    private static func stripPort(_ host: String) -> String {
        if host.hasPrefix("[") {
            guard let close = host.firstIndex(of: "]") else { return host }
            let suffix = host[host.index(after: close)...]
            if suffix.first == ":", isAsciiDigits(suffix.dropFirst()) {
                return String(host[...close])
            }
            return host
        }
        guard let colon = host.lastIndex(of: ":") else { return host }
        if isAsciiDigits(host[host.index(after: colon)...]) {
            return String(host[..<colon])
        }
        return host
    }

    private static func isAsciiDigits(_ text: Substring) -> Bool {
        var any = false
        for character in text {
            let scalars = character.unicodeScalars
            guard scalars.count == 1, let value = scalars.first?.value, value >= 48, value <= 57 else {
                return false
            }
            any = true
        }
        return any
    }
}
