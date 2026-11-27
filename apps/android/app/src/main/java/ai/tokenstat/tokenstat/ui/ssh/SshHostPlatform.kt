// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
package ai.tokenstat.tokenstat.ui.ssh

import android.content.Context
import androidx.compose.runtime.Composable
import androidx.compose.runtime.remember
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.booleanOrNull
import kotlinx.serialization.json.contentOrNull
import kotlinx.serialization.json.intOrNull

object SshHostPlatform {
    private const val STORE = "ai.tokenstat.ssh.platforms.v1"
    private const val MAX_ENTRIES = 128
    private const val MAX_AGE_MS = 90L * 24 * 60 * 60 * 1000

    data class Entry(
        val label: String,
        val hostname: String,
        val port: Int,
        val hostKeys: List<String>,
        val savedMs: Long,
    ) {
        fun serialize(): String = listOf(
            savedMs.toString(),
            port.toString(),
            hostname.replace("|", ""),
            hostKeys.joinToString(","),
            label.replace("|", " ").replace("\n", " "),
        ).joinToString("|")

        companion object {
            fun parse(raw: String?): Entry? {
                if (raw.isNullOrEmpty()) return null
                val parts = raw.split("|", limit = 5)
                if (parts.size != 5) return null
                val saved = parts[0].toLongOrNull() ?: return null
                val port = parts[1].toIntOrNull() ?: return null
                if (parts[4].isBlank()) return null
                return Entry(
                    label = parts[4],
                    hostname = parts[2],
                    port = port,
                    hostKeys = parts[3].split(",").filter { it.isNotEmpty() }.sorted(),
                    savedMs = saved,
                )
            }
        }
    }

    fun label(context: Context, host: JsonObject, nowMs: Long = System.currentTimeMillis()): String? {
        val id = host.sshString("id") ?: return null
        val entry = Entry.parse(
            context.getSharedPreferences(STORE, Context.MODE_PRIVATE).getString(id, null),
        ) ?: return null
        return validatedLabel(entry, host, nowMs)?.also {
            if (entry.hostKeys.isEmpty() && hostKeysOf(host).isNotEmpty()) {
                persist(context, id, entry.copy(hostKeys = hostKeysOf(host)))
            }
        } ?: run {
            if (nowMs - entry.savedMs >= MAX_AGE_MS) forget(context, id)
            null
        }
    }

    fun remember(context: Context, check: JsonObject, host: JsonObject, nowMs: Long = System.currentTimeMillis()) {
        val id = host.sshString("id") ?: return
        val label = cleanLabel(check) ?: return
        val prefs = context.getSharedPreferences(STORE, Context.MODE_PRIVATE)
        val entry = Entry(
            label = label,
            hostname = (host.sshString("hostname") ?: "").lowercase(),
            port = host["port"]?.let { (it as? JsonPrimitive)?.intOrNull } ?: 22,
            hostKeys = hostKeysOf(host),
            savedMs = nowMs,
        )
        val edit = prefs.edit().putString(id, entry.serialize())
        val all = prefs.all.keys
        if (all.size >= MAX_ENTRIES && !all.contains(id)) {
            val oldest = all.mapNotNull { key ->
                Entry.parse(prefs.getString(key, null))?.let { key to it.savedMs }
            }.minByOrNull { it.second }?.first
            if (oldest != null) edit.remove(oldest)
        }
        edit.apply()
    }

    fun forget(context: Context, hostId: String) {
        context.getSharedPreferences(STORE, Context.MODE_PRIVATE)
            .edit().remove(hostId).apply()
    }

    private fun hostKeysOf(host: JsonObject): List<String> =
        (host["hostKeys"] as? kotlinx.serialization.json.JsonArray)
            ?.mapNotNull { (it as? JsonPrimitive)?.contentOrNull }.orEmpty().sorted()

    fun validatedLabel(entry: Entry, host: JsonObject, nowMs: Long): String? {
        if (nowMs - entry.savedMs >= MAX_AGE_MS) return null
        val hostname = (host.sshString("hostname") ?: "").lowercase()
        val port = host["port"]?.let { (it as? JsonPrimitive)?.intOrNull } ?: 22
        if (entry.hostname.isNotEmpty() && (entry.hostname != hostname || entry.port != port)) {
            return null
        }
        val keys = hostKeysOf(host)
        if (entry.hostKeys.isEmpty()) {
            if (keys.isNotEmpty()) return entry.label
            return entry.label
        }
        if (entry.hostKeys != keys) return null
        return entry.label
    }

    fun cleanLabel(check: JsonObject): String? {
        val raw = check.sshString("distro")?.takeIf { it.isNotBlank() }
            ?: check.sshString("os")?.takeIf { it.isNotBlank() }
            ?: return null
        return raw.split(Regex("\\s+")).filter { it.isNotEmpty() }
            .joinToString(" ").take(80).takeIf { it.isNotEmpty() }
    }

    private fun persist(context: Context, id: String, entry: Entry) {
        context.getSharedPreferences(STORE, Context.MODE_PRIVATE)
            .edit().putString(id, entry.serialize()).apply()
    }
}

@Composable
fun sshStripColor(name: String?): androidx.compose.ui.graphics.Color {
    val colors = ai.tokenstat.tokenstat.ui.theme.LocalTsColors.current
    return remember(name, colors) {
        when (name) {
            "violet" -> colors.accent
            "amber" -> colors.warning
            "red" -> colors.danger
            "grey" -> colors.stateIdle
            "blue" -> colors.secondary
            "green" -> colors.success
            else -> colors.stateIdle
        }
    }
}
