// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
package ai.tokenstat.tokenstat.ui.workspace

import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.jsonObject
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/// The same cases as scripts/tests/ChatQuestionTests.swift.
class ChatQuestionTest {
    private fun json(text: String): JsonObject = Json.parseToJsonElement(text).jsonObject

    private val fence = "```$QUESTION_FENCE"
    private val block = "$fence\n{\"question\":\"Which database?\",\"options\":[\"A\",\"B\"]}\n```"

    @Test
    fun blocksAreStrippedFromTheReply() {
        assertEquals("Plain reply.", stripQuestionBlocks("Plain reply."))
        assertEquals(
            "Yes, done.",
            stripQuestionBlocks("```$PLAN_FENCE\n{\"steps\":[{\"step\":\"Validate\",\"status\":\"completed\"}]}\n```Yes, done."),
        )
        assertEquals(
            "Yes, done.",
            stripQuestionBlocks("```$PLAN_FENCE\n{\"steps\":[{\"step\":\"Validate\",\"status\":\"completed\"}]}\n  ```Yes, done."),
        )
        assertEquals(
            "Yes, shipping.",
            stripQuestionBlocks("$fence\n{\"question\":\"Ship?\"}\n```Yes, shipping."),
        )
        // Captured from Grok: the next plan opens on the last one's closing line.
        val plan = "```$PLAN_FENCE\n{\"steps\":[{\"step\":\"Read\",\"status\":\"in_progress\"}]}\n```"
        assertEquals(
            "Working now.\nDone.",
            stripQuestionBlocks("Working now. $plan\nDone."),
        )
        assertEquals(
            "After.",
            stripQuestionBlocks("```$PLAN_FENCE {\"steps\":[{\"step\":\"Same\",\"status\":\"pending\"}]}\n```\nAfter."),
        )
        assertEquals(
            "Done.",
            stripQuestionBlocks("```$PLAN_FENCE\n{\"steps\":[{\"step\":\"Tail\",\"status\":\"completed\"}]}```\nDone."),
        )
        assertEquals(
            "Before.\nAfter.",
            stripQuestionBlocks("Before. ```$PLAN_FENCE {\"steps\":[{\"step\":\"One\",\"status\":\"completed\"}]}```\nAfter."),
        )
        assertEquals(
            "Starting.\n\nDone.",
            stripQuestionBlocks("Starting.\n\n$plan```$PLAN_FENCE\n{\"steps\":[{\"step\":\"Read\",\"status\":\"completed\"}]}\n```\nDone."),
        )
        assertEquals("Starting.", stripQuestionBlocks("Starting.\n$plan```$PLAN_FENCE\n{\"steps\":["))
        assertEquals("prose", stripQuestionBlocks("${plan.dropLast(3)}``````\nprose"))
        // Captured from Cursor: the first plan closes and the next opens on
        // the same line with prose between the fences.
        assertEquals(
            "A.\nNext works.\nDone.",
            stripQuestionBlocks("A.\n```$PLAN_FENCE\n{\"steps\":[{\"step\":\"A\",\"status\":\"completed\"}]}\n```Next works.```$PLAN_FENCE\n{\"steps\":[{\"step\":\"B\",\"status\":\"in_progress\"}]}\n```\nDone."),
        )
        assertEquals(
            "Before.\nmid\nafter",
            stripQuestionBlocks("Before. ```$PLAN_FENCE {\"steps\":[{\"step\":\"A\",\"status\":\"completed\"}]}``` mid ```$PLAN_FENCE {\"steps\":[{\"step\":\"B\",\"status\":\"completed\"}]}``` after"),
        )
        assertEquals("Before:\nGoing with A.", stripQuestionBlocks("Before:\n$block\nGoing with A."))
        assertEquals("Before:", stripQuestionBlocks("Before:\n$fence\n{\"question\":\"Wh"))
        assertEquals("", stripQuestionBlocks(block))
        assertEquals("", stripQuestionBlocks(block.replace("\n", "\r\n")))
        for (padding in listOf("x".repeat(64 * 1024), "é".repeat(32 * 1024))) {
            val oversized = "$fence\n{\"question\":\"Q\",\"extra\":\"$padding\"}\n```"
            assertEquals(oversized, stripQuestionBlocks(oversized))
        }
        val prefix = "{\"question\":\"Q\",\"extra\":\""
        val suffix = "\"}"
        for (extra in listOf(0, 1)) {
            val body = prefix + "x".repeat(64 * 1024 - 1 - prefix.length - suffix.length + extra) + suffix
            val edge = "$fence\n$body\n```"
            assertEquals(if (extra == 0) "" else edge, stripQuestionBlocks(edge))
        }
        assertEquals("Run:\n```sh\nls\n```", stripQuestionBlocks("Run:\n```sh\nls\n```"))
        val prose = "Use ```$QUESTION_FENCE carefully.\nStill prose.\n```\nAfter."
        assertEquals(prose, stripQuestionBlocks(prose))
        assertEquals("after", stripQuestionBlocks("  $fence\n{\"question\":\"Pick?\"}\n  ```\nafter"))
        for (body in listOf("{}", "broken JSON", "{\"question\":42}", "{\"question\":\" \"}")) {
            val invalid = "$fence\n$body\n```"
            assertEquals(invalid, stripQuestionBlocks(invalid))
        }
        val unfinished = "$fence\n{\"question\":\"Wh"
        val abandoned = "$fence\n" + "x".repeat(64 * 1024 + 1)
        assertEquals(abandoned, stripQuestionBlocks(abandoned))
        assertEquals(abandoned, stripQuestionBlocks("$abandoned\n$block"))
        assertEquals(unfinished, stripQuestionBlocks(unfinished, streaming = false))
    }

