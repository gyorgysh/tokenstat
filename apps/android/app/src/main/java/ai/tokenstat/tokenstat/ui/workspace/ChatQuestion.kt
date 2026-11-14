// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
package ai.tokenstat.tokenstat.ui.workspace

import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive

/// A question the agent asked in its reply, and the answer once there is one.
/// Port of ChatQuestion.swift. The host finds the block and records it.
data class ChatQuestion(
    val id: String,
    val question: String,
    val options: List<String>,
    val multiple: Boolean,
    /// What the agent goes with if nobody answers.
    val defaultAnswer: String?,
    /// The agent stopped for this rather than carrying on with its default.
    val blocking: Boolean,
    val answer: String? = null,
    /// `note` rode the running turn, `queued` waits for it to end, `sent`
    /// started a turn.
    val delivery: String? = null,
)

const val QUESTION_FENCE = "tokenstat-question"
/// A plan the agent wrote for the activity panel. The host reads it, so the
/// reply drops it the same way.
const val PLAN_FENCE = "tokenstat-plan"
// Match the host scanner, including the newline before the closing fence.
private const val QUESTION_BLOCK_MAX_BYTES = 64 * 1024

/// The reply without its question blocks, which the card shows instead. A
/// block still streaming is cut from its opening line, so half a JSON object
/// never flashes on screen.
fun stripQuestionBlocks(text: String, streaming: Boolean = true): String {
    if (!text.contains(QUESTION_FENCE) && !text.contains(PLAN_FENCE)) return text
    val kept = mutableListOf<String>()
    var inside = false
    var isPlan = false
    val block = mutableListOf<String>()
    var bodyBytes = 0L
    val lines = text.split("\n")
    for ((index, line) in lines.withIndex()) {
        if (!inside) {
            opening(line)?.let { open ->
                if (open.prefix.isNotEmpty()) kept.add(open.prefix)
                inside = true
                isPlan = open.isPlan
                block.clear()
                block.add(open.fenceLine)
                bodyBytes = 0
                open.sameLineBody?.let { same ->
                    val closed = closeBodyLine(same, block, isPlan, kept)
                    if (closed != null) {
                        inside = closed.first
                        isPlan = closed.second
                        bodyBytes = 0
                    } else {
                        block.add(same)
                        bodyBytes = same.toByteArray(Charsets.UTF_8).size.toLong()
                    }
                }
                continue
            }
        }
        if (inside) {
            val closed = closeBodyLine(line, block, isPlan, kept)
            if (closed != null) {
                inside = closed.first
                isPlan = closed.second
                bodyBytes = 0
            } else {
                block.add(line)
                bodyBytes += line.toByteArray(Charsets.UTF_8).size + if (index < lines.lastIndex) 1 else 0
                if (bodyBytes > QUESTION_BLOCK_MAX_BYTES) {
                    kept.addAll(block)
                    block.clear()
                    inside = false
                }
            }
            continue
        }
        kept.add(line)
    }
    if (!streaming) kept.addAll(block)
    return kept.joinToString("\n").replace("\n\n\n", "\n\n").trim()
}

private data class FenceOpening(val prefix: String, val fenceLine: String, val sameLineBody: String?, val isPlan: Boolean)
private data class FenceMatch(val language: String, val body: String?, val isPlan: Boolean)
private data class FenceClose(val bodyPrefix: String, val trailing: String)

private fun opening(line: String): FenceOpening? {
    var index = 0
    while (index <= line.length - 3) {
        val tick = line.indexOf("```", index)
        if (tick < 0) return null
        val after = line.substring(tick + 3)
        val headerEnd = after.indexOf('\n').let { if (it < 0) after.length else it }
        val header = after.substring(0, headerEnd).removeSuffix("\r")
        fenceBody(header)?.let { matched ->
            val prefix = line.substring(0, tick).trim()
            return FenceOpening(prefix, "```${matched.language}", matched.body, matched.isPlan)
        }
        index = tick + 3
    }
    return null
}

