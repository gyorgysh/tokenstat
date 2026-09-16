// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
package ai.tokenstat.tokenstat.ui.workspace

import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.BatteryAlert
import androidx.compose.material.icons.filled.BatteryChargingFull
import androidx.compose.material.icons.filled.BatteryFull
import androidx.compose.material.icons.filled.BatteryStd
import androidx.compose.material.icons.filled.Bolt
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.add
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.put
import kotlinx.serialization.json.putJsonArray
import kotlinx.serialization.json.putJsonObject
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertSame
import org.junit.Test

class HostWorkspacesTest {
    @Test
    fun harnessFromCommand() {
        assertEquals("claude_code", harnessIdForCommand("/home/someone/.local/bin/claude"))
        assertEquals("opencode", harnessIdForCommand("/home/someone/.opencode/bin/opencode2"))
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

    @Test
    fun pathsTruncateInTheMiddle() {
        assertEquals("/a/b", middleTruncate("/a/b"))
        val long = "/home/someone/git/some-very-long-project-name/src/main"
        val cut = middleTruncate(long, 24)
        assertEquals(24, cut.length)
        assertEquals(true, cut.startsWith("/home/someone/g"))
        assertEquals(true, cut.endsWith("rc/main"))
        assertEquals(true, "…" in cut)
    }

    @Test
    fun powerIconsMatchReading() {
        assertSame(Icons.Default.BatteryChargingFull, powerIconVector(true, 10, "battery"))
        assertSame(Icons.Default.Bolt, powerIconVector(false, null, "ac"))
        assertSame(Icons.Default.BatteryFull, powerIconVector(false, 95, "battery"))
        assertSame(Icons.Default.BatteryStd, powerIconVector(false, 50, "battery"))
        assertSame(Icons.Default.BatteryAlert, powerIconVector(false, 5, "battery"))
        assertSame(Icons.Default.Bolt, powerIconVector(false, null, null))
    }
}
