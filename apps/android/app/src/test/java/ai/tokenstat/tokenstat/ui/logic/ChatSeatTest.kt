// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
package ai.tokenstat.tokenstat.ui.logic

import org.junit.Assert.assertEquals
import org.junit.Test

/// The live seat uses the same sentences on every client.
class ChatSeatTest {
    private fun phrase(verb: String?, target: String?, expected: String) {
        assertEquals(expected, ChatSeat.phrase(verb, target))
    }

    @Test
    fun `a read names the file`() {
        phrase("Read", "src/App.swift", "Reading App.swift")
    }

    @Test
    fun `a write names the file`() {
        phrase("Write", "a/b.txt", "Writing b.txt")
    }

    @Test
    fun `a trailing slash is not the name`() {
        phrase("Edit", "src/dir/", "Editing dir")
    }

    @Test
    fun `a notebook edit names the file`() {
        phrase("NotebookEdit", "notes/n.ipynb", "Editing n.ipynb")
    }

    @Test
    fun `a diff names the file`() {
        phrase("Diff", "a/b", "Comparing b")
    }

    @Test
    fun `a tab in a command becomes a space`() {
        phrase("Shell", "cargo\ttest", "Running cargo test")
    }

    @Test
    fun `bash is a command`() {
        phrase("Bash", "echo hi", "Running echo hi")
    }

    @Test
    fun `a command stops at the first line`() {
        phrase("Shell", "cargo test\nrm -rf", "Running cargo test")
    }

    @Test
    fun `a command drops surrounding space`() {
        phrase("Shell", "  ls  ", "Running ls")
    }

    @Test
    fun `a long command is clipped`() {
        phrase("Shell", "abcdefghijklmnopqrstuvwxyz0123456789", "Running abcdefghijklmnopqrstuvwxyz01234…")
    }

    @Test
    fun `thirty two characters stay whole`() {
        phrase("Shell", "abcdefghijklmnopqrstuvwxyz012345", "Running abcdefghijklmnopqrstuvwxyz012345")
    }

    @Test
    fun `thirty three characters clip`() {
        phrase("Shell", "abcdefghijklmnopqrstuvwxyz0123456", "Running abcdefghijklmnopqrstuvwxyz01234…")
    }

    @Test
    fun `grep names the query`() {
        phrase("Grep", "needle", "Searching needle")
    }

    @Test
    fun `search names the query`() {
        phrase("Search", "q", "Searching q")
    }

    @Test
    fun `an empty search is just looking`() {
        phrase("Glob", "   ", "Looking")
    }

    @Test
    fun `a name without a slash is still a name`() {
        phrase("Glob", "foo", "Looking through foo")
    }

    @Test
    fun `find names the file`() {
        phrase("Find", "src/x", "Looking through x")
    }

    @Test
    fun `a file name keeps its spaces`() {
        phrase("Glob", "dir/My  File.swift", "Looking through My  File.swift")
        phrase("Read", "dir/My  File.swift", "Reading My  File.swift")
    }

    @Test
    fun `a page names the site`() {
        phrase("WebFetch", "https://example.com/a?b=1", "Opening example.com")
        phrase("WebFetch", "http://[::1]:8080/x", "Opening [::1]")
        phrase("WebFetch", "http://user:pass@example.com/x", "Opening example.com")
        phrase("WebFetch", "https://", "Opening https://")
        phrase("WebFetch", "", "Opening")
        phrase("WebFetch", null, "Opening")
        phrase("WebFetch", "http://example.com:8080/a", "Opening example.com")
        phrase("WebFetch", "http://example.com:/a", "Opening example.com:")
        phrase("WebFetch", "http://a@b@example.com/x", "Opening example.com")
        phrase("WebFetch", "http://[::1]", "Opening [::1]")
        phrase("WebFetch", "example.com:１２", "Opening example.com:１２")
        phrase("WebFetch", "https://example.com?q=1", "Opening example.com")
        phrase("WebFetch", "https://example.com#top", "Opening example.com")
    }

    @Test
    fun `web search ignores the query`() {
        phrase("WebSearch", "anything", "Searching the web")
    }

    @Test
    fun `a task names no target`() {
        phrase("Task", "explore", "Asking another agent")
        phrase("Subagent", null, "Asking another agent")
        phrase("TodoWrite", "list", "Updating the list")
    }

    @Test
    fun `an unknown path names the file`() {
        phrase("Other", "src/App.swift", "Working on App.swift")
        phrase("read", "src/App.swift", "Working on App.swift")
        phrase("Read", "src\\App.swift", "Reading App.swift")
        phrase("Edit", "src\\dir\\", "Editing dir")
    }

    @Test
    fun `an unknown line is named`() {
        phrase("Other", "hello", "Working on hello")
    }

    @Test
    fun `nothing to name is just working`() {
        phrase(null, null, "Working")
        phrase("Other", "///", "Working")
        phrase(" Read ", "src/App.swift", "Reading App.swift")
        phrase("Shell", "cargo test\r\nrm -rf", "Running cargo test")
        phrase("Shell", "a  \t  b", "Running a b")
    }

