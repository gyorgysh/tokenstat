// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
package ai.tokenstat.tokenstat.ui.logic

import org.junit.Assert.*
import org.junit.Test

class ChatComposerSessionsTest {
    @Test fun accountHostProjectAndChatOwnershipCannotShareWriting() {
        fun account(server: String = "https://example.test", handle: String = "ada") = kotlinx.serialization.json.buildJsonObject {
            put("signedIn", kotlinx.serialization.json.JsonPrimitive(true))
            put("host", kotlinx.serialization.json.JsonPrimitive(server))
            put("handle", kotlinx.serialization.json.JsonPrimitive(handle))
        }
        val store = ChatComposerSessions<String>({ it.length.toLong() })
        val original = ProjectOwner.from(account(), "computer", "project")!!.conversation("chat")!!
        store.update(original, ChatComposerSessions.Snapshot("private draft", listOf("private file")))
        val different = listOf(
            ProjectOwner.from(account(handle = "grace"), "computer", "project")!!.conversation("chat"),
            ProjectOwner.from(account(server = "https://other.test"), "computer", "project")!!.conversation("chat"),
            ProjectOwner.from(account(), "another-computer", "project")!!.conversation("chat"),
            ProjectOwner.from(account(), "computer", "another-project")!!.conversation("chat"),
            ProjectOwner.from(account(), "computer", "project")!!.conversation("another-chat"),
        )
        different.forEach { assertTrue(store.snapshot(it).empty) }
        assertEquals("private draft", store.snapshot(original).text)
    }
    @Test fun twoChatsKeepTextAndFilesAcrossBackAndScreenDisposal() {
        val store = ChatComposerSessions<String>({ it.length.toLong() })
        var firstText by store.text("account/host/project/chat-a")
        var firstFiles by store.attachments("account/host/project/chat-a")
        firstText = "unfinished first"
        firstFiles = listOf("photo")
        var secondText by store.text("account/host/project/chat-b")
        var secondFiles by store.attachments("account/host/project/chat-b")
        assertEquals("", secondText)
        assertTrue(secondFiles.isEmpty())
        secondText = "unfinished second"
        secondFiles = listOf("report")
        // A new screen acquires fresh delegates from the retained ViewModel store.
        var restored by store.text("account/host/project/chat-a")
        var restoredFiles by store.attachments("account/host/project/chat-a")
        assertEquals("unfinished first", restored)
        assertEquals(listOf("photo"), restoredFiles)
        assertEquals("unfinished second", secondText)
        assertEquals(listOf("report"), secondFiles)
    }

    @Test fun acknowledgementCannotClearAnotherChatOrNewAttachments() {
        val store = ChatComposerSessions<String>({ it.length.toLong() })
        val sent = ChatComposerSessions.Snapshot("same words", listOf("first file"))
        store.update("a", sent)
        store.update("b", sent)
        val acknowledged = store.capture("a")
        assertTrue(store.clearIfUnchanged("a", acknowledged))
        assertEquals(sent, store.snapshot("b"))
        store.update("a", sent.copy(attachments = listOf("new file")))
        assertFalse(store.clearIfUnchanged("a", acknowledged))
        assertEquals(listOf("new file"), store.snapshot("a").attachments)
        store.update("a", sent)
        assertFalse(store.clearIfUnchanged("a", acknowledged)) // identical newly written payload
    }

    @Test fun capacityRefusalPreservesWritingAndClearingReleasesSpace() {
        val store = ChatComposerSessions<String>({ it.length.toLong() }, capacity = 1, byteLimit = 20)
        val first = ChatComposerSessions.Snapshot("keep", listOf("file"))
        assertTrue(store.update("a", first))
        assertFalse(store.update("b", ChatComposerSessions.Snapshot("second")))
        assertEquals("b", store.failure.value?.owner)
        assertEquals(first, store.snapshot("a"))
        assertFalse(store.update("a", first.copy(attachments = listOf("a file too large for the remaining memory"))))
        assertEquals(first, store.snapshot("a"))
        assertTrue(store.clearIfUnchanged("a", store.capture("a")))
        assertTrue(store.update("b", ChatComposerSessions.Snapshot("second")))
    }

    @Test fun draftsAndPendingNotesRemainVisibleInUnusedChatFilter() {
        assertFalse(UntouchedChats.isUntouched("New chat", null, false, "a", hasWriting = true))
        assertFalse(UntouchedChats.isUntouched("New chat", null, false, "a", hasPending = true))
        assertTrue(UntouchedChats.isUntouched("New chat", null, false, "a"))
    }
}
