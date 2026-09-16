// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
package ai.tokenstat.tokenstat.ui.workspace

import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.booleanOrNull
import kotlinx.serialization.json.doubleOrNull
import kotlinx.serialization.json.longOrNull

/// Transcript display items, ported from ChatModel.swift `ChatDisplayItem`.
///
/// The host sends fine-grained events: text arrives as deltas, tools as
/// start/end pairs keyed by call id. Rendering one card per event is the
/// flat transcript of separate fragment bubbles. `coalesceTranscript` folds
/// events into what the person reads: one assistant panel per prose run, one
/// tool row per call, one edit card per file.
sealed interface ChatDisplayItem {
    val id: String

    data class User(override val id: String, val text: String) : ChatDisplayItem
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
    ) : ChatDisplayItem

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
}

/// A tool call on a transcript. Ported from ChatModel.swift `ChatToolState`.
data class ChatToolState(
    val callId: String,
    val verb: String,
    val target: String,
    val running: Boolean,
    val failed: Boolean,
    val detail: String?,
    val startedAtMs: Long,
    val endedAtMs: Long?,
    /// Display lines, split once at construction. A row reads them half a
    /// dozen times per draw and Codex shell outputs reach megabytes, so the
    /// full text stays in `detail` and the row only ever draws these.
    val snippet: List<String>,
) {
    val duration: String? get() = ChatClock.duration(startedAtMs, endedAtMs)

    companion object {
        fun isFileEditVerb(verb: String): Boolean = verb == "Edit" || verb == "NotebookEdit"

        /// Display lines for one detail string, split once. An edit's
        /// red/green lines reach the row unprefixed so they keep their
        /// colour; other verbs keep the output marker on every line, so a
        /// shell trace like "+ set -x" never poses as a diff.
        fun makeSnippet(verb: String, detail: String?): List<String> {
            if (detail.isNullOrEmpty()) return emptyList()
            val lines = detail.split("\n")
            val isDiff = verb == "Edit" || verb == "NotebookEdit" || verb == "Diff"
            val out = lines.take(SnippetLineCap).map { line ->
                val shown = clip(line)
                if (isDiff && isDiffLine(shown)) shown else "| $shown"
            }
            return if (lines.size > SnippetLineCap) {
                out + "| … (${lines.size - SnippetLineCap} more)"
            } else {
                out
            }
        }

        /// A unified or old/new diff body line. File headers stay grey.
        fun isDiffLine(line: String): Boolean {
            val first = line.firstOrNull() ?: return false
            if (first != '+' && first != '-') return false
            return !(line.startsWith("+++ ") || line.startsWith("--- "))
        }

        /// Cut one line down to what a row can draw. A tool that answers in
        /// JSON answers in one forty-kilobyte line, and handing that to a
        /// stack that grows to fit is the hang: the cap stops the line that
        /// is really a document.
        fun clip(line: String): String {
            if (line.length <= SnippetColumnCap) return line
            return line.take(SnippetColumnCap) + "…"
        }

        private const val SnippetLineCap = 60
        private const val SnippetColumnCap = 600
    }
}

