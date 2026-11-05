// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
package ai.tokenstat.tokenstat.ui.workspace

import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.LinearProgressIndicator
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import ai.tokenstat.tokenstat.ui.connection.formatTrafficBytes
import ai.tokenstat.tokenstat.ui.localization.L10n
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.contentOrNull
import kotlinx.serialization.json.longOrNull
import kotlinx.coroutines.CancellationException

/** Account counters belong to the device starting the transfer, not its remote host. */
internal data class ChatRelayAllowance(val used: Long, val limit: Long, val remaining: Long) {
    val fraction: Float get() = if (limit > 0) (used.toDouble() / limit).coerceIn(0.0, 1.0).toFloat() else 0f

    companion object {
        fun from(account: JsonObject?): ChatRelayAllowance? {
            val usage = account?.get("relayUsage") as? JsonObject ?: return null
            fun text(key: String) = (usage[key] as? JsonPrimitive)?.contentOrNull
            fun number(key: String) = (usage[key] as? JsonPrimitive)?.longOrNull?.takeIf { it >= 0 }
            if (text("policy") != "rolling_30_utc_days" || number("windowDays") != 30L || text("timezone") != "UTC") return null
            return ChatRelayAllowance(number("usedBytes") ?: return null,
                number("limitBytes") ?: return null, number("remainingBytes") ?: return null)
        }
    }
}

@Composable
internal fun ChatFileRelayDialog(name: String, size: Long?, remaining: Long?, account: JsonObject?,
    loadAllowance: (suspend () -> JsonObject?)? = null, answer: (Boolean) -> Unit) {
    fun identity(value: JsonObject?) = listOf("host", "accountId", "handle", "accountSession").map { value?.get(it) }
    val owner = identity(account)
    var refreshed by remember(owner) { mutableStateOf<JsonObject?>(null) }
    LaunchedEffect(owner) {
        try {
            val fresh = loadAllowance?.invoke()
            if (owner.any { it != null } && identity(fresh) == owner) refreshed = fresh
        } catch (cancelled: CancellationException) { throw cancelled }
        catch (_: Exception) { /* Keep the last known counters available. */ }
    }
    val usage = ChatRelayAllowance.from(refreshed ?: account)
    val usageLabel = L10n.text("common.chat_files_relay_usage_label")
    AlertDialog(
        onDismissRequest = { answer(false) },
        title = { Text(L10n.text("common.chat_files_relay_title")) },
        text = {
            Column(modifier = Modifier.verticalScroll(rememberScrollState()), verticalArrangement = Arrangement.spacedBy(12.dp)) {
                Text(L10n.text("common.chat_files_relay_explanation"))
                Column {
                    Text(name, fontWeight = FontWeight.SemiBold, maxLines = 3, overflow = TextOverflow.Ellipsis)
                    Text(size?.let(::formatTrafficBytes) ?: L10n.text("common.chat_files_size_unknown"))
                }
                HorizontalDivider()
                if (usage != null) {
                    Text(L10n.text("common.chat_files_relay_used", formatTrafficBytes(usage.used), formatTrafficBytes(usage.limit)), fontWeight = FontWeight.SemiBold)
                    LinearProgressIndicator(progress = { usage.fraction }, modifier = Modifier.fillMaxWidth().semantics { contentDescription = usageLabel })
                    Text(L10n.text("common.chat_files_relay_available", formatTrafficBytes(usage.remaining)))
                    Text(L10n.text("common.chat_files_relay_allowance"))
                } else {
                    remaining?.takeIf { it >= 0 }?.let { Text(L10n.text("common.chat_files_relay_available", formatTrafficBytes(it))) }
                    Text(L10n.text("common.chat_files_relay_usage_unknown"))
                }
                Text(L10n.text("common.chat_files_relay_reporting"), style = MaterialTheme.typography.bodySmall)
            }
        },
        confirmButton = { TextButton(onClick = { answer(true) }) { Text(L10n.text("common.continue")) } },
        dismissButton = { TextButton(onClick = { answer(false) }) { Text(L10n.text("common.cancel")) } },
    )
}
