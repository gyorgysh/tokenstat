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
            return labeled(L10n.text("apple.seatstep.reading.463816d0"), fileName(line))
        case "Write":
            return labeled(L10n.text("apple.seatstep.writing.a8bfae3e"), fileName(line))
        case "Edit", "NotebookEdit":
            return labeled(L10n.text("apple.seatstep.editing.fab4539d"), fileName(line))
        case "Diff":
            return labeled(L10n.text("apple.seatstep.comparing.1fa1aad0"), fileName(line))
        case "Shell", "Bash":
            return labeled(L10n.text("common.running"), collapsed)
        case "Grep", "Search":
            return labeled(L10n.text("apple.seatstep.searching.03bd6fca"), collapsed)
        case "Glob", "Find":
            let file = fileName(line)
            if file.isEmpty { return L10n.text("apple.seatstep.looking.afa37c88") }
            return labeled(L10n.text("apple.seatstep.looking_through.6c8d5b7b"), file)
        case "WebFetch":
            return labeled(L10n.text("apple.seatstep.opening.f4b13e93"), site(collapsed))
        case "WebSearch":
            return L10n.text("apple.seatstep.searching_the_web.87d2f338")
        case "Task", "Subagent":
            return L10n.text("apple.seatstep.asking_another_agent.fde5ee73")
        case "TodoWrite":
            return L10n.text("apple.seatstep.updating_the_list.ca724dcc")
        default:
            // A path with nothing left after the slashes is just work.
            // "Working on" with an empty name reads as a broken sentence.
            let edges = trimEdges(line)
            if edges.contains("/") || edges.contains("\\") {
                let file = fileName(line)
                if file.isEmpty { return L10n.text("common.working") }
                return labeled(L10n.text("apple.seatstep.working_on.006abaf3"), file)
            }
            if collapsed.isEmpty { return L10n.text("common.working") }
            return labeled(L10n.text("apple.seatstep.working_on.006abaf3"), collapsed)
        }
    }

    /// Waiting wins. A real step is shown as written. Speaking is a reply.
    /// Everything else is thought.
    static func seatLabel(waiting: Bool, step: String?, speaking: Bool) -> String {
        if waiting { return L10n.text("common.waiting") }
        if let step, !step.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return step
        }
        if speaking { return L10n.text("apple.seatstep.replying.b2663dd7") }
        return L10n.text("apple.seatstep.thinking.a20d12c5")
    }

    /// Present while the step runs, past once it has finished.
    /// An unknown name is returned unchanged, once trimmed.
    static func word(verb: String?, running: Bool) -> String {
        switch trimVerb(verb) {
        case "Read": return running ? L10n.text("apple.seatstep.reading.463816d0") : L10n.text("apple.seatstep.read.9b9a8d05")
        case "Write": return running ? L10n.text("apple.seatstep.writing.a8bfae3e") : L10n.text("apple.seatstep.wrote.42717062")
        case "Edit", "NotebookEdit": return running ? L10n.text("apple.seatstep.editing.fab4539d") : L10n.text("apple.seatstep.edited.7117f080")
        case "Diff": return running ? L10n.text("apple.seatstep.comparing.1fa1aad0") : L10n.text("apple.seatstep.compared.17c858fc")
        case "Shell", "Bash": return running ? L10n.text("common.running") : L10n.text("apple.seatstep.ran.b6a7c95e")
        case "Grep", "Search": return running ? L10n.text("apple.seatstep.searching.03bd6fca") : L10n.text("apple.seatstep.searched.9fc7f116")
        case "Glob", "Find": return running ? L10n.text("apple.seatstep.looking.afa37c88") : L10n.text("apple.seatstep.looked.07558310")
        case "WebFetch": return running ? L10n.text("apple.seatstep.opening.f4b13e93") : L10n.text("apple.seatstep.opened.b19fb8d1")
        case "WebSearch": return running ? L10n.text("apple.seatstep.searching_the_web.87d2f338") : L10n.text("apple.seatstep.searched_the_web.7d2580ce")
        case "Task", "Subagent": return running ? L10n.text("apple.seatstep.asking_another_agent.fde5ee73") : L10n.text("apple.seatstep.asked_another_agent.629f8e22")
        case "TodoWrite": return running ? L10n.text("apple.seatstep.updating_the_list.ca724dcc") : L10n.text("apple.seatstep.updated_the_list.de8e6fab")
        case "": return running ? L10n.text("common.working") : L10n.text("apple.seatstep.worked.e7f93aad")
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
        if name.isEmpty { return L10n.text("apple.seatstep.approval.147fb813") }
        return word(verb: name, running: pending)
    }

    /// What Always allow will store for the rest of this chat.
    /// A command prefix is that prefix. A plain tool is its own name.
    /// A command with no safe prefix is not stored, so the line says so
    /// instead of naming the tool.
    static func allowAlwaysNote(verb: String?, shellPrefix: String?) -> String? {
        let prefix = trimVerb(shellPrefix)
        if !prefix.isEmpty {
            return L10n.text("apple.seatstep.always_allow_remembers_0_for_this_chat_onl.394a9e6d", "\(prefix)")
        }
        if isShell(verb: verb) {
            return L10n.text("apple.seatstep.always_allow_answers_this_request_only_not.a067a2b7")
        }
        let name = trimVerb(verb)
        if name.isEmpty { return nil }
        return L10n.text("apple.seatstep.always_allow_remembers_0_for_this_chat_onl.394a9e6d", "\(name)")
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