    @Test
    fun aQuestionBecomesACardAndItsAnswerLandsOnIt() {
        val text = Json.encodeToString(kotlinx.serialization.json.JsonPrimitive.serializer(),
            kotlinx.serialization.json.JsonPrimitive("Before:\n$block"))
        val events = listOf(
            json("""{"kind":"user","text":"hi","atMs":1}"""),
            json("""{"kind":"agent","backend":"claude","atMs":2,"event":{"kind":"text","delta":$text}}"""),
            json("""{"kind":"question","id":"q1","question":"Which database?","options":["A","B"],"multiple":false,"default":"A","blocking":false,"atMs":3}"""),
        )
        val open = coalesceTranscript(events, running = true)
        val reply = open.filterIsInstance<ChatDisplayItem.Assistant>().single()
        assertEquals("Before:", reply.text)
        val card = open.filterIsInstance<ChatDisplayItem.Question>().single()
        assertEquals("question-q1", card.id)
        assertEquals(listOf("A", "B"), card.question.options)
        assertEquals("A", card.question.defaultAnswer)
        assertTrue(!card.question.blocking)
        assertNull(card.question.answer)

        val answered = coalesceTranscript(
            events + json("""{"kind":"answer","questionId":"q1","text":"B","delivery":"note","atMs":4}"""),
            running = true,
        ).filterIsInstance<ChatDisplayItem.Question>().single()
        assertEquals("B", answered.question.answer)
        assertEquals("note", answered.question.delivery)
    }

    @Test
    fun aQuestionWithoutADefaultIsBlockingAndAStrayAnswerIsIgnored() {
        val items = coalesceTranscript(listOf(
            json("""{"kind":"question","id":"q2","question":"Name?","atMs":1}"""),
            json("""{"kind":"answer","questionId":"elsewhere","text":"x","atMs":2}"""),
        ))
        val card = items.filterIsInstance<ChatDisplayItem.Question>().single()
        assertTrue(card.question.blocking)
        assertNull(card.question.answer)
        assertEquals(1, items.size)
    }

    @Test
    fun questionsAreNeverFolded() {
        val items = coalesceTranscript(listOf(
            json("""{"kind":"user","text":"hi","atMs":1}"""),
            json("""{"kind":"question","id":"q3","question":"Name?","atMs":2}"""),
        ))
        for (detail in ChatDetail.entries) {
            val folded = foldTranscript(items, detail, running = false) { false }
            assertTrue("$detail shows the question", folded.any { it.id == "question-q3" })
        }
    }
}