private fun fenceBody(header: String): FenceMatch? {
    val trimmed = header.trim()
    for ((name, isPlan) in listOf(PLAN_FENCE to true, QUESTION_FENCE to false)) {
        if (trimmed == name) return FenceMatch(name, null, isPlan)
        if (!trimmed.startsWith(name)) continue
        val rest = trimmed.substring(name.length)
        if (!rest.first().isWhitespace()) continue
        val body = rest.trimStart()
        // Prose after the language tag is not a block. The body is a JSON
        // object, so a same-line body must open one.
        if (!body.startsWith("{")) continue
        return FenceMatch(name, body, isPlan)
    }
    return null
}

private fun closeBodyLine(
    line: String,
    block: MutableList<String>,
    isPlan: Boolean,
    kept: MutableList<String>,
): Pair<Boolean, Boolean>? {
    val closed = closingFence(line) ?: return null
    if (closed.bodyPrefix.isNotEmpty()) block.add(closed.bodyPrefix)
    val body = block.drop(1).joinToString("\n")
    val value = if (body.toByteArray(Charsets.UTF_8).size < QUESTION_BLOCK_MAX_BYTES)
        runCatching { Json.parseToJsonElement(body) as? JsonObject }.getOrNull() else null
    val question = value?.get("question") as? JsonPrimitive
    val valid = if (isPlan) value?.get("steps") is JsonArray
        else question?.isString == true && question.content.isNotBlank()
    val next = closed.trailing.trim(' ', '\t')
    val nextInfo = if (next.startsWith("```")) fenceBody(next.substring(3)) else null
    if (!valid) {
        kept.addAll(block)
        if (closed.bodyPrefix.isEmpty()) {
            kept.add(if (nextInfo != null) line.dropLast(closed.trailing.length) else line)
        } else if (nextInfo == null && closed.trailing.isNotEmpty()) {
            kept.add(closed.trailing)
        }
    } else if (closed.trailing.isNotEmpty() && nextInfo == null) {
        kept.add(closed.trailing)
    }
    block.clear()
    if (nextInfo != null) {
        block.add("```${nextInfo.language}")
        return true to nextInfo.isPlan
    }
    return false to isPlan
}

private fun closingFence(line: String): FenceClose? {
    var index = 0
    while (index < line.length && (line[index] == ' ' || line[index] == '\t')) index++
    var ticks = 0
    while (index + ticks < line.length && line[index + ticks] == '`') ticks++
    if (ticks >= 3) {
        val afterRun = line.substring(index + ticks).trimStart(' ', '\t')
        if (ticks >= 6 && afterRun.firstOrNull()?.let { it in 'a'..'z' || it in 'A'..'Z' } == true) {
            return FenceClose("", line.substring(index + 3).removeSuffix("\r"))
        }
        var trailing = line.substring(index + ticks)
        if (trailing.endsWith('\r')) trailing = trailing.dropLast(1)
        return FenceClose("", trailing.trimStart(' ', '\t'))
    }
    return trailingClose(line)
}

private fun trailingClose(line: String): FenceClose? {
    var index = 0
    while (index <= line.length - 3) {
        val tick = line.indexOf("```", index)
        if (tick < 0) return null
        val before = line.substring(0, tick)
        if (before.trim().isEmpty()) {
            index = tick + 3
            continue
        }
        var ticks = 0
        while (tick + ticks < line.length && line[tick + ticks] == '`') ticks++
        val afterRun = line.substring(tick + ticks).trimStart(' ', '\t')
        if (ticks >= 6 && afterRun.firstOrNull()?.let { it in 'a'..'z' || it in 'A'..'Z' } == true) {
            return FenceClose(before, line.substring(tick + 3).removeSuffix("\r"))
        }
        var trailing = line.substring(tick + ticks)
        if (trailing.endsWith('\r')) trailing = trailing.dropLast(1)
        return FenceClose(before, trailing.trimStart(' ', '\t'))
    }
    return null
}
