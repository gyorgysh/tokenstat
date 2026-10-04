// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
package ai.tokenstat.tokenstat.ui.workspace

import android.content.Context

/// How much of an agent's work a transcript shows between a question and
/// its answer. Port of ChatTranscriptFold.swift `ChatDetail`.
///
/// Every level keeps what a person has to see: the question, every reply, an
/// approval the agent is waiting on, a failure, a handoff and an attachment.
enum class ChatDetail(val key: String) {
    /// One line per stretch of work: "Worked 3m · 14 steps · 2 files".
    Compact("compact"),
    /// Thinking and runs of reads and searches fold to one line each.
    Standard("standard"),
    /// Every step on its own row, with its output open.
    Detailed("detailed"),
    ;

    companion object {
        fun fromKey(key: String?): ChatDetail? = entries.firstOrNull { it.key == key }
    }
}

/// One folded line standing in for several transcript rows. Port of
/// `ChatStepGroup`.
data class ChatStepGroup(
    val style: Style,
    val open: Boolean,
    /// The rows this line stands for, oldest first.
    val memberIds: List<String>,
    /// Tool calls and edits. Thinking and in-between text are not steps.
    val steps: Int = 0,
    val files: Int = 0,
    val added: Int = 0,
    val removed: Int = 0,
    val reads: Int = 0,
    val searches: Int = 0,
    val pages: Int = 0,
    /// Still being added to.
    val running: Boolean = false,
    val liveVerb: String? = null,
    val liveTarget: String? = null,
    val startedAtMs: Long? = null,
    val endedAtMs: Long? = null,
    /// The turn's reported spend, in Compact, where its usage row is not drawn.
    val cost: Double? = null,
    /// The first line of a folded thought.
    val preview: String? = null,
) {
    enum class Style { Work, Explored, Thought }
}

/// The detail level, kept on this device the way the Apple client keeps it
/// in UserDefaults. A phone defaults to Compact, a tablet to Standard.
class ChatDetailStore(private val context: Context) {
    private val prefs = context.getSharedPreferences("tokenstat.chat.v1", Context.MODE_PRIVATE)

    fun level(): ChatDetail =
        ChatDetail.fromKey(prefs.getString("detail", null)) ?: platformDefault()

    fun setLevel(level: ChatDetail) {
        prefs.edit().putString("detail", level.key).apply()
    }

    private fun platformDefault(): ChatDetail =
        if (context.resources.configuration.smallestScreenWidthDp >= 600) ChatDetail.Standard else ChatDetail.Compact
}

private val readVerbs = setOf("Read")
private val searchVerbs = setOf("Grep", "Search", "Glob", "Find", "WebSearch")
private val pageVerbs = setOf("WebFetch")

private fun isExploration(verb: String): Boolean =
    verb in readVerbs || verb in searchVerbs || verb in pageVerbs

/// A group's row id. Named after its first step, so it holds while a live
/// turn adds steps and when an older page lands above.
fun stepGroupId(firstMember: String): String = "g:$firstMember"

/// Folds coalesced rows into what a detail level shows. Port of
/// `ChatTranscriptFold.fold`. Detailed is the identity. An open group is
/// its header followed by its steps as `GroupStep` rows, never one tall row.
fun foldTranscript(
    items: List<ChatDisplayItem>,
    detail: ChatDetail,
    running: Boolean,
    isOpen: (String) -> Boolean,
): List<ChatDisplayItem> = when (detail) {
    ChatDetail.Detailed -> items
    ChatDetail.Standard -> foldStandard(items, running, isOpen)
    ChatDetail.Compact -> foldCompact(items, running, isOpen)
}

/// The group header standing for `id`, when `id` is one of a closed group's
/// steps. Null when the row is drawn as itself or is not here.
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
        // One read is a row like any other.
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
                // Reasoning still arriving stays open. It folds once
                // anything comes after it.
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

private fun foldCompact(
    items: List<ChatDisplayItem>,
    running: Boolean,
    isOpen: (String) -> Boolean,
): List<ChatDisplayItem> {
    val out = ArrayList<ChatDisplayItem>()
    // A turn runs from one question to the next. Rows before the first
    // question (a window that opens mid-turn) are a turn of their own.
    val starts = items.indices.filter { items[it] is ChatDisplayItem.User }.toMutableList()
    if (starts.firstOrNull() != 0) starts.add(0, 0)
    starts.forEachIndexed { n, start ->
        if (start >= items.size) return@forEachIndexed
        val end = if (n + 1 < starts.size) starts[n + 1] else items.size
        foldCompactTurn(items.subList(start, end), running && end == items.size, isOpen, out)
    }
    return out
}

private fun foldCompactTurn(
    turn: List<ChatDisplayItem>,
    live: Boolean,
    isOpen: (String) -> Boolean,
    out: MutableList<ChatDisplayItem>,
) {
    val members = ArrayList<ChatDisplayItem>()
    val usage = ArrayList<ChatDisplayItem>()
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
        emitGroup(group, members.toList(), out, isOpen)
        members.clear()
    }

    turn.forEach { item ->
        when {
            item is ChatDisplayItem.Usage -> {
                cost += item.costUsd ?: 0.0
                usage.add(item)
            }
            item is ChatDisplayItem.Thinking -> members.add(item)
            item is ChatDisplayItem.Tool && !item.state.failed -> members.add(item)
            item is ChatDisplayItem.Edit && !item.state.failed -> members.add(item)
            else -> {
                // Replies, questions, failures and handoffs stay in order.
                flush(trailing = false)
                out.add(item)
            }
        }
    }
    flush(trailing = true)

    // The spend rides on the turn's last work line. A turn with no work to
    // fold keeps its usage rows, or the figure would just vanish.
    val header = out.getOrNull(lastHeader) as? ChatDisplayItem.Group
    if (lastHeader >= 0 && header != null) {
        if (cost > 0) out[lastHeader] = header.copy(group = header.group.copy(cost = cost))
    } else {
        out.addAll(usage)
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
    if (open) members.forEach { out.add(ChatDisplayItem.GroupStep(it.id, id, it)) }
}

private fun makeGroup(style: ChatStepGroup.Style, members: List<ChatDisplayItem>, running: Boolean): ChatStepGroup {
    var steps = 0
    var reads = 0
    var searches = 0
    var pages = 0
    var added = 0
    var removed = 0
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
    return ChatStepGroup(
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
        // A step still running is running whatever came after it.
        running = anyRunning || running,
        liveVerb = liveVerb,
        liveTarget = liveTarget,
        startedAtMs = started,
        endedAtMs = ended,
    )
}

/// The first line that says something, without its markdown marks.
fun thoughtPreview(text: String): String? {
    val marks = "#*_>`- "
    for (line in text.split("\n")) {
        val plain = line.trim().trim { it in marks }.trim()
        if (plain.isNotEmpty()) return plain.take(160)
    }
    return null
}
