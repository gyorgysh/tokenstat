// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
package ai.tokenstat.tokenstat.ui.team

import kotlinx.serialization.json.*

internal data class TeamAuthor(val kind: String, val name: String = "", val backend: String = "", val person: String = "", val run: String = "", val formerInitiator: Boolean = false)
internal enum class TeamBlockKind { User, Text, Thinking, Tool, Edit, File, Notice, Error }
internal data class TeamBlock(val id: String, val kind: TeamBlockKind, val author: TeamAuthor?, val text: String = "", val title: String = "", val file: JsonObject? = null, val ok: Boolean? = null)

/** Only shared, host-projected content enters this reader. No personal chat,
 * approval, workspace, URL action or provider continuation callback exists. */
internal object TeamTranscript {
    private val runPattern = Regex("run_[0-9a-f]{32}")
    private fun JsonObject.str(key: String) = (this[key] as? JsonPrimitive)?.takeIf { it.isString }?.content
    private fun person(raw: JsonObject): Pair<String, String> {
        val id = raw.str("id").orEmpty(); val name = raw.str("name").orEmpty()
        require(id.isNotEmpty() && id.toByteArray().size <= 128 && name.isNotEmpty() && name.codePointCount(0, name.length) <= 128)
        return id to name
    }
    private fun author(row: JsonObject, fallback: String): TeamAuthor {
        val raw = row["author"] as? JsonObject
        if (row.str("kind") == "user") return when (raw?.str("kind")) {
            null, "localBeforeTeams" -> TeamAuthor("localBeforeTeams")
            "person" -> {
                require(row.str("mode") in setOf("comment", "ask"))
                val p = person(raw); TeamAuthor(row.str("mode")!!, name = p.second, person = p.first)
            }
            "formerMember" -> TeamAuthor("formerMember")
            else -> error("Invalid shared author")
        }
        val backend = row.str("backend")?.takeIf { it.isNotEmpty() } ?: fallback
        if (raw == null) return TeamAuthor("agent", backend = backend)
        require(raw.str("kind") == "agent" && row.str("mode") == "agent" && raw.str("backend") == backend)
        val run = raw.str("runId").orEmpty()
        require(run.matches(runPattern))
        val initiator = raw["initiatedBy"] as? JsonObject ?: error("Invalid shared initiator")
        return when (initiator.str("kind")) {
            "person" -> { val p = person(initiator); TeamAuthor("agent", name = p.second, backend = backend, person = p.first, run = run) }
            "formerMember" -> TeamAuthor("agent", backend = backend, run = run, formerInitiator = true)
            else -> error("Invalid shared initiator")
        }
    }
    fun project(events: List<JsonObject>, backend: String): List<TeamBlock> {
        val rows = mutableListOf<TeamBlock>()
        val tools = mutableMapOf<Triple<String, String, String>, java.util.ArrayDeque<Int>>()
        var previous: ULong? = null
        var buffered = StringBuilder(); var bufferedKind = TeamBlockKind.Text; var bufferedAuthor: TeamAuthor? = null; var bufferedId = ""
        fun flush() {
            if (buffered.isNotEmpty()) rows += TeamBlock(bufferedId, bufferedKind, bufferedAuthor, buffered.toString())
            buffered = StringBuilder(); bufferedAuthor = null
        }
        for (row in events) {
            val seq = (row["seq"] as? JsonPrimitive)?.takeIf { !it.isString }?.content?.toULongOrNull() ?: error("Invalid shared sequence")
            previous?.let { require(seq > it) }; previous = seq
            val id = "s$seq"; val kind = row.str("kind")
            if (kind == "user") {
                flush(); tools.clear()
                rows += TeamBlock(id, TeamBlockKind.User, author(row, backend), row.str("text").orEmpty()); continue
            }
            if (kind == "agent") {
                val by = author(row, backend)
                val event = row["event"] as? JsonObject ?: error("Invalid shared event")
                val eventKind = event.str("kind")
                if (eventKind in setOf("text", "thinking")) {
                    val nextKind = if (eventKind == "text") TeamBlockKind.Text else TeamBlockKind.Thinking
                    if (buffered.isNotEmpty() && (bufferedKind != nextKind || bufferedAuthor != by)) flush()
                    if (buffered.isEmpty()) { bufferedId = id; bufferedKind = nextKind; bufferedAuthor = by }
                    buffered.append(event.str("delta").orEmpty()); continue
                }
                flush()
                val call = Triple(by.backend, by.run, event.str("callId").orEmpty())
                when (eventKind) {
                    "toolStart" -> {
                        val title = listOf(event.str("verb"), event.str("target")).filterNotNull().joinToString(" ")
                        if (call.third.isNotEmpty()) tools.getOrPut(call) { java.util.ArrayDeque() }.addLast(rows.size)
                        rows += TeamBlock(id, TeamBlockKind.Tool, by, event["input"]?.toString().orEmpty(), title)
                    }
                    "toolEnd" -> {
                        val queue = tools[call]
                        val at = if (queue?.isEmpty() == false) queue.removeFirst() else null
                        val detail = event.str("detail").orEmpty(); val ok = (event["ok"] as? JsonPrimitive)?.booleanOrNull
                        if (at == null) rows += TeamBlock(id, TeamBlockKind.Tool, by, detail, ok = ok)
                        else rows[at] = rows[at].copy(text = listOf(rows[at].text, detail).filter { it.isNotEmpty() }.joinToString("\n\n"), ok = ok)
                    }
                    "edit" -> rows += TeamBlock(id, TeamBlockKind.Edit, by, event.str("patch").orEmpty(), event.str("path").orEmpty())
                    "attachment" -> rows += TeamBlock(id, TeamBlockKind.File, by, file = event)
                    "failed" -> rows += TeamBlock(id, TeamBlockKind.Error, by, event.str("text").orEmpty())
                    "done" -> { tools.clear(); rows += TeamBlock(id, TeamBlockKind.Notice, by, title = if (event.str("status") in setOf("failed", "error")) "run_failed" else "run_finished") }
                    "usage" -> Unit
                    else -> rows += TeamBlock(id, TeamBlockKind.Notice, by, title = "event_unavailable")
                }
                continue
            }
            flush(); tools.clear()
            when (kind) {
                "question" -> rows += TeamBlock(id, TeamBlockKind.Notice, null, listOf(row.str("question").orEmpty(), (row["options"] as? JsonArray)?.joinToString("\n") { (it as? JsonPrimitive)?.content.orEmpty() }.orEmpty()).filter { it.isNotEmpty() }.joinToString("\n"), "recorded_question")
                "answer", "system" -> rows += TeamBlock(id, TeamBlockKind.Notice, null, row.str("text").orEmpty(), "recorded_message")
                "handoff" -> rows += TeamBlock(id, TeamBlockKind.Notice, null, row.str("to").orEmpty(), "recorded_handoff")
                "answerWithdrawn" -> rows += TeamBlock(id, TeamBlockKind.Notice, null, title = "answer_withdrawn")
                "approval" -> rows += TeamBlock(id, TeamBlockKind.Notice, null, (row["approval"] as? JsonObject)?.str("preview").orEmpty(), "recorded_approval")
                else -> rows += TeamBlock(id, TeamBlockKind.Notice, null, title = "event_unavailable")
            }
        }
        flush(); return rows
    }
}

/** Fixed-size literal pages preserve every UTF-16 code unit without breaking
 * surrogate pairs. Used for large replies and read-only tool/diff detail. */
internal fun teamTextPages(text: String, limit: Int = 8192): List<String> {
    require(limit >= 2)
    val pages = mutableListOf<String>(); var start = 0
    while (start < text.length) {
        var end = minOf(text.length, start + limit)
        if (end < text.length && text[end - 1].isHighSurrogate() && text[end].isLowSurrogate()) end--
        pages += text.substring(start, end); start = end
    }
    return pages.ifEmpty { listOf("") }
}