    @Test
    fun `waiting wins and a step is shown as written`() {
        assertEquals("Waiting", ChatSeat.seatLabel(true, "Reading App.swift", true))
        assertEquals("Reading App.swift", ChatSeat.seatLabel(false, "Reading App.swift", false))
        assertEquals("  spaced  ", ChatSeat.seatLabel(false, "  spaced  ", true))
        assertEquals("Replying", ChatSeat.seatLabel(false, "   ", true))
        assertEquals("Replying", ChatSeat.seatLabel(false, null, true))
        assertEquals("Thinking", ChatSeat.seatLabel(false, "", false))
        assertEquals("Thinking", ChatSeat.seatLabel(false, null, false))
    }

    @Test
    fun `a tool row speaks in the present then the past`() {
        assertEquals("Reading", ChatSeat.word("Read", true))
        assertEquals("Read", ChatSeat.word("Read", false))
        assertEquals("Writing", ChatSeat.word("Write", true))
        assertEquals("Wrote", ChatSeat.word("Write", false))
        assertEquals("Editing", ChatSeat.word("Edit", true))
        assertEquals("Edited", ChatSeat.word("NotebookEdit", false))
        assertEquals("Comparing", ChatSeat.word("Diff", true))
        assertEquals("Compared", ChatSeat.word("Diff", false))
        assertEquals("Running", ChatSeat.word("Shell", true))
        assertEquals("Ran", ChatSeat.word("Bash", false))
        assertEquals("Searching", ChatSeat.word("Grep", true))
        assertEquals("Searched", ChatSeat.word("Search", false))
        assertEquals("Looking", ChatSeat.word("Glob", true))
        assertEquals("Looked", ChatSeat.word("Find", false))
        assertEquals("Opening", ChatSeat.word("WebFetch", true))
        assertEquals("Opened", ChatSeat.word("WebFetch", false))
        assertEquals("Searching the web", ChatSeat.word("WebSearch", true))
        assertEquals("Searched the web", ChatSeat.word("WebSearch", false))
        assertEquals("Asking another agent", ChatSeat.word("Task", true))
        assertEquals("Asked another agent", ChatSeat.word("Subagent", false))
        assertEquals("Updating the list", ChatSeat.word("TodoWrite", true))
        assertEquals("Updated the list", ChatSeat.word("TodoWrite", false))
        assertEquals("Working", ChatSeat.word(null, true))
        assertEquals("Worked", ChatSeat.word("", false))
        assertEquals("ApplyPatch", ChatSeat.word(" ApplyPatch ", true))
        assertEquals("bash", ChatSeat.word("bash", false))
        assertEquals(true, ChatSeat.speaks("Bash"))
        assertEquals(true, ChatSeat.speaks(" Read "))
        assertEquals(false, ChatSeat.speaks("ApplyPatch"))
        assertEquals(true, ChatSeat.speaks(null))
    }

    @Test
    fun `a permission chip speaks, and always allow names the stored rule`() {
        assertEquals("Reading", ChatSeat.approvalWord("Read", true))
        assertEquals("Read", ChatSeat.approvalWord("Read", false))
        assertEquals("Running", ChatSeat.approvalWord("Bash", true))
        assertEquals("Ran", ChatSeat.approvalWord("Bash", false))
        assertEquals("Approval", ChatSeat.approvalWord(null, true))
        assertEquals("Approval", ChatSeat.approvalWord("  ", false))
        assertEquals("ApplyPatch", ChatSeat.approvalWord(" ApplyPatch ", true))
        assertEquals(
            "Always allow remembers cargo test for this chat only.",
            ChatSeat.allowAlwaysNote("Bash", "cargo test"),
        )
        assertEquals(
            "Always allow remembers cargo test for this chat only.",
            ChatSeat.allowAlwaysNote("Read", "  cargo test  "),
        )
        assertEquals(
            "Always allow answers this request only. Nothing is saved for later.",
            ChatSeat.allowAlwaysNote("Bash", null),
        )
        assertEquals(
            "Always allow answers this request only. Nothing is saved for later.",
            ChatSeat.allowAlwaysNote("Bash", "  "),
        )
        assertEquals(
            "Always allow answers this request only. Nothing is saved for later.",
            ChatSeat.allowAlwaysNote("run_terminal_command", null),
        )
        assertEquals(
            "Always allow answers this request only. Nothing is saved for later.",
            ChatSeat.allowAlwaysNote("sh", null),
        )
        assertEquals(
            "Always allow remembers Read for this chat only.",
            ChatSeat.allowAlwaysNote("Read", null),
        )
        assertEquals(
            "Always allow remembers ApplyPatch for this chat only.",
            ChatSeat.allowAlwaysNote(" ApplyPatch ", null),
        )
        assertEquals(
            "Always allow remembers execute_turn for this chat only.",
            ChatSeat.allowAlwaysNote("execute_turn", null),
        )
        assertEquals(null, ChatSeat.allowAlwaysNote(null, null))
        assertEquals(false, ChatSeat.isShell("push"))
        assertEquals(true, ChatSeat.isShell("Run-Task"))
    }
}
