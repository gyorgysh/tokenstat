// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
package ai.tokenstat.tokenstat.ui.team

import kotlinx.serialization.json.*
import org.junit.Assert.*
import org.junit.Test

class TeamTranscriptTest {
    private fun obj(text: String) = Json.parseToJsonElement(text).jsonObject
    private fun agent(seq: Int, event: JsonObject, run: Char = 'a', former: Boolean = false) = buildJsonObject {
        put("seq", seq); put("kind", "agent"); put("mode", "agent"); put("backend", "claude"); put("event", event)
        put("author", buildJsonObject {
            put("kind", "agent"); put("backend", "claude"); put("runId", "run_" + run.toString().repeat(32))
            put("initiatedBy", if (former) obj("""{"kind":"formerMember","name":"Must not appear"}""") else obj("""{"kind":"person","id":"person-fixture","name":"Fictional member"}"""))
        })
    }
    private fun text(delta: String) = buildJsonObject { put("kind", "text"); put("delta", delta) }
    @Test fun chartFragmentsCoalesceWithoutCrossingPeopleOrRunBoundaries() {
        val source = "```tokenstat-chart\n{}\n```"
        val rows = TeamTranscript.project(listOf(agent(0, text(source.take(12))), agent(1, text(source.drop(12))), agent(2, text("other run"), 'b')), "claude")
        assertEquals(2, rows.size); assertEquals(source, rows[0].text); assertEquals("Fictional member", rows[0].author?.name)
        assertEquals("other run", rows[1].text)
        val erased = TeamTranscript.project(listOf(agent(0, text("reply"), former = true)), "claude").single()
        assertTrue(erased.author!!.formerInitiator); assertEquals("", erased.author.name)
    }
    @Test fun toolsKeepOwnershipAcrossRepeatedCallIdsAndNeverMatchAnotherRun() {
        val start = obj("""{"kind":"toolStart","callId":"same","verb":"Read","target":"file.txt","input":{"path":"file.txt"}}""")
        val end = obj("""{"kind":"toolEnd","callId":"same","ok":true,"detail":"first output"}""")
        val rows = TeamTranscript.project(listOf(agent(0, start), agent(1, start), agent(2, end), agent(3, end, 'b')), "claude")
        assertEquals(3, rows.size); assertEquals(true, rows[0].ok); assertTrue(rows[0].text.contains("first output"))
        assertNull(rows[1].ok); assertFalse(rows[1].text.contains("first output")); assertEquals("", rows[2].title)
        val anonymous = JsonObject(start - "callId")
        val unboundEnd = JsonObject(end - "callId")
        assertEquals(2, TeamTranscript.project(listOf(agent(0, anonymous), agent(1, unboundEnd)), "claude").size)
    }
    @Test fun malformedAuthorsAndSequencesCannotBecomeNamedContent() {
        val row = agent(1, text("literal"))
        assertTrue(runCatching { TeamTranscript.project(listOf(row, row), "claude") }.isFailure)
        val bad = JsonObject(row + ("mode" to JsonPrimitive("comment")))
        assertTrue(runCatching { TeamTranscript.project(listOf(bad), "claude") }.isFailure)
        val user = obj("""{"seq":0,"kind":"user","text":"literal","author":{"kind":"person","id":"p","name":"unverified"}}""")
        assertTrue(runCatching { TeamTranscript.project(listOf(user), "claude") }.isFailure)
        val hidden = TeamTranscript.project(listOf(agent(0, obj("""{"kind":"session","id":"private-continuation"}"""))), "claude").single()
        assertEquals(TeamBlockKind.Notice, hidden.kind); assertEquals("", hidden.text)
    }
    @Test fun literalPagesKeepEveryCodeUnitAndDoNotSplitSurrogatePairs() {
        val original = "ab🙂cdé".repeat(100)
        val pages = teamTextPages(original, 3)
        assertEquals(original, pages.joinToString("")); assertTrue(pages.all { !it.last().isHighSurrogate() && !it.first().isLowSurrogate() })
    }
}
