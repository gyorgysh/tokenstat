// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
package ai.tokenstat.tokenstat.ui.workspace

import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.add
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.put
import kotlinx.serialization.json.putJsonArray
import kotlinx.serialization.json.putJsonObject
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test

class HostWorkspacesTest {
    @Test
    fun harnessFromCommand() {
        assertEquals("claude_code", harnessIdForCommand("/Users/gyorgy/.local/bin/claude"))
        assertEquals("opencode", harnessIdForCommand("/Users/gyorgy/.opencode/bin/opencode2"))
        assertEquals("codex", harnessIdForCommand("codex"))
        assertNull(harnessIdForCommand("/bin/zsh"))
        assertNull(harnessIdForCommand(""))
    }

    @Test
    fun folderSubtitleSummarizesGit() {
        val repo = buildJsonObject {
            put("exists", true)
            putJsonObject("git") {
                put("isRepo", true)
                put("branch", "main")
                put("ahead", 2)
                put("behind", 0)
                put("added", 11)
                put("removed", 28)
                put("partial", false)
                putJsonArray("files") { add(JsonPrimitive("a")); add(JsonPrimitive("b")) }
            }
        }
        assertEquals("main ⇡2 +11 −28", folderSubtitle(repo))
        assertEquals("Folder missing", folderSubtitle(buildJsonObject { put("exists", false) }))
        assertEquals("Not a git repo", folderSubtitle(buildJsonObject { put("exists", true) }))
        assertNull(
            folderSubtitle(
                buildJsonObject {
                    put("exists", true)
                    putJsonObject("git") {
                        put("isRepo", true)
                        put("branch", "")
                        put("ahead", 0)
                        put("behind", 0)
                        putJsonArray("files") {}
                    }
                },
            ),
        )
    }
}
