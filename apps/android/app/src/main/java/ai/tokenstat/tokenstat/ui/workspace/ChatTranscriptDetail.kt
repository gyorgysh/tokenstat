// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
package ai.tokenstat.tokenstat.ui.workspace

import android.content.Context

enum class ChatDetail(val key: String) {
    Minimal("minimal"),
    Compact("compact"),
    Standard("standard"),
    Detailed("detailed"),
    ;

    companion object {
        fun fromKey(key: String?): ChatDetail? = entries.firstOrNull { it.key == key }
    }
}

data class ChatStepGroup(
    val style: Style,
    val open: Boolean,
    val memberIds: List<String>,
    val steps: Int = 0,
    val files: Int = 0,
    val added: Long = 0,
    val removed: Long = 0,
    val reads: Int = 0,
    val searches: Int = 0,
    val pages: Int = 0,
    val failures: Int = 0,
    val running: Boolean = false,
    val liveVerb: String? = null,
    val liveTarget: String? = null,
    val startedAtMs: Long? = null,
    val endedAtMs: Long? = null,
    val cost: Double? = null,
    val preview: String? = null,
    val plain: Boolean = false,
    val verb: String? = null,
    val subject: String? = null,
) {
    enum class Style { Work, Explored, Thought, Step }
}

enum class PlainStep {
    Detail,
    Line,
}

class ChatDetailStore(context: Context) {
    private val prefs = context.getSharedPreferences("tokenstat.chat.v1", Context.MODE_PRIVATE)

    fun level(): ChatDetail {
        ChatDetail.fromKey(prefs.getString(KEY, null))?.let { return it }
        val moved = prefs.getString(PREVIOUS_KEY, null)?.let(::renamedDetail) ?: return ChatDetail.Compact
        setLevel(moved)
        return moved
    }

    fun smoothStreaming(): Boolean = prefs.getBoolean("smoothStreaming", true)
    fun setSmoothStreaming(enabled: Boolean) { prefs.edit().putBoolean("smoothStreaming", enabled).apply() }

    fun setLevel(level: ChatDetail) {
        prefs.edit().putString(KEY, level.key).apply()
    }

    private companion object {
        const val KEY = "detailLevel"
        const val PREVIOUS_KEY = "detail"
    }
}

fun renamedDetail(key: String): ChatDetail? = when (key) {
    "minimal" -> ChatDetail.Compact
    "compact" -> ChatDetail.Minimal
    else -> ChatDetail.fromKey(key)
}

private val readVerbs = setOf("Read")
private val searchVerbs = setOf("Grep", "Search", "Glob", "Find", "WebSearch")
private val pageVerbs = setOf("WebFetch")

private fun isExploration(verb: String): Boolean =
    verb in readVerbs || verb in searchVerbs || verb in pageVerbs

fun stepGroupId(firstMember: String): String = "g:$firstMember"

fun foldTranscript(
    items: List<ChatDisplayItem>,
    detail: ChatDetail,
    running: Boolean,
    isOpen: (String) -> Boolean,
): List<ChatDisplayItem> {
    val folded = when (detail) {
        ChatDetail.Detailed -> items
        ChatDetail.Standard -> foldStandard(items, running, isOpen)
        ChatDetail.Minimal -> foldMinimal(items, running, isOpen)
        ChatDetail.Compact -> foldCompact(items, running, isOpen)
    }
    return withTurnChanges(folded, items, running)
}

fun withTurnChanges(
    folded: List<ChatDisplayItem>,
    raw: List<ChatDisplayItem>,
    running: Boolean,
): List<ChatDisplayItem> {
    val changes = HashMap<Int, ChatDisplayItem.Changes>()
    var turn = 0
    var id = ""
    data class Accumulator(var added: Long = 0, var removed: Long = 0, val patches: MutableList<String> = mutableListOf())
    val files = LinkedHashMap<String, Accumulator>()
    fun close() {
        if (files.isNotEmpty()) changes[turn] = ChatDisplayItem.Changes(id, files.map { (path, value) ->
            ChangedFile(path, value.added, value.removed, value.patches.toList())
        })
        files.clear()
    }
    for (item in raw) {
        when {
            item is ChatDisplayItem.User && !item.isSteer -> {
                close()
                turn++
            }
            item is ChatDisplayItem.Edit && !item.state.failed && !item.state.running -> {
                if (files.isEmpty()) id = "changes:${item.id}"
                val path = item.state.path
                val file = files.getOrPut(path) { Accumulator() }
                file.added += item.state.added
                file.removed += item.state.removed
                file.patches.add(item.state.patch)
            }
        }
    }
    close()
    if (changes.isEmpty()) return folded
    val out = ArrayList<ChatDisplayItem>(folded.size + changes.size)
    turn = 0
    for (item in folded) {
        if (item is ChatDisplayItem.User && !item.isSteer) {
            changes[turn]?.let { out.add(it) }
            turn++
        }
        out.add(item)
    }
    if (!running) changes[turn]?.let { out.add(it) }
    return out
}

