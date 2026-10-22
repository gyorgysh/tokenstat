// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
package ai.tokenstat.tokenstat.ui.team

import java.io.File
import java.nio.file.Files
import kotlinx.coroutines.*
import kotlinx.coroutines.test.*
import kotlinx.serialization.json.*
import org.junit.Assert.*
import org.junit.Test

@OptIn(ExperimentalCoroutinesApi::class)
class TeamCommentDraftStoreTest {
    private val target = TeamCommentTarget("https://fixture.invalid", "person-fixture", "org-fixture", "repo-fixture", "checkout-fixture", "share-fixture", "host-fixture")
    private fun receipt(d: TeamCommentDraft, state: String) = buildJsonObject {
        put("shareId", target.share); put("clientMessageId", d.attempt!!.id); put("state", state)
        if (state == "accepted") { put("sequence", 0); put("acceptedAtMs", 1) }
    }
    private fun refuses(block: () -> Unit) { try { block(); fail("expected refusal") } catch (_: TeamDraftFailure) {} }
    private fun fixture(block: (File, TeamCommentDraftStore) -> Unit) {
        val dir = Files.createTempDirectory("tokenstat-team-comment-tests-").toFile()
        try { block(dir, TeamCommentDraftStore(dir)) } finally { dir.deleteRecursively() }
    }
    @Test fun restartAndRetryRetainTheExactInputAndOnlyValidReceiptsResolveIt() = fixture { dir, store ->
        val saved = store.save(target, "  words 🙂\n", null, "Fictional chat")!!
        val pending = store.reserve(target, saved)
        val restarted = TeamCommentDraftStore(dir)
        assertEquals(pending, restarted.load(target)); assertEquals(pending, restarted.reserve(target, pending))
        refuses { store.save(target, "edited", pending, "label") }
        assertEquals("edited", store.unsaved(target)?.text); store.forgetUnsaved(target)
        assertEquals(pending, store.resolve(target, pending, receipt(pending, "unknown")))
        refuses { store.resolve(target, pending, JsonObject(receipt(pending, "accepted") + ("shareId" to JsonPrimitive("foreign")))) }
        refuses { store.resolve(target, pending, JsonObject(receipt(pending, "accepted") + ("sequence" to JsonPrimitive(-1)))) }
        refuses { store.resolve(target, pending, JsonObject(receipt(pending, "accepted") + ("acceptedAtMs" to JsonPrimitive("1")))) }
        assertEquals(pending, store.load(target))
        val rejected = store.resolve(target, pending, receipt(pending, "notAccepted"))!!
        assertNull(rejected.attempt); assertEquals(saved.text, rejected.text)
        val later = store.save(target, "new words", rejected, "label")
        refuses { store.resolve(target, pending, receipt(pending, "accepted")) }
        assertEquals(later, store.load(target))
    }
    @Test fun conflictsAndExplicitRemovalProtectEveryReviewedVersion() = fixture { _, store ->
        val first = store.save(target, "first", null, "label")!!
        val second = store.save(target, "second", first, "label")
        refuses { store.save(target, "other window", first, "label") }
        assertEquals("other window", store.unsaved(target)?.text)
        val reviewed = store.list(target.origin, target.person).entries.single()
        store.remember(target, "newer unsaved", second, "label")
        refuses { store.discard(reviewed) }
        store.forgetUnsaved(target)
        store.discard(store.list(target.origin, target.person).entries.single())
        assertNull(store.load(target))
    }
    @Test fun recoveryIsAccountAndResourceBoundAndCorruptFilesArePreserved() = fixture { dir, store ->
        store.save(target, "words", null, "label")
        for (other in listOf(target.copy(person = "other"), target.copy(origin = "https://other.invalid"), target.copy(host = "other"), target.copy(share = "other"), target.copy(checkout = "other"))) assertNull(store.load(other))
        assertTrue(store.list(target.origin, "other-person").entries.isEmpty())
        val file = dir.walk().single { it.extension == "json" }
        file.writeText("{broken")
        assertTrue(runCatching { store.load(target) }.isFailure)
        assertTrue(store.list(target.origin, target.person).unreadable); assertTrue(file.exists())
    }
    @Test fun sendBudgetsCountUtf8AndEscapedPayloadsWithoutDroppingLongDrafts() = fixture { _, store ->
        assertFalse(TeamCommentDraft("", "é".repeat(4097), null, "").canSend)
        assertFalse(TeamCommentDraft("", "\u0001".repeat(3000), null, "").canSend)
        val long = store.save(target, "x".repeat(8193), null, "label")!!
        refuses { store.reserve(target, long) }; assertEquals(long, store.load(target))
    }
    @Test fun lostRepliesRecoverAndExplicitResendUsesIdenticalInput() = runTest {
        Dispatchers.setMain(StandardTestDispatcher(testScheduler))
        val dir = Files.createTempDirectory("tokenstat-team-comment-model-").toFile()
        try {
            val store = TeamCommentDraftStore(dir); val sent = mutableListOf<JsonElement?>()
            val model = TeamCommentModel(store, target, "label") { _, body -> sent += body["input"]; throw java.io.IOException("reply lost") }
            model.restore(); model.edit("one literal message"); model.send()
            assertTrue(model.pending); model.send(); assertEquals(2, sent.size); assertEquals(sent[0], sent[1])
            val next = TeamCommentModel(TeamCommentDraftStore(dir), target, "label") { _, _ -> buildJsonObject { put("receipt", receipt(store.load(target)!!, "accepted")) } }
            next.restore(); assertTrue(next.pending); assertEquals("one literal message", next.text)
            next.check(); assertFalse(next.pending); assertEquals("", next.text); assertNull(store.load(target))
        } finally { dir.deleteRecursively(); Dispatchers.resetMain() }
    }
}
