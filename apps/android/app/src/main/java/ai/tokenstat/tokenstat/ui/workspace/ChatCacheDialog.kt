// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
package ai.tokenstat.tokenstat.ui.workspace

import ai.tokenstat.tokenstat.ui.localization.L10n
import ai.tokenstat.tokenstat.ui.logic.ChatCacheRules
import android.content.Context
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.Checkbox
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.unit.dp

/// One question about reading a whole conversation again.
internal sealed interface ChatCacheQuestion {
    val tokens: Long

    /// Sending after the prompt cache expired. `canStartNew` is false when
    /// the message carries files uploaded into this chat, or the host is too
    /// old to start a continuing chat.
    data class Idle(val idleMs: Long, override val tokens: Long, val canStartNew: Boolean) : ChatCacheQuestion

    data class ModelSwitch(val from: String?, val to: String, override val tokens: Long) : ChatCacheQuestion
}

internal enum class ChatCacheAnswer { PROCEED, START_NEW, CANCEL }

/// "Don't ask again", kept per question on this device.
internal object ChatCacheSuppression {
    private fun prefs(context: Context) = context.getSharedPreferences("chat-cache-warnings", Context.MODE_PRIVATE)
    private fun key(question: ChatCacheQuestion) = if (question is ChatCacheQuestion.Idle) "idle" else "model"
    fun idle(context: Context) = prefs(context).getBoolean("idle", false)
    fun model(context: Context) = prefs(context).getBoolean("model", false)
    fun suppress(context: Context, question: ChatCacheQuestion) =
        prefs(context).edit().putBoolean(key(question), true).apply()
}

private fun modelName(id: String?) = id?.takeIf(String::isNotBlank) ?: L10n.text("common.chat.cache.default_model")

@Composable
internal fun ChatCacheDialog(question: ChatCacheQuestion, context: Context, answer: (ChatCacheAnswer) -> Unit) {
    var suppressed by remember(question) { mutableStateOf(false) }
    fun reply(value: ChatCacheAnswer) {
        if (suppressed && value != ChatCacheAnswer.CANCEL) ChatCacheSuppression.suppress(context, question)
        answer(value)
    }
    val size = ChatCacheRules.tokenCount(question.tokens)
    val (title, message) = when (question) {
        is ChatCacheQuestion.Idle -> L10n.text("common.chat.cache.resume_title") to buildString {
            append(L10n.text("common.chat.cache.resume_message", ChatCacheRules.duration(question.idleMs), size))
            if (question.canStartNew) append("\n\n").append(L10n.text("common.chat.cache.resume_new_hint"))
        }
        is ChatCacheQuestion.ModelSwitch -> L10n.text("common.chat.cache.switch_title") to
            L10n.text("common.chat.cache.switch_message", modelName(question.from), modelName(question.to), size)
    }
    AlertDialog(
        onDismissRequest = { answer(ChatCacheAnswer.CANCEL) },
        title = { Text(title) },
        text = {
            Column(verticalArrangement = Arrangement.spacedBy(12.dp)) {
                Text(message)
                Row(verticalAlignment = Alignment.CenterVertically) {
                    Checkbox(checked = suppressed, onCheckedChange = { suppressed = it })
                    Text(L10n.text("common.chat.cache.dont_ask_again"))
                }
            }
        },
        confirmButton = {
            if (question is ChatCacheQuestion.Idle && question.canStartNew) {
                Row {
                    TextButton(onClick = { reply(ChatCacheAnswer.PROCEED) }) { Text(L10n.text("common.chat.cache.send_here")) }
                    TextButton(onClick = { reply(ChatCacheAnswer.START_NEW) }) { Text(L10n.text("common.chat.cache.start_new")) }
                }
            } else {
                val label = if (question is ChatCacheQuestion.Idle) "common.chat.cache.send_here" else "common.chat.cache.switch_model"
                TextButton(onClick = { reply(ChatCacheAnswer.PROCEED) }) { Text(L10n.text(label)) }
            }
        },
        dismissButton = {
            TextButton(onClick = { answer(ChatCacheAnswer.CANCEL) }) { Text(L10n.text("common.cancel")) }
        },
    )
}