private fun foldCompact(
    items: List<ChatDisplayItem>,
    running: Boolean,
    isOpen: (String) -> Boolean,
): List<ChatDisplayItem> {
    val out = ArrayList<ChatDisplayItem>(items.size)
    val run = ArrayList<ChatDisplayItem>()

    fun line(style: ChatStepGroup.Style, members: List<ChatDisplayItem>, live: Boolean) {
        emitGroup(makeGroup(style, members, live).copy(plain = true), members, out, isOpen)
    }

    fun flushRun(trailing: Boolean) {
        if (run.isNotEmpty()) line(ChatStepGroup.Style.Explored, run.toList(), running && trailing)
        run.clear()
    }

    items.forEachIndexed { index, item ->
        when {
            item is ChatDisplayItem.Tool && !item.state.failed && isExploration(item.state.verb) -> run.add(item)
            item is ChatDisplayItem.Thinking -> {
                flushRun(trailing = false)
                if (running && index == items.lastIndex) {
                    out.add(item)
                } else {
                    val group = makeGroup(ChatStepGroup.Style.Thought, listOf(item), false)
                        .copy(preview = thoughtPreview(item.text), plain = true)
                    emitGroup(group, listOf(item), out, isOpen)
                }
            }
            item is ChatDisplayItem.Tool -> {
                flushRun(trailing = false)
                line(ChatStepGroup.Style.Step, listOf(item), item.state.running)
            }
            item is ChatDisplayItem.Edit -> {
                flushRun(trailing = false)
                line(ChatStepGroup.Style.Step, listOf(item), item.state.running)
            }
            else -> {
                flushRun(trailing = false)
                out.add(item)
            }
        }
    }
    flushRun(trailing = true)
    return out
}

fun stepGroupOwner(id: String, folded: List<ChatDisplayItem>): String? =
    folded.firstOrNull { it is ChatDisplayItem.Group && !it.group.open && id in it.group.memberIds }?.id

private fun foldStandard(
    items: List<ChatDisplayItem>,
    running: Boolean,
    isOpen: (String) -> Boolean,
): List<ChatDisplayItem> {
    val out = ArrayList<ChatDisplayItem>(items.size)
    val run = ArrayList<ChatDisplayItem>()

    fun flushRun(trailing: Boolean) {
        if (run.size >= 2) {
            emitGroup(makeGroup(ChatStepGroup.Style.Explored, run, running && trailing), run, out, isOpen)
        } else {
            out.addAll(run)
        }
        run.clear()
    }

    items.forEachIndexed { index, item ->
        when {
            item is ChatDisplayItem.Tool && !item.state.failed && isExploration(item.state.verb) -> run.add(item)
            item is ChatDisplayItem.Thinking -> {
                flushRun(trailing = false)
                if (running && index == items.lastIndex) {
                    out.add(item)
                } else {
                    val group = makeGroup(ChatStepGroup.Style.Thought, listOf(item), false)
                        .copy(preview = thoughtPreview(item.text))
                    emitGroup(group, listOf(item), out, isOpen)
                }
            }
            else -> {
                flushRun(trailing = false)
                out.add(item)
            }
        }
    }
    flushRun(trailing = true)
    return out
}

private fun foldMinimal(
    items: List<ChatDisplayItem>,
    running: Boolean,
    isOpen: (String) -> Boolean,
): List<ChatDisplayItem> {
    val out = ArrayList<ChatDisplayItem>()
    val starts = items.indices.filter { (items[it] as? ChatDisplayItem.User)?.isSteer == false }.toMutableList()
    if (starts.firstOrNull() != 0) starts.add(0, 0)
    starts.forEachIndexed { n, start ->
        if (start >= items.size) return@forEachIndexed
        val end = if (n + 1 < starts.size) starts[n + 1] else items.size
        foldMinimalTurn(items.subList(start, end), running && end == items.size, isOpen, out)
    }
    return out
}