/// A file the agent changed. One card, not a tool row plus a second copy.
/// Ported from ChatModel.swift `ChatEditState`.
data class ChatEditState(
    val path: String,
    val added: Int,
    val removed: Int,
    val patch: String,
    /// 1-based count of this path since the last user message.
    val revision: Int,
    val running: Boolean,
    val failed: Boolean,
    val startedAtMs: Long,
    val endedAtMs: Long?,
) {
    val duration: String? get() = ChatClock.duration(startedAtMs, endedAtMs)

    val fileName: String get() = path.substringAfterLast('/').ifEmpty { path }

    /// Last two folders of the parent path, enough to tell two same-named
    /// files apart without drawing the whole absolute path as the title.
    val location: String
        get() {
            val folder = path.substringBeforeLast('/', "")
            if (folder.isEmpty() || folder == "/") return ""
            val parts = folder.split('/').filter { it.isNotEmpty() }
            if (parts.isEmpty()) return ""
            if (parts.size == 1) return parts[0]
            return parts.takeLast(2).joinToString("/")
        }

    /// Nil on the first change of a file in a turn. Later ones name themselves.
    val changeLabel: String? get() = if (revision >= 2) "${ChatClock.ordinal(revision)} change" else null

    fun applyPatch(added: Int, removed: Int, patch: String): ChatEditState {
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
        if (!(added == 0 && removed == 0 && patch.isNotEmpty())) return this
        var plus = 0
        var minus = 0
        for (line in patch.split("\n")) {
            if (!ChatToolState.isDiffLine(line)) continue
            if (line.firstOrNull() == '+') plus += 1
            if (line.firstOrNull() == '-') minus += 1
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

private fun JsonObject.safeInt(vararg keys: String): Int {
    for (key in keys) {
        val v = (this[key] as? JsonPrimitive)?.longOrNull
        if (v != null) return v.coerceIn(0, Int.MAX_VALUE.toLong()).toInt()
    }
    return 0
}

/// Fold raw timeline events into display items. A faithful port of
/// ChatModel.swift `ChatDisplayItem.coalesce`, reading the same JSON the
/// Apple client decodes into `ChatTimelineEvent` / `ChatAgentEvent`.
fun coalesceTranscript(
    events: List<JsonObject>,
    defaultBackend: String? = null,
    running: Boolean = true,
): List<ChatDisplayItem> {
    val items = mutableListOf<ChatDisplayItem>()
    // Every row a call id has started, oldest first. A call id is not
    // unique on every backend, so an End closes the oldest row still
    // running under that name rather than the newest start.
    val toolIndexes = mutableMapOf<String, MutableList<Int>>()
    val toolStarts = mutableMapOf<String, Int>()
    val editStarts = mutableMapOf<String, Int>()
    val approvalIndex = mutableMapOf<String, Int>()
    val editRevisions = mutableMapOf<String, Int>()
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
        val body = text.toString().trim()
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
        for (index in items.indices) {
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
    }

    fun nextEditRevision(path: String): Int {
        val n = (editRevisions[path] ?: 0) + 1
        editRevisions[path] = n
        return n
    }

    fun noteToolIndex(index: Int, callId: String) {
        if (callId.isEmpty()) return
        val indexes = toolIndexes.getOrPut(callId) { mutableListOf() }
        indexes.removeAll { it == index }
        indexes.add(index)
    }

    /// The row an End closes: the oldest one still running under this call
    /// id, or, for a repeat End with nothing left running, the newest row
    /// the id named.
    fun toolEndIndex(callId: String): Int? {
        if (callId.isEmpty()) return null
        val indexes = toolIndexes[callId] ?: return null
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

    fun matchingEditIndex(callId: String, path: String): Int? {
        if (callId.isNotEmpty()) {
            val indexes = toolIndexes[callId]
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
        for (index in items.indices.reversed()) {
            when (val item = items[index]) {
                is ChatDisplayItem.Edit ->
                    if (item.state.running && (path.isEmpty() || item.state.path == path)) return index
                is ChatDisplayItem.Tool ->
                    if (item.state.running && ChatToolState.isFileEditVerb(item.state.verb) &&
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
            // A new user turn bounds any tools left open by an interrupted
            // older turn, including histories recorded by older hosts.
            closeRunningTools(failed = false, at = atMsOf(ev, inner), detail = "Interrupted")
            editRevisions.clear()
            items.add(
                ChatDisplayItem.User(
                    "user-${stamp(ev, items.size)}",
                    ev.str("text") ?: ev.str("body") ?: "",
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
            // The separator would say the same thing twice, less well.
            if (to.isNotEmpty()) lastBackend = to
            continue
        }
        val approval = ev["approval"] as? JsonObject
        if (approval != null || kind == "approval") {
            flushText()
            flushThinking()
            // The timeline records an approval twice: once when the agent
            // paused, and again with the answer. Keep the row in the place
            // it happened and let the later state win.
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
            "text", "agent" -> {
                flushThinking()
                if (text.isEmpty()) {
                    textID = "text-${stamp(ev, items.size)}"
                    textBackend = ev.str("backend") ?: defaultBackend
                }
                // Older hosts fold tool one-liners into agent text ("Grep:
                // path"). iOS never sees those as tools either; the text
                // run keeps them inline like the Apple transcript does.
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
                val verb = inner.str("verb") ?: "Tool"
                val target = ChatToolState.clip(inner.str("target") ?: "")
                noteToolIndex(items.size, callId)
                // A bare "tool" event without a start/end pair arrives
                // already finished; only true starts run open.
                val isStart = (inner.str("kind") ?: "").lowercase() != "tool"
                if (ChatToolState.isFileEditVerb(verb)) {
                    val path = target.ifEmpty { "File" }
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
                            ),
                        ),
                    )
                }
            }
            "toolend", "tool_end" -> {
                flushText()
                flushThinking()
                val callId = inner.str("callId") ?: inner.str("call_id") ?: ""
                val index = toolEndIndex(callId)
                if (index != null && index in items.indices) {
                    when (val item = items[index]) {
                        is ChatDisplayItem.Tool -> {
                            val state = item.state.copy(
                                running = false,
                                failed = !(inner.safeBool("ok") ?: true),
                                detail = inner.str("detail"),
                                snippet = ChatToolState.makeSnippet(
                                    item.state.verb,
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
                    val path = ChatToolState.clip(inner.str("target") ?: "").ifEmpty { "File" }
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
                    )
                    state = state.applyDetail(inner.str("detail"))
                    val rowID = if (ev.safeLong("seq") != null || callId.isEmpty()) {
                        "edit-${stamp(ev, items.size)}"
                    } else {
                        "edit-$callId"
                    }
                    items.add(ChatDisplayItem.Edit(rowID, state))
                } else {
                    val fallback = callId.ifEmpty { "end-${stamp(ev, items.size)}" }
                    val fallbackVerb = inner.str("verb") ?: "Tool"
                    val rowID = if (ev.safeLong("seq") != null) {
                        "tool-${stamp(ev, items.size)}"
                    } else {
                        "tool-$fallback"
                    }
                    items.add(
                        ChatDisplayItem.Tool(
                            rowID,
                            ChatToolState(
                                callId = fallback,
                                verb = fallbackVerb,
                                target = ChatToolState.clip(inner.str("target") ?: ""),
                                running = false,
                                failed = !(inner.safeBool("ok") ?: true),
                                detail = inner.str("detail"),
                                startedAtMs = atMsOf(ev, inner) ?: 0,
                                endedAtMs = atMsOf(ev, inner),
                                snippet = ChatToolState.makeSnippet(fallbackVerb, inner.str("detail")),
                            ),
                        ),
                    )
                }
            }
            "edit" -> {
                flushText()
                flushThinking()
                val callId = inner.str("callId") ?: inner.str("call_id") ?: ""
                val path = inner.str("path") ?: "File"
                val added = inner.safeInt("added")
                val removed = inner.safeInt("removed")
                val patch = inner.str("patch") ?: ""
                val index = matchingEditIndex(callId, path)
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
                            )
                            state = state.recountIfNeeded()
                            items[index] = ChatDisplayItem.Edit(item.id, state)
                        }
                        else -> Unit
                    }
                    if (callId.isNotEmpty()) noteToolIndex(index, callId)
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
                    )
                    state = state.recountIfNeeded()
                    val rowID = if (ev.safeLong("seq") != null || callId.isEmpty()) {
                        "edit-${stamp(ev, items.size)}"
                    } else {
                        val occurrence = (editStarts[callId] ?: 0) + 1
                        editStarts[callId] = occurrence
                        if (occurrence == 1) "edit-$callId" else "edit-$callId#$occurrence"
                    }
                    if (callId.isNotEmpty()) noteToolIndex(items.size, callId)
                    items.add(ChatDisplayItem.Edit(rowID, state))
                }
            }
            "attachment" -> {
                flushText()
                flushThinking()
                // An attachment without an id carries nothing to download.
                val id = inner.str("id") ?: inner.str("attachmentId")
                if (id != null) {
                    items.add(
                        ChatDisplayItem.Attachment(
                            "attachment-$id",
                            attachmentId = id,
                            name = inner.str("name")?.ifEmpty { null } ?: "Attachment",
                            mediaType = inner.str("mediaType") ?: inner.str("media_type"),
                            size = inner.safeLong("size"),
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
                        // Tool calls send `input` as an object; the row
                        // ignores it so usage still decodes.
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
                        inner.str("text") ?: "The turn failed",
                    ),
                )
            }
            "done" -> {
                flushText()
                flushThinking()
                val status = inner.str("status") ?: ""
                // Only the host's process outcome can fail a turn.
                val failed = status == "error"
                closeRunningTools(failed = failed, at = atMsOf(ev, inner), detail = if (failed) status else null)
            }
            else -> Unit
        }
    }
    flushText()
    flushThinking()
    // Tool logs are history; only the host knows whether a process lives.
    if (!running) {
        closeRunningTools(failed = false, at = null, detail = "Ended without a tool result")
    }
    return items
}
