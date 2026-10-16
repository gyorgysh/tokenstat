// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
package ai.tokenstat.tokenstat.ui.workspace

import ai.tokenstat.tokenstat.ui.logic.ChatComposerSessions
import org.junit.Assert.*
import org.junit.Test
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive

class NewChatRequestTest {
    private fun drafts(capacity: Int = 64) = ChatComposerSessions<StagedAttachment>({ it.bytes.toLong() }, capacity = capacity)
    private val owner = newChatDraftOwner("account", "host", "repository")!!
    private val file = StagedAttachment("image.png", "", "image/png", 20, "/local/unsent-image")

    @Test fun emptyExplicitOpenCanClaimCreationWithoutSendingAModelPrompt() {
        val drafts = drafts()
        for (text in listOf("", " \n ")) {
            drafts.update(owner, ChatComposerSessions.Snapshot(text))
            val request = NewChatRequest("host", "repository", "account", drafts.capture(owner))
            assertTrue(request.claim("account", "host", "repository"))
            assertFalse(request.shouldSend)
        }
        drafts.update(owner, ChatComposerSessions.Snapshot(attachments = listOf(file)))
        assertTrue(NewChatRequest("host", "repository", "account", drafts.capture(owner)).shouldSend)
    }

    @Test fun capturedAgentAndModelMustStillBeAvailableBeforeCreation() {
        fun descriptor(value: String) = listOf(Json.parseToJsonElement(value).jsonObject)
        val setup = NewChatSetup("codex", "model", "high")
        assertTrue(setup.isAvailable(descriptor("""{"id":"codex","models":["model"],"efforts":["high"]}""")))
        for (value in listOf("""{"id":"claude","models":["model"],"efforts":["high"]}""", """{"id":"codex","installed":false,"models":["model"],"efforts":["high"]}""", """{"id":"codex","models":["other"],"efforts":["high"]}""", """{"id":"codex","models":["model"],"efforts":["low"]}"""))
            assertFalse(setup.isAvailable(descriptor(value)))
        assertFalse(setup.isAvailable(emptyList()))
        assertTrue(NewChatSetup("codex", null, null).isAvailable(descriptor("""{"id":"codex"}""")))
        assertFalse(NewChatSetup("codex", null, null, fastMode = true).isAvailable(descriptor("""{"id":"codex"}""")))
        assertFalse(NewChatSetup("muse", null, null).isAvailable(descriptor("""{"id":"muse","gateTier":"bypassOnly"}""")))
    }

    @Test fun localComposerChoicesAreCapturedInCreationAndAgentChangesRetireAgentSpecificChoices() {
        val setup = NewChatSetup("codex", "model", "high", "plan", "bypass", true)
        val params = setup.createParameters("repository")
        for ((key, value) in mapOf("workspaceId" to "repository", "backend" to "codex", "model" to "model", "effort" to "high", "mode" to "plan", "autonomy" to "bypass", "fastMode" to "true"))
            assertEquals(value, params[key]?.jsonPrimitive?.content)
        val backends = listOf(Json.parseToJsonElement("""{"id":"muse","gateTier":"bypassOnly"}""").jsonObject)
        val changed = setup.copy(autonomy = "standard").changed("backend", "muse", backends)
        assertEquals("plan", changed.mode)
        assertEquals("bypass", changed.autonomy)
        assertNull(changed.model); assertNull(changed.effort); assertFalse(changed.fastMode)
    }

    @Test fun onlyTheCapturedAccountHostAndRepositoryCanClaimSendOnce() {
        val drafts = drafts()
        drafts.update(owner, ChatComposerSessions.Snapshot("Review the patch", listOf(file)))
        val request = NewChatRequest("host", "repository", "account", drafts.capture(owner))
        assertFalse(request.claim("other-account", "host", "repository"))
        assertFalse(request.claim("account", "other-host", "repository"))
        assertFalse(request.claim("account", "host", "other-repository"))
        assertEquals(listOf(file), drafts.snapshot(owner).attachments)
        val other = newChatDraftOwner("other-account", "host", "repository")!!
        drafts.update(other, ChatComposerSessions.Snapshot("Private older draft"))
        assertFalse(NewChatRequest("host", "repository", "account", drafts.capture(other)).claim("account", "host", "repository"))
        assertFalse(NewChatRequest("host", "other-repository", "account", drafts.capture(owner)).claim("account", "host", "other-repository"))
        assertTrue(request.claim("account", "host", "repository"))
        assertFalse(request.claim("account", "host", "repository"))
    }

