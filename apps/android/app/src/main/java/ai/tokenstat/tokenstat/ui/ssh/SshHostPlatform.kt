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

/// Confirmed server metadata, local to this device. Never infer an OS from an
/// address. Port of `SSHHostPlatformCache` plus `distroBrandID`'s Android half.
///
/// The label comes from `ssh.provision.check` (what the host itself reported
/// in `/etc/os-release`), remembered by the setup check step. The row reads it
/// back only while it still describes the same endpoint and trusted identity.
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

    /// The label a host row may show, or null when nothing confirmed applies.
    /// An edited endpoint or a changed trusted identity invalidates the entry,
    /// so a label never follows an address it was not confirmed for.
    fun label(context: Context, host: JsonObject, nowMs: Long = System.currentTimeMillis()): String? {
        val id = host.sshString("id") ?: return null
        val entry = Entry.parse(
            context.getSharedPreferences(STORE, Context.MODE_PRIVATE).getString(id, null),
        ) ?: return null
        return validatedLabel(entry, host, nowMs)?.also {
            // Bind a provisional pre-trust label to the first trusted keys, the
            // way the Apple cache does: the setup check probes before the
            // fingerprint is trusted, and a later identity change must
            // invalidate the label instead of hiding behind it.
            if (entry.hostKeys.isEmpty() && hostKeysOf(host).isNotEmpty()) {
                persist(context, id, entry.copy(hostKeys = hostKeysOf(host)))
            }
        } ?: run {
            // Expired entries are dropped on read so the store cannot fill
            // with labels nothing will ever show again.
            if (nowMs - entry.savedMs >= MAX_AGE_MS) forget(context, id)
            null
        }
    }

    /// Remember what `ssh.provision.check` reported. The distro when it has
    /// one, else the OS, cleaned to one line of at most 80 characters.
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
        // Bound the store: drop the oldest beyond the cap.
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

    /// Pure half of [label], so unit tests pin the same answers without a
    /// device. Returns the label, or null when the entry must not be shown.
    fun validatedLabel(entry: Entry, host: JsonObject, nowMs: Long): String? {
        if (nowMs - entry.savedMs >= MAX_AGE_MS) return null
        val hostname = (host.sshString("hostname") ?: "").lowercase()
        val port = host["port"]?.let { (it as? JsonPrimitive)?.intOrNull } ?: 22
        if (entry.hostname.isNotEmpty() && (entry.hostname != hostname || entry.port != port)) {
            return null
        }
        val keys = hostKeysOf(host)
        if (entry.hostKeys.isEmpty()) {
            // Provisional: confirmed before the first trust. It survives the
            // trust (the caller binds it), and nothing else invalidates it.
            if (keys.isNotEmpty()) return entry.label
            return entry.label
        }
        if (entry.hostKeys != keys) return null
        return entry.label
    }

    /// One line from a provision check: the distro when it names one, else the
    /// OS. Null when the check said nothing usable.
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

/// The color strip a host row wears, ported from `SSHColor.color`. Names are
/// the six the Apple editor offers; anything else reads as idle, never as a
/// guessed color.
@Composable
fun sshStripColor(name: String?): androidx.compose.ui.graphics.Color {
    val colors = ai.tokenstat.tokenstat.ui.theme.LocalTsColors.current
    return remember(name, colors) {
        when (name) {
            "violet" -> colors.accent
            "amber" -> colors.warning
            "red" -> colors.danger
            "grey" -> colors.stateIdle
            // No system blue or green fills: the one blue the theme owns is
            // the info accent, and success green is a status, not a label.
            // Both still read as colors, not as states, on a 4dp strip.
            "blue" -> colors.secondary
            "green" -> colors.success
            else -> colors.stateIdle
        }
    }
}
