// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
package ai.tokenstat.tokenstat.ui.workspace

import kotlinx.serialization.json.Json
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

/// The reply without its question blocks, which the card shows instead. A
/// block still streaming is cut from its opening line, so half a JSON object
/// never flashes on screen.
fun stripQuestionBlocks(text: String, streaming: Boolean = true): String {
    if (!text.contains("```$QUESTION_FENCE")) return text
    val kept = mutableListOf<String>()
    var inside = false
    val block = mutableListOf<String>()
    for (line in text.split("\n")) {
        val trimmed = line.trim()
        if (!inside && trimmed == "```$QUESTION_FENCE") {
            inside = true
            block.add(line)
            continue
        }
        if (inside) {
            block.add(line)
            if (trimmed == "```") {
                val value = runCatching { Json.parseToJsonElement(block.drop(1).dropLast(1).joinToString("\n")) as? JsonObject }.getOrNull()
                val question = value?.get("question") as? JsonPrimitive
                if (question?.isString != true || question.content.isBlank()) kept.addAll(block)
                block.clear()
                inside = false
            }
            continue
        }
        kept.add(line)
    }
    if (!streaming) kept.addAll(block)
    return kept.joinToString("\n").replace("\n\n\n", "\n\n").trim()
}
