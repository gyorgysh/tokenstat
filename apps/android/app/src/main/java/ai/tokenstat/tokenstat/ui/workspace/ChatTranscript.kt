// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
package ai.tokenstat.tokenstat.ui.workspace

import ai.tokenstat.tokenstat.ui.localization.L10n

import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.contentOrNull
import kotlinx.serialization.json.jsonPrimitive
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.booleanOrNull
import kotlinx.serialization.json.doubleOrNull
import kotlinx.serialization.json.longOrNull

data class ChatPlanStep(val text: String, val status: String)

sealed interface ChatDisplayItem {
    val id: String

    data class User(override val id: String, val text: String, val isSteer: Boolean = false) : ChatDisplayItem
    data class Assistant(override val id: String, val text: String, val backend: String?) : ChatDisplayItem
    data class TurnSeparator(override val id: String, val backend: String) : ChatDisplayItem
    data class Handoff(override val id: String, val to: String, val brief: String) : ChatDisplayItem
    data class Thinking(override val id: String, val text: String) : ChatDisplayItem
    data class Tool(override val id: String, val state: ChatToolState) : ChatDisplayItem
    data class Edit(override val id: String, val state: ChatEditState) : ChatDisplayItem
    data class Attachment(
        override val id: String,
        val attachmentId: String,
        val name: String,
        val mediaType: String?,
        val size: Long?,
        val callId: String? = null,
        val backend: String? = null,
    ) : ChatDisplayItem

    data class ImageGallery(override val id: String, val images: List<Attachment>) : ChatDisplayItem

    data class Approval(
        override val id: String,
        val raw: JsonObject,
    ) : ChatDisplayItem

    data class Usage(
        override val id: String,
        val input: Long,
        val output: Long,
        val costUsd: Double?,
    ) : ChatDisplayItem

    data class Failed(override val id: String, val text: String) : ChatDisplayItem

    data class Group(override val id: String, val group: ChatStepGroup) : ChatDisplayItem

    data class Question(override val id: String, val question: ChatQuestion) : ChatDisplayItem

    data class Plan(override val id: String, val steps: List<ChatPlanStep>) : ChatDisplayItem

    data class GroupStep(
        override val id: String,
        val groupId: String,
        val item: ChatDisplayItem,
        val plain: PlainStep? = null,
    ) : ChatDisplayItem

    data class Changes(override val id: String, val files: List<ChangedFile>) : ChatDisplayItem {
        val added: Long get() = files.sumOf { it.added }
        val removed: Long get() = files.sumOf { it.removed }
    }
}

data class ChangedFile(val path: String, val added: Long, val removed: Long, val patches: List<String> = emptyList()) {
    val fileName: String get() = path.substringAfterLast('/').ifEmpty { path }
}

data class ChatToolState(
    val callId: String,
    val verb: String,
    val target: String,
    val running: Boolean,
    val failed: Boolean,
    val detail: String?,
    val startedAtMs: Long,
    val endedAtMs: Long?,
    val snippet: List<String>,
    val backend: String? = null,
) {
    val duration: String? get() = ChatClock.duration(startedAtMs, endedAtMs)

    companion object {
        fun isFileEditVerb(verb: String): Boolean = verb == "Edit" || verb == "NotebookEdit"

        fun makeSnippet(verb: String, detail: String?): List<String> {
            if (detail.isNullOrEmpty()) return emptyList()
            val isDiff = verb == "Edit" || verb == "NotebookEdit" || verb == "Diff"
            val out = ArrayList<String>(SnippetLineCap + 1)
            var start = 0
            var count = 0
            while (true) {
                val end = detail.indexOf('\n', start).let { if (it < 0) detail.length else it }
                if (count < SnippetLineCap) {
                    val shown = clip(detail, start, end)
                    out.add(if (isDiff && isDiffLine(shown)) shown else "| $shown")
                }
                count++
                if (end == detail.length) break
                start = end + 1
            }
            if (count > SnippetLineCap) {
                out.add(L10n.text("android.chattranscript.0_more.8bfcca49", "${count - SnippetLineCap}"))
            }
            return out
        }

        fun isDiffLine(line: String): Boolean {
            val first = line.firstOrNull() ?: return false
            if (first != '+' && first != '-') return false
            return !(line.startsWith("+++ ") || line.startsWith("--- "))
        }

        fun clip(line: String): String {
            return clip(line, 0, line.length)
        }

        private fun clip(text: String, start: Int, end: Int): String {
            if (end - start <= SnippetColumnCap) return text.substring(start, end)
            var cut = start + SnippetColumnCap
            if (text[cut - 1].isHighSurrogate() && text[cut].isLowSurrogate()) cut--
            return text.substring(start, cut) + "…"
        }

        private const val SnippetLineCap = 60
        private const val SnippetColumnCap = 600
    }
}

