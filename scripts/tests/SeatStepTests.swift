// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
// Compile with SeatStep.swift using swiftc -parse-as-library, then run.
import Foundation

@main
struct SeatStepTests {
    static func require(_ condition: Bool, _ message: String) {
        precondition(condition, message)
    }

    static func phrase(_ verb: String?, _ target: String?, _ expected: String, _ message: String) {
        require(SeatStep.phrase(verb: verb, target: target) == expected, message)
    }

    static func main() {
        phrase("Read", "src/App.swift", "Reading App.swift", "read names the file")
        phrase("Write", "a/b.txt", "Writing b.txt", "write names the file")
        phrase("Edit", "src/dir/", "Editing dir", "a trailing slash is not the name")
        phrase("NotebookEdit", "notes/n.ipynb", "Editing n.ipynb", "a notebook edit names the file")
        phrase("Diff", "a/b", "Comparing b", "a diff names the file")
        phrase("Shell", "cargo\ttest", "Running cargo test", "a tab in a command becomes a space")
        phrase("Bash", "echo hi", "Running echo hi", "bash is a command")
        phrase("Shell", "cargo test\nrm -rf", "Running cargo test", "a command stops at the first line")
        phrase("Shell", "  ls  ", "Running ls", "a command drops surrounding space")
        phrase("Shell", "abcdefghijklmnopqrstuvwxyz0123456789", "Running abcdefghijklmnopqrstuvwxyz01234…", "a long command is clipped")
        phrase("Shell", "abcdefghijklmnopqrstuvwxyz012345", "Running abcdefghijklmnopqrstuvwxyz012345", "thirty two characters stay whole")
        phrase("Shell", "abcdefghijklmnopqrstuvwxyz0123456", "Running abcdefghijklmnopqrstuvwxyz01234…", "thirty three characters clip")
        phrase("Grep", "needle", "Searching needle", "grep names the query")
        phrase("Search", "q", "Searching q", "search names the query")
        phrase("Glob", "   ", "Looking", "an empty search is just looking")
        phrase("Glob", "foo", "Looking through foo", "a name without a slash is still a name")
        phrase("Find", "src/x", "Looking through x", "find names the file")
        phrase("Glob", "dir/My  File.swift", "Looking through My  File.swift", "a file name keeps its spaces")
        phrase("WebFetch", "https://example.com/a?b=1", "Opening example.com", "a page names the site")
        phrase("WebFetch", "http://[::1]:8080/x", "Opening [::1]", "an address drops its port")
        phrase("WebFetch", "http://user:pass@example.com/x", "Opening example.com", "a page drops the login")
        phrase("WebFetch", "https://", "Opening https://", "a bare scheme stays visible")
        phrase("WebFetch", "", "Opening", "an empty page is just opening")
        phrase("WebFetch", nil, "Opening", "a missing page is just opening")
        phrase("WebSearch", "anything", "Searching the web", "web search ignores the query")
        phrase("WebFetch", "http://example.com:8080/a", "Opening example.com", "a numeric port is dropped")
        phrase("WebFetch", "http://example.com:/a", "Opening example.com:", "an empty port stays")
        phrase("WebFetch", "http://a@b@example.com/x", "Opening example.com", "the last login mark wins")
        phrase("WebFetch", "http://[::1]", "Opening [::1]", "an address without a port stays")
        phrase("WebFetch", "example.com:１２", "Opening example.com:１２", "a non ascii port stays")
        phrase("WebFetch", "https://example.com?q=1", "Opening example.com", "a query is not part of the site")
        phrase("WebFetch", "https://example.com#top", "Opening example.com", "a fragment is not part of the site")
        phrase("Task", "explore", "Asking another agent", "a task names no target")
        phrase("Subagent", nil, "Asking another agent", "a subagent names no target")
        phrase("TodoWrite", "list", "Updating the list", "a list update names no item")
        phrase("Read", "dir/My  File.swift", "Reading My  File.swift", "a read keeps spaces in the name")
        phrase("Read", "src\\App.swift", "Reading App.swift", "a windows path names the file")
        phrase("Edit", "src\\dir\\", "Editing dir", "a trailing backslash is not the name")
        phrase("Other", "src/App.swift", "Working on App.swift", "an unknown path names the file")
        phrase("read", "src/App.swift", "Working on App.swift", "a lowercase verb is not a read")
        phrase("Other", "hello", "Working on hello", "an unknown line is named")
        phrase(nil, nil, "Working", "nothing to name is just working")
        phrase(" Read ", "src/App.swift", "Reading App.swift", "a verb keeps its meaning once trimmed")
        phrase("Other", "///", "Working", "slashes alone are just working")
        phrase("Shell", "cargo test\r\nrm -rf", "Running cargo test", "a return ends the command")
        phrase("Shell", "a  \t  b", "Running a b", "runs of space collapse")

        require(SeatStep.seatLabel(waiting: true, step: "Reading App.swift", speaking: true) == "Waiting", "waiting wins")
        require(SeatStep.seatLabel(waiting: false, step: "Reading App.swift", speaking: false) == "Reading App.swift", "a step is shown as written")
        require(SeatStep.seatLabel(waiting: false, step: "  spaced  ", speaking: true) == "  spaced  ", "a step keeps its own spaces")
        require(SeatStep.seatLabel(waiting: false, step: "   ", speaking: true) == "Replying", "blank space is not a step")
        require(SeatStep.seatLabel(waiting: false, step: nil, speaking: true) == "Replying", "speech with no step is a reply")
        require(SeatStep.seatLabel(waiting: false, step: "", speaking: false) == "Thinking", "an empty step is thought")
        require(SeatStep.seatLabel(waiting: false, step: nil, speaking: false) == "Thinking", "nothing running is thought")

        func word(_ verb: String?, _ running: Bool, _ expected: String, _ message: String) {
            require(SeatStep.word(verb: verb, running: running) == expected, message)
        }
        word("Read", true, "Reading", "a read in progress")
        word("Read", false, "Read", "a finished read")
        word("Write", true, "Writing", "a write in progress")
        word("Write", false, "Wrote", "a finished write")
        word("Edit", true, "Editing", "an edit in progress")
        word("NotebookEdit", false, "Edited", "a finished notebook edit")
        word("Diff", true, "Comparing", "a diff in progress")
        word("Diff", false, "Compared", "a finished diff")
        word("Shell", true, "Running", "a command in progress")
        word("Bash", false, "Ran", "a finished command")
        word("Grep", true, "Searching", "a search in progress")
        word("Search", false, "Searched", "a finished search")
        word("Glob", true, "Looking", "a file search in progress")
        word("Find", false, "Looked", "a finished file search")
        word("WebFetch", true, "Opening", "a page in progress")
        word("WebFetch", false, "Opened", "a finished page")
        word("WebSearch", true, "Searching the web", "a web search in progress")
        word("WebSearch", false, "Searched the web", "a finished web search")
        word("Task", true, "Asking another agent", "another agent in progress")
        word("Subagent", false, "Asked another agent", "a finished request to another agent")
        word("TodoWrite", true, "Updating the list", "a list in progress")
        word("TodoWrite", false, "Updated the list", "a finished list")
        word(nil, true, "Working", "an unnamed step in progress")
        word("", false, "Worked", "a finished unnamed step")
        word(" ApplyPatch ", true, "ApplyPatch", "an unknown name stays")
        word("bash", false, "bash", "a lowercase name stays")
        require(SeatStep.speaks(verb: "Bash"), "a command already says it is running")
        require(SeatStep.speaks(verb: " Read "), "a trimmed read already says it is reading")
        require(!SeatStep.speaks(verb: "ApplyPatch"), "an unknown name still needs the chip")
        require(SeatStep.speaks(verb: nil), "an unnamed step already says it is working")

        func approval(_ verb: String?, _ pending: Bool, _ expected: String, _ message: String) {
            require(SeatStep.approvalWord(verb: verb, pending: pending) == expected, message)
        }
        approval("Read", true, "Reading", "a pending read")
        approval("Read", false, "Read", "a decided read")
        approval("Bash", true, "Running", "a pending command")
        approval("Bash", false, "Ran", "a decided command")
        approval(nil, true, "Approval", "a blank request stays Approval")
        approval("  ", false, "Approval", "spaces are still a blank request")
        approval(" ApplyPatch ", true, "ApplyPatch", "an unknown permission keeps its name")

        func note(_ verb: String?, _ prefix: String?, _ expected: String?, _ message: String) {
            require(SeatStep.allowAlwaysNote(verb: verb, shellPrefix: prefix) == expected, message)
        }
        note("Bash", "cargo test", "Always allow remembers cargo test for this chat only.", "a command prefix is what is saved")
        note("Read", "  cargo test  ", "Always allow remembers cargo test for this chat only.", "a prefix is trimmed, then kept")
        note("Bash", nil, "Always allow answers this request only. Nothing is saved for later.", "a command with no prefix is not saved")
        note("Bash", "  ", "Always allow answers this request only. Nothing is saved for later.", "a blank prefix is no prefix")
        note("run_terminal_command", nil, "Always allow answers this request only. Nothing is saved for later.", "a compound command name is still a command")
        note("sh", nil, "Always allow answers this request only. Nothing is saved for later.", "a short shell name is a command")
        note("Read", nil, "Always allow remembers Read for this chat only.", "a plain tool is remembered by its name")
        note(" ApplyPatch ", nil, "Always allow remembers ApplyPatch for this chat only.", "an unknown tool keeps the trimmed name")
        note("execute_turn", nil, "Always allow remembers execute_turn for this chat only.", "execute inside a longer word is not a command")
        note(nil, nil, nil, "nothing to remember says nothing")
        require(SeatStep.isShell(verb: "push") == false, "push is not a command")
        require(SeatStep.isShell(verb: "Run-Task"), "run as its own word is a command")

        print("SeatStepTests passed.")
    }
}
