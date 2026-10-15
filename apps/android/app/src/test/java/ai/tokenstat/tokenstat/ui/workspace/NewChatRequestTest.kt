// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
package ai.tokenstat.tokenstat.ui.workspace

import ai.tokenstat.tokenstat.ui.logic.ChatComposerSessions
import org.junit.Assert.*
import org.junit.Test
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.jsonObject

class NewChatRequestTest {
    @Test fun emptyExplicitOpenCanClaimCreationWithoutSendingAModelPrompt() {
        val drafts = ChatComposerSessions<StagedAttachment>({ it.bytes.toLong() })
        for (text in listOf("", " \n ")) {
            drafts.update("account|new-chat", ChatComposerSessions.Snapshot(text))
            val request = NewChatRequest("host", "repository", "account", drafts.capture("account|new-chat"))
            assertTrue(request.claim("account", "host", "repository"))
            assertFalse(request.shouldSend)
        }
        drafts.update("landing", ChatComposerSessions.Snapshot("Review this"))
        assertTrue(NewChatRequest("host", "repository", "account", drafts.capture("landing")).shouldSend)
    }
    @Test fun capturedAgentAndModelMustStillBeAvailableBeforeCreation() {
        fun descriptor(value: String) = listOf(Json.parseToJsonElement(value).jsonObject)
        val setup = NewChatSetup("codex", "model", "high")
        assertTrue(setup.isAvailable(descriptor("""{"id":"codex","models":["model"],"efforts":["high"]}""")))
        for (value in listOf("""{"id":"claude","models":["model"],"efforts":["high"]}""", """{"id":"codex","installed":false,"models":["model"],"efforts":["high"]}""", """{"id":"codex","models":["other"],"efforts":["high"]}""", """{"id":"codex","models":["model"],"efforts":["low"]}"""))
            assertFalse(setup.isAvailable(descriptor(value)))
        assertFalse(setup.isAvailable(emptyList()))
        assertTrue(NewChatSetup("codex", null, null).isAvailable(descriptor("""{"id":"codex"}""")))
    }
    @Test fun onlyTheCapturedAccountHostAndRepositoryCanClaimSendOnce() {
        val drafts = ChatComposerSessions<StagedAttachment>({ it.bytes.toLong() })
        drafts.update("account|new-chat", ChatComposerSessions.Snapshot("Review the patch"))
        val request = NewChatRequest("host", "repository", "account", drafts.capture("account|new-chat"))
        assertFalse(request.claim("other-account", "host", "repository"))
        assertFalse(request.claim("account", "other-host", "repository"))
        assertFalse(request.claim("account", "host", "other-repository"))
        assertEquals("Review the patch", drafts.snapshot("account|new-chat").text)
        drafts.update("other-account|new-chat", ChatComposerSessions.Snapshot("Private older draft"))
        assertFalse(NewChatRequest("host", "repository", "account", drafts.capture("other-account|new-chat")).claim("account", "host", "repository"))
        assertEquals("Private older draft", drafts.snapshot("other-account|new-chat").text)
        assertTrue(request.claim("account", "host", "repository"))
        assertFalse(request.claim("account", "host", "repository"))
    }

    @Test fun acceptedTransferKeepsNewerLandingWritingAndConversationWriting() {
        val drafts = ChatComposerSessions<StagedAttachment>({ it.bytes.toLong() })
        drafts.update("landing", ChatComposerSessions.Snapshot("First request"))
        val request = NewChatRequest("host", "repository", "account", drafts.capture("landing"))
        drafts.update("landing", ChatComposerSessions.Snapshot("Newer writing"))
        assertTrue(drafts.update("new-conversation", request.source.snapshot))
        assertFalse(drafts.clearIfUnchanged(request.source.owner, request.source))
        assertEquals("Newer writing", drafts.snapshot("landing").text)
        assertEquals("First request", drafts.snapshot("new-conversation").text)
        assertTrue(drafts.hasWriting("new-conversation"))
    }
}
