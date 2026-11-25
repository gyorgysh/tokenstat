// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
package ai.tokenstat.tokenstat.ui.logic

import java.io.File
import java.nio.file.Files
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class ChatDraftFilesTest {
    private val folder: File = Files.createTempDirectory("drafts").toFile()

    private fun kept() = folder.list()?.count { it.endsWith(".txt") }

    private fun settle(done: () -> Boolean) {
        val end = System.currentTimeMillis() + 5_000
        while (!done() && System.currentTimeMillis() < end) Thread.sleep(10)
        assertTrue(done())
    }

    @Test fun aNewLaunchReadsTheUnsentText() {
        val first = ChatDraftFiles(folder, delayMs = 0)
        first.write("owner", "half a thought 🙂")
        settle { kept() == 1 }
        val second = ChatDraftFiles(folder)
        assertTrue(second.has("owner"))
        assertEquals("half a thought 🙂", second.read("owner"))
        assertFalse(second.has("another account"))
    }

    @Test fun sendingLeavesNothingBehindAndCannotComeBack() {
        val files = ChatDraftFiles(folder, delayMs = 60_000)
        files.write("owner", "words")
        assertEquals("words", files.read("owner"))
        files.write("owner", "")
        assertEquals("", files.read("owner"))
        assertFalse(files.has("owner"))
        settle { folder.list()?.isEmpty() == true }
    }

    @Test fun leavingTheScreenWritesWhatWasWaiting() {
        val files = ChatDraftFiles(folder, delayMs = 60_000)
        files.write("owner", "typed just now")
        files.flush()
        settle { kept() == 1 }
        assertEquals("typed just now", ChatDraftFiles(folder).read("owner"))
    }

    @Test fun theOldestDraftsMakeRoom() {
        val files = ChatDraftFiles(folder, capacity = 3, delayMs = 0)
        repeat(6) { files.write("owner$it", "text") }
        settle { files.has("owner5") && kept() == 3 }
    }

    @Test fun aComposerStartsFromTheKeptTextOnce() {
        ChatDraftFiles(folder, delayMs = 0).write("owner", "kept")
        settle { kept() == 1 }
        val composers = ChatComposerSessions<String>({ 0 }, saved = ChatDraftFiles(folder, delayMs = 0))
        assertTrue(composers.hasWriting("owner"))
        assertEquals("kept", composers.snapshot("owner").text)
        val sent = composers.capture("owner")
        assertTrue(composers.clearIfUnchanged("owner", sent))
        assertEquals("", composers.snapshot("owner").text)
        settle { folder.list()?.isEmpty() == true }
    }
}
