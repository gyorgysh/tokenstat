// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
package ai.tokenstat.tokenstat.ecosystem

import android.content.Context
import android.content.Intent
import android.os.Build
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.asStateFlow

/** Incoming text stays a draft. Targeted shares retain the account/project boundary. */
object SystemShare {
    data class Draft(val text: String, val projectId: String?, val owner: String?, val sequence: Long)
    private val pending = MutableStateFlow<Draft?>(null)
    val draft = pending.asStateFlow()
    fun offer(intent: Intent?): String? {
        if (intent?.action != Intent.ACTION_SEND || intent.type !in setOf("text/plain", "text/uri-list")) return null
        val text = runCatching { intent.getCharSequenceExtra(Intent.EXTRA_TEXT)?.toString() }.getOrNull()
            ?.takeIf { it.isNotBlank() && it.length <= 100_000 } ?: return null
        val shortcut = if (Build.VERSION.SDK_INT >= 29) runCatching { intent.getStringExtra(Intent.EXTRA_SHORTCUT_ID) }.getOrNull() else null
        if (shortcut != null && !shortcut.startsWith("project.")) return null
        val targetId = shortcut?.removePrefix("project.")
        if (targetId != null && !targetId.matches(Regex("[0-9a-f]{64}"))) return null
        // Resolve after foreground account verification, including a cold start.
        pending.value = Draft(text, targetId, SystemProjects.find(targetId.orEmpty())?.owner ?: SystemProjects.owner, System.nanoTime())
        return targetId?.let { "project.$it" } ?: "workspaces"
    }
    fun take(value: Draft) = pending.compareAndSet(value, null)
    fun clear() { pending.value = null }
    fun send(context: Context, text: String) {
        if (text.isBlank()) return
        runCatching {
            context.startActivity(Intent.createChooser(Intent(Intent.ACTION_SEND).apply {
                type = "text/plain"; putExtra(Intent.EXTRA_TEXT, text)
            }, null).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK))
        }
    }
}