private fun foldMinimalTurn(
    turn: List<ChatDisplayItem>,
    live: Boolean,
    isOpen: (String) -> Boolean,
    out: MutableList<ChatDisplayItem>,
) {
    val members = ArrayList<ChatDisplayItem>()
    val usage = ArrayList<ChatDisplayItem.Usage>()
    var cost = 0.0
    var lastHeader = -1

    fun flush(trailing: Boolean) {
        if (members.isEmpty()) return
        lastHeader = out.size
        val thoughtsOnly = members.all { it is ChatDisplayItem.Thinking }
        var group = makeGroup(
            if (thoughtsOnly) ChatStepGroup.Style.Thought else ChatStepGroup.Style.Work,
            members, live && trailing,
        )
        if (thoughtsOnly) {
            group = group.copy(preview = thoughtPreview((members.first() as ChatDisplayItem.Thinking).text))
        }
        if (live && trailing && members.lastOrNull() is ChatDisplayItem.Thinking) {
            group = group.copy(preview = thoughtPreview((members.last() as ChatDisplayItem.Thinking).text))
        }
        emitGroup(group, members.toList(), out, isOpen)
        members.clear()
    }

    turn.forEach { item ->
        when {
            item is ChatDisplayItem.Usage -> {
                cost += item.costUsd ?: 0.0
                usage.add(item)
            }
            item is ChatDisplayItem.Thinking || item is ChatDisplayItem.Tool || item is ChatDisplayItem.Edit -> members.add(item)
            else -> {
                flush(trailing = false)
                out.add(item)
            }
        }
    }
    flush(trailing = true)

    val header = out.getOrNull(lastHeader) as? ChatDisplayItem.Group
    val knownCost = cost.isFinite() && usage.all { row -> row.costUsd?.let { it.isFinite() && it >= 0 } == true }
    if (lastHeader >= 0 && header != null && knownCost && cost > 0) {
        out[lastHeader] = header.copy(group = header.group.copy(cost = cost))
    } else if (usage.isNotEmpty()) {
        fun sum(values: List<Long>): Long = values.fold(0L) { total, value ->
            val next = value.coerceAtLeast(0)
            if (Long.MAX_VALUE - total < next) Long.MAX_VALUE else total + next
        }
        out.add(ChatDisplayItem.Usage(usage.first().id, sum(usage.map { it.input }), sum(usage.map { it.output }),
            cost.takeIf { knownCost }))
    }
}

private fun emitGroup(
    group: ChatStepGroup,
    members: List<ChatDisplayItem>,
    out: MutableList<ChatDisplayItem>,
    isOpen: (String) -> Boolean,
) {
    val id = stepGroupId(members.first().id)
    val open = isOpen(id)
    out.add(ChatDisplayItem.Group(id, group.copy(open = open)))
    if (!open) return
    val plain = when {
        !group.plain || group.style == ChatStepGroup.Style.Thought -> null
        members.size == 1 -> PlainStep.Detail
        else -> PlainStep.Line
    }
    members.forEach { out.add(ChatDisplayItem.GroupStep(it.id, id, it, plain)) }
}

private fun makeGroup(style: ChatStepGroup.Style, members: List<ChatDisplayItem>, running: Boolean): ChatStepGroup {
    var steps = 0
    var reads = 0
    var searches = 0
    var pages = 0
    var failures = 0
    var added = 0L
    var removed = 0L
    val paths = HashSet<String>()
    var anyRunning = false
    var liveVerb: String? = null
    var liveTarget: String? = null
    var started: Long? = null
    var ended: Long? = null

    fun span(start: Long, end: Long?) {
        if (start > 0) started = minOf(started ?: start, start)
        if (end != null && end > 0) ended = maxOf(ended ?: end, end)
    }

    for (member in members) {
        when (member) {
            is ChatDisplayItem.Tool -> {
                val state = member.state
                steps++
                if (state.failed) failures++
                if (state.verb in readVerbs) reads++
                if (state.verb in searchVerbs) searches++
                if (state.verb in pageVerbs) pages++
                span(state.startedAtMs, state.endedAtMs)
                if (state.running) {
                    anyRunning = true
                    liveVerb = state.verb
                    liveTarget = state.target
                }
            }
            is ChatDisplayItem.Edit -> {
                val state = member.state
                steps++
                if (state.failed) failures++
                paths.add(state.path)
                added += state.added
                removed += state.removed
                span(state.startedAtMs, state.endedAtMs)
                if (state.running) {
                    anyRunning = true
                    liveVerb = "Edit"
                    liveTarget = state.path
                }
            }
            else -> Unit
        }
    }
    val single = members.singleOrNull()
    return ChatStepGroup(
        verb = when (single) {
            is ChatDisplayItem.Tool -> single.state.verb
            is ChatDisplayItem.Edit -> "Edit"
            else -> null
        },
        subject = when (single) {
            is ChatDisplayItem.Tool -> single.state.target
            is ChatDisplayItem.Edit -> single.state.path
            else -> null
        },
        style = style,
        open = false,
        memberIds = members.map { it.id },
        steps = steps,
        files = paths.size,
        added = added,
        removed = removed,
        reads = reads,
        searches = searches,
        pages = pages,
        failures = failures,
        running = anyRunning || running,
        liveVerb = liveVerb,
        liveTarget = liveTarget,
        startedAtMs = started,
        endedAtMs = ended,
    )
}

fun thoughtPreview(text: String): String? {
    val marks = "#*_>`- "
    for (line in text.split("\n")) {
        val plain = line.trim().trim { it in marks }.trim()
        if (plain.isNotEmpty()) return plain.take(160)
    }
    return null
}