    @Test fun unboundWordsMoveOnlyIntoAnEmptyExplicitRepositoryAndRepositoryDraftsStaySeparate() {
        val drafts = drafts()
        val unbound = newChatDraftOwner("account", null, null)!!
        val other = newChatDraftOwner("account", "host", "other-repository")!!
        drafts.update(unbound, ChatComposerSessions.Snapshot("Unbound words"))
        drafts.update(other, ChatComposerSessions.Snapshot("Other repository", listOf(file)))
        adoptUnboundNewChatDraft(drafts, "account", "host", "other-repository")
        assertEquals("Unbound words", drafts.snapshot(unbound).text)
        assertEquals("Other repository", drafts.snapshot(other).text)
        adoptUnboundNewChatDraft(drafts, "account", "host", "repository")
        assertEquals("Unbound words", drafts.snapshot(owner).text)
        assertFalse(drafts.hasWriting(unbound))
        assertEquals(listOf(file), drafts.snapshot(other).attachments)
        assertNotEquals(owner, newChatDraftOwner("account", "other-host", "repository"))
        assertNotEquals(owner, newChatDraftOwner("other-account", "host", "repository"))
    }

    @Test fun returningAttachmentResultsCannotCrossRepositoryOrVisitGeneration() {
        val firstVisit = NewChatInputLease(owner)
        assertTrue(firstVisit.accepts(firstVisit))
        val otherRepository = NewChatInputLease(newChatDraftOwner("account", "host", "other-repository"))
        assertFalse(firstVisit.accepts(otherRepository))
        firstVisit.retire()
        val returnedVisit = NewChatInputLease(owner)
        assertFalse(firstVisit.accepts(returnedVisit))
        assertFalse(firstVisit.accepts(firstVisit))
        assertTrue(returnedVisit.accepts(returnedVisit))
        val signedOut = NewChatInputLease(null)
        assertFalse(signedOut.accepts(signedOut))
    }

    @Test fun refusedHandoffRetainsTextAndFilesAndNeverOverwritesExistingWriting() {
        val full = drafts(capacity = 1)
        val snapshot = ChatComposerSessions.Snapshot("Keep this", listOf(file))
        full.update(owner, snapshot)
        val request = NewChatRequest("host", "repository", "account", full.capture(owner))
        assertTrue(request.claim("account", "host", "repository"))
        assertFalse(request.installInto(full, "conversation"))
        assertEquals(snapshot, full.snapshot(owner))
        val drafts = drafts()
        drafts.update(owner, snapshot)
        drafts.update("conversation", ChatComposerSessions.Snapshot("Existing writing"))
        val second = NewChatRequest("host", "repository", "account", drafts.capture(owner))
        assertTrue(second.claim("account", "host", "repository"))
        assertFalse(second.installInto(drafts, "conversation"))
        assertEquals("Existing writing", drafts.snapshot("conversation").text)
        assertEquals(snapshot, drafts.snapshot(owner))
    }

    @Test fun acceptedTransferKeepsNewerLandingWritingAndCapturedFiles() {
        val drafts = drafts()
        drafts.update(owner, ChatComposerSessions.Snapshot("First request", listOf(file)))
        val request = NewChatRequest("host", "repository", "account", drafts.capture(owner))
        assertTrue(request.claim("account", "host", "repository"))
        drafts.update(owner, ChatComposerSessions.Snapshot("Newer writing"))
        assertTrue(request.installInto(drafts, "new-conversation"))
        assertEquals("Newer writing", drafts.snapshot(owner).text)
        assertEquals("First request", drafts.snapshot("new-conversation").text)
        assertEquals(listOf(file), drafts.snapshot("new-conversation").attachments)
    }
}
