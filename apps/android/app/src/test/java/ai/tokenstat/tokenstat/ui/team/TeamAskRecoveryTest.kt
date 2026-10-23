// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
package ai.tokenstat.tokenstat.ui.team

import java.io.File
import java.nio.file.Files
import kotlinx.coroutines.test.runTest
import kotlinx.serialization.json.*
import org.junit.Assert.*
import org.junit.Test

class TeamAskRecoveryTest {
    private val target = TeamCommentTarget("https://fixture.invalid", "person-fixture", "org-fixture", "repo-fixture", "checkout-fixture", "share-fixture", "a".repeat(64))
    private val fence = buildJsonObject { put("runId", "run_" + "a".repeat(32)); put("incarnation", "b".repeat(64)) }
    @Test fun lostReplyAndRunningControlSurviveNewStoresWithoutResendingOnRestore() = runTest {
        val root = Files.createTempDirectory("team-ask-recovery").toFile()
        try {
            var reviews = 0; var sends = 0; var stops = 0; var lost = true
            var original: JsonObject? = null
            var status: JsonObject = buildJsonObject { put("running", "false") }
            suspend fun call(method: String, input: JsonObject): JsonObject = when (method) {
                "team.chat.ask.review" -> { reviews++; buildJsonObject { put("agentRuns", true); put("review", "c".repeat(64)) } }
                "team.chat.ask" -> {
                    sends++
                    assertEquals(input, TeamAskRecoveryStore(root).load(target)!!.record.input)
                    if (original == null) original = input else assertEquals(original, input)
                    if (lost) throw java.io.IOException("Fictional reply lost")
                    buildJsonObject { put("state", "running"); put("fence", fence) }
                }
                "team.chat.ask.status" -> { assertEquals(fence, input["fence"]); status }
                "team.chat.ask.stop" -> {
                    assertEquals(fence, input["fence"])
                    if (++stops == 1) throw java.io.IOException("Fictional Stop failed")
                    buildJsonObject { put("stopping", false) }
                }
                else -> error("Unexpected call")
            }
            fun model() = TeamAskModel(TeamAskRecoveryStore(root), target, "Fictional project", ::call)
            val first = model(); first.restore(); first.text = "Original fictional Ask"; first.ask()
            assertTrue(first.pending); assertEquals(1, sends)
            val pending = model(); pending.restore()
            assertEquals("Original fictional Ask", pending.text); assertTrue(pending.pending); assertEquals(1, sends)
            lost = false; pending.ask()
            assertEquals(1, reviews); assertEquals(2, sends); assertEquals(fence, pending.fence)
            val running = model(); running.restore()
            assertEquals(fence, running.fence); assertEquals(2, sends)
            running.check(); assertEquals(fence, running.fence)
            status = buildJsonObject { put("running", true) }; running.check()
            assertNull(running.error); assertNotNull(running.fence)
            running.stop(); assertFalse(running.stopping); assertNotNull(running.fence)
            running.stop(); assertTrue(running.stopping); assertNotNull(running.fence)
            status = buildJsonObject { put("running", false) }; running.check()
            assertNull(running.fence); assertNull(TeamAskRecoveryStore(root).load(target))
        } finally { root.deleteRecursively() }
    }
    @Test fun explicitRefusalKeepsWordsAndFailedStorageCannotSendWork() = runTest {
        val root = Files.createTempDirectory("team-ask-refusal").toFile()
        try {
            val storage = TeamAskRecoveryStore(root)
            val refused = TeamAskModel(storage, target, "") { method, _ ->
                if (method == "team.chat.ask.review") buildJsonObject { put("agentRuns", true); put("review", "c".repeat(64)) }
                else throw TeamAskNotAccepted("Fictional stale review refused")
            }
            refused.restore(); refused.text = "Keep the refused words"; refused.ask()
            assertFalse(refused.pending); assertEquals("Keep the refused words", refused.text); assertNull(storage.load(target))
            val file = File(root, "not-a-directory").apply { writeText("fixture") }
            var calls = 0
            val blocked = TeamAskModel(TeamAskRecoveryStore(file), target, "") { _, _ -> calls++; error("Must not send") }
            blocked.restore(); blocked.text = "Unsaved work"; blocked.ask()
            assertFalse(blocked.loaded); assertEquals(0, calls)
        } finally { root.deleteRecursively() }
    }
    @Test fun staleWindowsScopesAndCorruptionCannotEraseOrReplaceSavedWork() {
        val root = Files.createTempDirectory("team-ask-cas").toFile()
        try {
            fun record(text: String) = TeamAskRecord(buildJsonObject {
                put("text", text); put("review", "c".repeat(64)); put("clientMessageId", java.util.UUID.randomUUID().toString()); put("clientMessageCreatedAtMs", 1)
            })
            val store = TeamAskRecoveryStore(root)
            val first = store.replace(target, record("First"), null)!!
            assertNull(store.load(target.copy(person = "other-person")))
            assertNull(store.load(target.copy(host = "b".repeat(64))))
            val next = store.replace(target, first.record.copy(fence = fence), first)!!
            try { store.replace(target, null, first); fail("Stale completion removed newer recovery") } catch (_: TeamDraftFailure) { }
            assertEquals(next.record, store.load(target)!!.record)
            val file = root.walk().single { it.extension == "json" }
            file.writeText("broken")
            assertTrue(runCatching { store.load(target) }.isFailure)
            assertEquals("broken", file.readText())
            val wrong = buildJsonObject { put("receipt", buildJsonObject { put("shareId", "other-share"); put("clientMessageId", first.record.input["clientMessageId"]!!); put("state", "succeeded"); put("runId", fence["runId"]!!) }) }
            assertFalse(first.record.terminal(wrong, target.share))
        } finally { root.deleteRecursively() }
    }
}