data class ChatEditState(
    val path: String,
    val added: Long,
    val removed: Long,
    val patch: String,
    val revision: Int,
    val running: Boolean,
    val failed: Boolean,
    val startedAtMs: Long,
    val endedAtMs: Long?,
    val callId: String? = null,
    val backend: String? = null,
) {
    val duration: String? get() = ChatClock.duration(startedAtMs, endedAtMs)

    val fileName: String get() = path.substringAfterLast('/').ifEmpty { path }

    val location: String
        get() {
            val folder = path.substringBeforeLast('/', "")
            if (folder.isEmpty() || folder == "/") return ""
            val parts = folder.split('/').filter { it.isNotEmpty() }
            if (parts.isEmpty()) return ""
            if (parts.size == 1) return parts[0]
            return parts.takeLast(2).joinToString("/")
        }

    val changeLabel: String? get() = if (revision >= 2) L10n.text("android.chattranscript.0_change.d4ef778c", "${ChatClock.ordinal(revision)}") else null

    fun applyPatch(added: Long, removed: Long, patch: String): ChatEditState {
        return copy(
            added = if (added > 0) added else this.added,
            removed = if (removed > 0) removed else this.removed,
            patch = if (patch.isNotEmpty()) patch else this.patch,
        ).recountIfNeeded()
    }

    fun applyDetail(detail: String?): ChatEditState {
        if (patch.isNotEmpty() || detail.isNullOrEmpty()) return this
        return copy(patch = detail).recountIfNeeded()
    }

    fun recountIfNeeded(): ChatEditState {
        if (!(added == 0L && removed == 0L && patch.isNotEmpty())) return this
        var plus = 0L
        var minus = 0L
        var start = 0
        while (start < patch.length) {
            when (patch[start]) {
                '+' -> if (!patch.startsWith("+++ ", start)) plus++
                '-' -> if (!patch.startsWith("--- ", start)) minus++
            }
            val newline = patch.indexOf('\n', start)
            if (newline < 0) break
            start = newline + 1
        }
        return copy(added = plus, removed = minus)
    }
}

object ChatClock {
    fun duration(startedAtMs: Long, endedAtMs: Long?): String? {
        endedAtMs ?: return null
        val ms = maxOf(0L, endedAtMs - startedAtMs)
        if (ms < 1000) return "${ms}ms"
        val seconds = ms / 1000.0
        if (seconds < 10) return "%.1fs".format(seconds)
        return "${Math.round(seconds)}s"
    }

    fun ordinal(value: Int): String {
        val mod100 = value % 100
        val mod10 = value % 10
        if (mod100 in 11..13) return "${value}th"
        return when (mod10) {
            1 -> "${value}st"
            2 -> "${value}nd"
            3 -> "${value}rd"
            else -> "${value}th"
        }
    }
}

private fun JsonObject.safeLong(key: String): Long? =
    (this[key] as? JsonPrimitive)?.longOrNull

private fun JsonObject.safeDouble(key: String): Double? =
    (this[key] as? JsonPrimitive)?.doubleOrNull

private fun JsonObject.safeBool(key: String): Boolean? =
    (this[key] as? JsonPrimitive)?.booleanOrNull

