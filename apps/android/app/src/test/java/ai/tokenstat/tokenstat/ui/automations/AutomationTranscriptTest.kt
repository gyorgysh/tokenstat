// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
package ai.tokenstat.tokenstat.ui.automations

import org.junit.Assert.assertEquals
import org.junit.Test

class AutomationTranscriptTest {
    @Test
    fun toolParagraphsBecomeToolsWithTheirSnippets() {
        val blocks = RunTranscriptParser.parse(
            "Looking at the repo.\n\n17:29:15 Bash cargo test\n| ok\n| done\nAll green.\n\nEdit src/a.rs\n+ new\n- old",
        )
        assertEquals(
            listOf(
                RunTranscriptBlock.Text("Looking at the repo."),
                RunTranscriptBlock.Tool("Bash", "cargo test", listOf("| ok", "| done"), "17:29:15"),
                RunTranscriptBlock.Text("All green."),
                RunTranscriptBlock.Tool("Edit", "src/a.rs", listOf("+ new", "- old"), null),
            ),
            blocks,
        )
    }

    @Test
    fun aSentenceStartingWithAVerbStaysProse() {
        assertEquals(
            listOf(RunTranscriptBlock.Text("Read the docs first. Then build.")),
            RunTranscriptParser.parse("Read the docs first. Then build."),
        )
        assertEquals(emptyList<RunTranscriptBlock>(), RunTranscriptParser.parse(""))
    }
}
