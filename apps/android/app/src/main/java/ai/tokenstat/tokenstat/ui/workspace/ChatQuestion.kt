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
        val trimmed = line.trim()
        // The host reads the info string trimmed, so "``` tokenstat-question"
        // is a question there too and must not show as raw JSON here.
        val info = if (trimmed.startsWith("```")) trimmed.substring(3).trim() else ""
        if (!inside && (info == QUESTION_FENCE || info == PLAN_FENCE)) {
            inside = true
            isPlan = info == PLAN_FENCE
            block.clear()
            block.add(line)
            bodyBytes = 0
            continue
        }
        if (inside) {
            // Host closing_fence: ticks may share the line with the next
            // sentence (` ```Yes,...`), so trailing text stays as prose.
            // Probe the raw line (leading space/tab only) so a full trim
            // cannot eat spaces that belong to the glued sentence.
            val trailing = closingFenceTrailing(line)
            if (trailing != null) {
                val body = block.drop(1).joinToString("\n")
                val value = if (body.length < QUESTION_BLOCK_MAX_BYTES && body.toByteArray(Charsets.UTF_8).size < QUESTION_BLOCK_MAX_BYTES)
                    runCatching { Json.parseToJsonElement(body) as? JsonObject }.getOrNull() else null
                val question = value?.get("question") as? JsonPrimitive
                val valid = if (isPlan) value?.get("steps") is JsonArray
                    else question?.isString == true && question.content.isNotBlank()
                if (!valid) {
                    kept.addAll(block)
                    kept.add(line)
                } else if (trailing.isNotEmpty()) {
                    kept.add(trailing)
                }
                block.clear()
                inside = false
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

/** Prose after closing backticks, or empty when the line is only the fence. Null when it does not close. */
private fun closingFenceTrailing(line: String): String? {
    var index = 0
    while (index < line.length && (line[index] == ' ' || line[index] == '\t')) index++
    var ticks = 0
    while (index + ticks < line.length && line[index + ticks] == '`') ticks++
    if (ticks < 3) return null
    var trailing = line.substring(index + ticks)
    if (trailing.endsWith('\r')) trailing = trailing.dropLast(1)
    return trailing.trimStart(' ', '\t')
}