fun coalesceTranscript(
    events: List<JsonObject>,
    defaultBackend: String? = null,
    running: Boolean = true,
): List<ChatDisplayItem> {
    val items = mutableListOf<ChatDisplayItem>()
    var latestPlanID: String? = null
    val supersededPlanIDs = mutableSetOf<String>()
    val toolIndexes = mutableMapOf<Pair<String?, String>, MutableList<Int>>()
    val toolStarts = mutableMapOf<String, Int>()
    val toolBackends = mutableMapOf<String, String>()
    val editStarts = mutableMapOf<String, Int>()
    val approvalIndex = mutableMapOf<String, Int>()
    val questionIndex = mutableMapOf<String, Int>()
    val editRevisions = mutableMapOf<String, Int>()
    val runningIndexes = linkedSetOf<Int>()
    var text = StringBuilder()
    var textID = ""
    var textBackend: String? = null
    var thinking = StringBuilder()
    var thinkingID = ""
    var lastBackend: String? = null

    fun stamp(ev: JsonObject, position: Int): String {
        val seq = ev.safeLong("seq")
        if (seq != null) return "s$seq"
        return "${ev.safeLong("atMs") ?: ev.safeLong("at_ms") ?: 0}-$position"
    }

    fun atMsOf(ev: JsonObject, inner: JsonObject?): Long? =
        ev.safeLong("atMs") ?: ev.safeLong("at_ms")
            ?: inner?.safeLong("atMs") ?: inner?.safeLong("at_ms")

    fun flushText() {
        val body = stripQuestionBlocks(text.toString(), streaming = running).trim()
        if (body.isNotEmpty()) {
            items.add(ChatDisplayItem.Assistant(textID, body, textBackend ?: defaultBackend))
        }
        text = StringBuilder()
        textID = ""
        textBackend = null
    }

    fun flushThinking() {
        val body = thinking.toString().trim()
        if (body.isNotEmpty()) {
            items.add(ChatDisplayItem.Thinking(thinkingID, body))
        }
        thinking = StringBuilder()
        thinkingID = ""
    }

    fun closeRunningTools(failed: Boolean, at: Long?, detail: String?) {
        for (index in runningIndexes) {
            when (val item = items[index]) {
                is ChatDisplayItem.Tool -> {
                    if (!item.state.running) continue
                    var state = item.state.copy(running = false, failed = failed, endedAtMs = at)
                    if (state.detail == null) {
                        state = state.copy(
                            detail = detail,
                            snippet = ChatToolState.makeSnippet(state.verb, detail),
                        )
                    }
                    items[index] = item.copy(state = state)
                }
                is ChatDisplayItem.Edit -> {
                    if (!item.state.running) continue
                    var state = item.state.copy(running = false, failed = failed, endedAtMs = at)
                    state = state.applyDetail(detail)
                    items[index] = item.copy(state = state)
                }
                else -> continue
            }
        }
        runningIndexes.clear()
    }

    fun nextEditRevision(path: String): Int {
        val n = (editRevisions[path] ?: 0) + 1
        editRevisions[path] = n
        return n
    }

    fun noteToolIndex(index: Int, callId: String, backend: String?) {
        if (callId.isEmpty()) return
        val indexes = toolIndexes.getOrPut(backend to callId) { mutableListOf() }
        indexes.removeAll { it == index }
        indexes.add(index)
    }

    fun toolIndexesFor(callId: String, backend: String?): List<Int>? =
        toolIndexes[backend to callId]
            ?: toolIndexes.entries.filter { it.key.second == callId }.singleOrNull()?.value

    fun toolEndIndex(callId: String, backend: String?): Int? {
        if (callId.isEmpty()) return null
        val indexes = toolIndexesFor(callId, backend) ?: return null
        val runningIdx = indexes.firstOrNull { index ->
            if (index !in items.indices) return@firstOrNull false
            when (val item = items[index]) {
                is ChatDisplayItem.Tool -> item.state.running
                is ChatDisplayItem.Edit -> item.state.running
                else -> false
            }
        }
        return runningIdx ?: indexes.lastOrNull { it in items.indices }
    }

    fun matchingEditIndex(callId: String, path: String, backend: String?): Int? {
        if (callId.isNotEmpty()) {
            val indexes = toolIndexesFor(callId, backend)
            if (indexes != null) {
                for (index in indexes.asReversed()) {
                    if (index !in items.indices) continue
                    when (val item = items[index]) {
                        is ChatDisplayItem.Edit ->
                            if (path.isEmpty() || item.state.path == path || item.state.path == "File") return index
                        is ChatDisplayItem.Tool ->
                            if (ChatToolState.isFileEditVerb(item.state.verb) &&
                                (path.isEmpty() || item.state.target == path || item.state.target.isEmpty())
                            ) return index
                        else -> continue
                    }
                }
            }
        }
        for (index in runningIndexes.toList().asReversed()) {
            when (val item = items[index]) {
                is ChatDisplayItem.Edit ->
                    if (item.state.backend == backend && item.state.running && (path.isEmpty() || item.state.path == path)) return index
                is ChatDisplayItem.Tool ->
                    if (item.state.backend == backend && item.state.running && ChatToolState.isFileEditVerb(item.state.verb) &&
                        (path.isEmpty() || item.state.target == path)
                    ) return index
                else -> continue
            }
        }
        return null
    }

    for (ev in events) {
        val kind = (ev.str("kind") ?: "").lowercase()
        val inner = ev["event"] as? JsonObject
        if (kind == "user") {
            flushText()
            flushThinking()
            if (!ev.bol("steer")) {
                latestPlanID = null
                closeRunningTools(failed = false, at = atMsOf(ev, inner), detail = L10n.text("android.chattranscript.interrupted.132d124d"))
                toolIndexes.clear()
                editRevisions.clear()
            }
            items.add(
                ChatDisplayItem.User(
                    "user-${stamp(ev, items.size)}",
                    ev.str("text") ?: ev.str("body") ?: "",
                    isSteer = ev.bol("steer"),
                ),
            )
            continue
        }
        if (kind == "handoff") {
            flushText()
            flushThinking()
            val to = ev.str("to") ?: inner?.str("to") ?: ""
            items.add(
                ChatDisplayItem.Handoff(
                    "handoff-${stamp(ev, items.size)}",
                    to = to,
                    brief = ev.str("brief") ?: inner?.str("brief") ?: "",
                ),
            )
            if (to.isNotEmpty()) lastBackend = to
            continue
        }
        if (kind == "question") {
            val questionId = ev.str("id")
            val asked = ev.str("question")
            if (questionId != null && asked != null) {
                flushText()
                flushThinking()
                val fallback = ev.str("default")
                questionIndex[questionId] = items.size
                items.add(
                    ChatDisplayItem.Question(
                        "question-$questionId",
                        ChatQuestion(
                            id = questionId,
                            question = asked,
                            options = (ev["options"] as? JsonArray)?.mapNotNull { it.jsonPrimitive.contentOrNull }.orEmpty(),
                            multiple = ev.safeBool("multiple") ?: false,
                            defaultAnswer = fallback,
                            blocking = ev.safeBool("blocking") ?: (fallback == null),
                        ),
                    ),
                )
            }
            continue
        }
        if (kind == "answer" || kind == "answerwithdrawn") {
            val at = ev.str("questionId")?.let { questionIndex[it] }
            val row = at?.let { items.getOrNull(it) } as? ChatDisplayItem.Question
            if (at != null && row != null) {
                val question = if (kind == "answer") {
                    row.question.copy(answer = ev.str("text") ?: "", delivery = ev.str("delivery"))
                } else {
                    row.question.copy(answer = null, delivery = null)
                }
                items[at] = row.copy(question = question)
            }
            continue
        }
        val approval = ev["approval"] as? JsonObject
        if (approval != null || kind == "approval") {
            flushText()
            flushThinking()
            val raw = approval ?: ev
            val rowID = "approval-${raw.str("id") ?: stamp(ev, items.size)}"
            val at = approvalIndex[rowID]
            if (at != null && at in items.indices) {
                items[at] = ChatDisplayItem.Approval(rowID, raw)
            } else {
                approvalIndex[rowID] = items.size
                items.add(ChatDisplayItem.Approval(rowID, raw))
            }
            continue
        }
        if (inner == null) continue
        val eventBackend = ev.str("backend") ?: defaultBackend
        if (eventBackend != null && lastBackend != null && eventBackend != lastBackend) {
            flushText()
            flushThinking()
            items.add(ChatDisplayItem.TurnSeparator("turn-${stamp(ev, items.size)}", eventBackend))
        }
        if (eventBackend != null) lastBackend = eventBackend
        when ((inner.str("kind") ?: kind).lowercase()) {
            "plan" -> {
                flushText()
                flushThinking()
                val steps = (inner["steps"] as? JsonArray)?.filterIsInstance<JsonObject>() ?: continue
                latestPlanID?.let { supersededPlanIDs.add(it) }
                latestPlanID = null
                if (steps.isNotEmpty()) {
                    val planID = "plan-${stamp(ev, items.size)}"
                    latestPlanID = planID
                    items.add(ChatDisplayItem.Plan(planID,
                        steps.map { ChatPlanStep(it.str("text").orEmpty(), it.str("status").orEmpty()) }))
                }
            }
            "text", "agent" -> {
                flushThinking()
                if (text.isEmpty()) {
                    textID = "text-${stamp(ev, items.size)}"
                    textBackend = ev.str("backend") ?: defaultBackend
                }
                text.append(inner.str("delta") ?: inner.str("text") ?: ev.str("text") ?: "")
            }
            "thinking" -> {
                flushText()
                if (thinking.isEmpty()) thinkingID = "think-${stamp(ev, items.size)}"
                thinking.append(inner.str("delta") ?: inner.str("text") ?: "")
            }
            "toolstart", "tool_start", "tool" -> {
                flushText()
                flushThinking()
                val callId = inner.str("callId") ?: inner.str("call_id")
                    ?: "tool-${stamp(ev, items.size)}"
                val occurrence = (toolStarts[callId] ?: 0) + 1
                toolStarts[callId] = occurrence
                val rowID = if (ev.safeLong("seq") != null) {
                    "tool-${stamp(ev, items.size)}"
                } else if (occurrence == 1) {
                    "tool-$callId"
                } else {
                    "tool-$callId#$occurrence"
                }
                val verb = inner.str("verb") ?: ""
                val target = ChatToolState.clip(inner.str("target") ?: "")
                if (eventBackend != null) toolBackends[rowID] = eventBackend
                noteToolIndex(items.size, callId, eventBackend)
                val isStart = (inner.str("kind") ?: "").lowercase() != "tool"
                val isFileEdit = ChatToolState.isFileEditVerb(verb)
                if (isStart && (isFileEdit || inner.safeBool("running") != false)) {
                    runningIndexes.add(items.size)
                }
                if (isFileEdit) {
                    val path = target.ifEmpty { L10n.text("android.chattranscript.file.50009ce1") }
                    items.add(
                        ChatDisplayItem.Edit(
                            rowID,
                            ChatEditState(
                                path = path,
                                added = 0,
                                removed = 0,
                                patch = "",
                                revision = nextEditRevision(path),
                                running = isStart,
                                failed = inner.safeBool("failed") == true,
                                startedAtMs = atMsOf(ev, inner) ?: 0,
                                endedAtMs = null,
                                callId = callId,
                                backend = eventBackend,
                            ),
                        ),
                    )
                } else {
                    items.add(
                        ChatDisplayItem.Tool(
                            rowID,
                            ChatToolState(
                                callId = callId,
                                verb = verb,
                                target = target,
                                running = isStart && inner.safeBool("running") != false,
                                failed = inner.safeBool("failed") == true,
                                detail = inner.str("detail") ?: inner.str("snippet"),
                                startedAtMs = atMsOf(ev, inner) ?: 0,
                                endedAtMs = null,
                                snippet = ChatToolState.makeSnippet(
                                    verb,
                                    inner.str("detail") ?: inner.str("snippet"),
                                ),
                                backend = eventBackend,
                            ),
                        ),
                    )
                }
            }
            "toolend", "tool_end" -> {
                flushText()
                flushThinking()
                val callId = inner.str("callId") ?: inner.str("call_id") ?: ""
                val index = toolEndIndex(callId, eventBackend)
                if (index != null && index in items.indices) {
                    runningIndexes.remove(index)
                    when (val item = items[index]) {
                        is ChatDisplayItem.Tool -> {
                            val presentation = refineMuseToolPresentation(
                                toolBackends[item.id] ?: eventBackend,
                                item.state.verb,
                                item.state.target,
                                inner.str("detail"),
                            )
                            val state = item.state.copy(
                                verb = presentation.verb,
                                target = presentation.target,
                                running = false,
                                failed = !(inner.safeBool("ok") ?: true),
                                detail = inner.str("detail"),
                                snippet = ChatToolState.makeSnippet(
                                    presentation.verb,
                                    inner.str("detail"),
                                ),
                                endedAtMs = atMsOf(ev, inner),
                            )
                            items[index] = item.copy(state = state)
                        }
                        is ChatDisplayItem.Edit -> {
                            var state = item.state.copy(
                                running = false,
                                failed = !(inner.safeBool("ok") ?: true),
                                endedAtMs = atMsOf(ev, inner),
                            )
                            state = state.applyDetail(inner.str("detail"))
                            items[index] = item.copy(state = state)
                        }
                        else -> Unit
                    }
                } else if (ChatToolState.isFileEditVerb(inner.str("verb") ?: "")) {
                    val path = ChatToolState.clip(inner.str("target") ?: "").ifEmpty { L10n.text("android.chattranscript.file.50009ce1") }
                    var state = ChatEditState(
                        path = path,
                        added = 0,
                        removed = 0,
                        patch = "",
                        revision = nextEditRevision(path),
                        running = false,
                        failed = !(inner.safeBool("ok") ?: true),
                        startedAtMs = atMsOf(ev, inner) ?: 0,
                        endedAtMs = atMsOf(ev, inner),
                        callId = callId.takeIf { it.isNotEmpty() },
                        backend = eventBackend,
                    )
                    state = state.applyDetail(inner.str("detail"))
                    val rowID = if (ev.safeLong("seq") != null || callId.isEmpty()) {
                        "edit-${stamp(ev, items.size)}"
                    } else {
                        "edit-$callId"
                    }
                    noteToolIndex(items.size, callId, eventBackend)
                    items.add(ChatDisplayItem.Edit(rowID, state))
                } else {
                    val fallback = callId.ifEmpty { "end-${stamp(ev, items.size)}" }
                    val fallbackVerb = inner.str("verb") ?: ""
                    val presentation = refineMuseToolPresentation(eventBackend, fallbackVerb,
                        ChatToolState.clip(inner.str("target") ?: ""), inner.str("detail"))
                    val occurrence = (toolStarts[fallback] ?: 0) + 1
                    toolStarts[fallback] = occurrence
                    val rowID = if (ev.safeLong("seq") != null) {
                        "tool-${stamp(ev, items.size)}"
                    } else {
                        if (occurrence == 1) "tool-$fallback" else "tool-$fallback#$occurrence"
                    }
                    noteToolIndex(items.size, callId, eventBackend)
                    items.add(
                        ChatDisplayItem.Tool(
                            rowID,
                            ChatToolState(
                                callId = fallback,
                                verb = presentation.verb,
                                target = presentation.target,
                                running = false,
                                failed = !(inner.safeBool("ok") ?: true),
                                detail = inner.str("detail"),
                                startedAtMs = atMsOf(ev, inner) ?: 0,
                                endedAtMs = atMsOf(ev, inner),
                                snippet = ChatToolState.makeSnippet(presentation.verb, inner.str("detail")),
                                backend = eventBackend,
                            ),
                        ),
                    )
                }
            }
            "edit" -> {
                flushText()
                flushThinking()
                val callId = inner.str("callId") ?: inner.str("call_id") ?: ""
                val path = inner.str("path") ?: L10n.text("android.chattranscript.file.50009ce1")
                val added = (inner.safeLong("added") ?: 0L).coerceIn(0L, 4_294_967_295L)
                val removed = (inner.safeLong("removed") ?: 0L).coerceIn(0L, 4_294_967_295L)
                val patch = inner.str("patch") ?: ""
                val index = matchingEditIndex(callId, path, eventBackend)
                if (index != null && index in items.indices) {
                    when (val item = items[index]) {
                        is ChatDisplayItem.Edit -> {
                            var state = item.state.applyPatch(added, removed, patch)
                            if (state.path == "File" && path.isNotEmpty()) state = state.copy(path = path)
                            items[index] = item.copy(state = state)
                        }
                        is ChatDisplayItem.Tool -> {
                            var state = ChatEditState(
                                path = path,
                                added = added,
                                removed = removed,
                                patch = patch,
                                revision = nextEditRevision(path),
                                running = item.state.running,
                                failed = false,
                                startedAtMs = item.state.startedAtMs,
                                endedAtMs = if (item.state.running) null else (atMsOf(ev, inner) ?: item.state.endedAtMs),
                                callId = item.state.callId,
                                backend = item.state.backend,
                            )
                            state = state.recountIfNeeded()
                            items[index] = ChatDisplayItem.Edit(item.id, state)
                        }
                        else -> Unit
                    }
                    if (callId.isNotEmpty()) noteToolIndex(index, callId, eventBackend)
                } else {
                    var state = ChatEditState(
                        path = path,
                        added = added,
                        removed = removed,
                        patch = patch,
                        revision = nextEditRevision(path),
                        running = false,
                        failed = false,
                        startedAtMs = atMsOf(ev, inner) ?: 0,
                        endedAtMs = null,
                        callId = callId.takeIf { it.isNotEmpty() },
                        backend = eventBackend,
                    )
                    state = state.recountIfNeeded()
                    val rowID = if (ev.safeLong("seq") != null || callId.isEmpty()) {
                        "edit-${stamp(ev, items.size)}"
                    } else {
                        val occurrence = (editStarts[callId] ?: 0) + 1
                        editStarts[callId] = occurrence
                        if (occurrence == 1) "edit-$callId" else "edit-$callId#$occurrence"
                    }
                    if (callId.isNotEmpty()) noteToolIndex(items.size, callId, eventBackend)
                    items.add(ChatDisplayItem.Edit(rowID, state))
                }
            }
            "attachment" -> {
                flushText()
                flushThinking()
                val id = inner.str("id") ?: inner.str("attachmentId")
                if (id != null) {
                    items.add(
                        ChatDisplayItem.Attachment(
                            "attachment-$id",
                            attachmentId = id,
                            name = inner.str("name")?.ifEmpty { null } ?: L10n.text("android.chattranscript.attachment.040d2b36"),
                            mediaType = inner.str("mediaType") ?: inner.str("media_type"),
                            size = inner.safeLong("size"),
                            callId = (inner.str("callId") ?: inner.str("call_id"))?.takeIf { it.isNotBlank() },
                            backend = eventBackend,
                        ),
                    )
                }
            }
            "usage" -> {
                flushText()
                flushThinking()
                items.add(
                    ChatDisplayItem.Usage(
                        "usage-${stamp(ev, items.size)}",
                        input = inner.safeLong("input") ?: 0,
                        output = inner.safeLong("output") ?: 0,
                        costUsd = inner.safeDouble("costUsd") ?: inner.safeDouble("cost_usd"),
                    ),
                )
            }
            "failed" -> {
                flushText()
                flushThinking()
                closeRunningTools(failed = true, at = atMsOf(ev, inner), detail = inner.str("text"))
                items.add(
                    ChatDisplayItem.Failed(
                        "failed-${stamp(ev, items.size)}",
                        inner.str("text") ?: L10n.text("android.chattranscript.the_turn_failed.45783181"),
                    ),
                )
            }
            "done" -> {
                flushText()
                flushThinking()
                val status = inner.str("status") ?: ""
                val failed = status == "error"
                closeRunningTools(failed = failed, at = atMsOf(ev, inner), detail = if (failed) status else null)
            }
            else -> Unit
        }
    }
    flushText()
    flushThinking()
    if (!running) {
        closeRunningTools(failed = false, at = null, detail = L10n.text("android.chattranscript.ended_without_a_tool_result.da8d3680"))
    }
    return items.filterNot { it.id in supersededPlanIDs }
}
