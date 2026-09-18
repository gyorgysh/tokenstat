// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
package ai.tokenstat.tokenstat.ui.ssh

import ai.tokenstat.tokenstat.ui.components.TsCard
import ai.tokenstat.tokenstat.ui.theme.LocalTsColors
import ai.tokenstat.tokenstat.ui.theme.Space
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.unit.dp
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.update
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.booleanOrNull
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.contentOrNull
import kotlinx.serialization.json.put
import androidx.compose.ui.text.style.TextOverflow

/// One shell the host is holding, as `ssh.session.list` reports it.
///
/// The sessions live in the host process, not in the app, so this is how the
/// screen finds the shells it left running. Port of `SSHSessionSummary`.
data class SshSessionEntry(
    val id: String,
    val hostId: String?,
    val label: String,
    val alive: Boolean,
    /// Locally ended by reconcile: the host reaped the shell, but the tab
    /// stays until the person explicitly closes it, so the command's final
    /// output can still be read.
    val locallyEnded: Boolean = false,
) {
    companion object {
        fun of(element: JsonElement): SshSessionEntry? {
            val item = element as? JsonObject ?: return null
            val id = (item["id"] as? JsonPrimitive)?.contentOrNull ?: return null
            return SshSessionEntry(
                id = id,
                hostId = (item["hostId"] as? JsonPrimitive)?.contentOrNull,
                label = (item["label"] as? JsonPrimitive)?.contentOrNull?.takeIf { it.isNotBlank() }
                    ?: "Session",
                alive = (item["alive"] as? JsonPrimitive)?.booleanOrNull != false,
            )
        }
    }
}

/// The SSH sessions this app is showing, in one place.
///
/// Port of the phone half of `SSHSessionsModel`. A refresh reconciles against
/// `ssh.session.list`: it adopts what the host is holding and never drops a
/// live local terminal. Leaving the screen leaves shells running, and the
/// Open sessions section is the way back to them.
///
/// Held by the app model so navigating between tabs cannot orphan a shell:
/// the old screen kept the open session in composable `remember`, so leaving
/// SSH and coming back lost the only reference to a shell that was still
/// running on the host, with nothing on any screen mentioning it.
class SshConnectionState(
    private val call: suspend (method: String, params: JsonObject) -> JsonElement = { _, _ ->
        JsonArray(emptyList())
    },
) {
    private val mutableSessions = MutableStateFlow<List<SshSessionEntry>>(emptyList())
    val sessions: StateFlow<List<SshSessionEntry>> = mutableSessions.asStateFlow()

    private val mutableSelectedId = MutableStateFlow<String?>(null)
    val selectedId: StateFlow<String?> = mutableSelectedId.asStateFlow()

    private val mutableConnecting = MutableStateFlow<JsonObject?>(null)
    val connecting: StateFlow<JsonObject?> = mutableConnecting.asStateFlow()

    /// Sessions whose close is still in flight. Closing takes a tab off
    /// screen straight away and tells the host afterwards, so for a moment
    /// the host still lists a session this app has forgotten. Without this
    /// the next reconcile adopts it back and the tab somebody just closed
    /// reappears.
    private val closingIds = mutableSetOf<String>()

    val selected: SshSessionEntry?
        get() = mutableSessions.value.firstOrNull { it.id == mutableSelectedId.value }

    fun sessionsFor(hostId: String): List<SshSessionEntry> =
        mutableSessions.value.filter { it.hostId == hostId }

    fun requestConnect(host: JsonObject) {
        mutableConnecting.value = host
    }

    fun cancelConnect() {
        mutableConnecting.value = null
    }

    /// Take a freshly opened session and select it. One entry per session id,
    /// always: an adopt racing a reconcile must not list the same shell twice.
    fun adopt(entry: SshSessionEntry) {
        mutableSessions.update { current ->
            if (current.any { it.id == entry.id }) current else current + entry
        }
        mutableSelectedId.value = entry.id
        mutableConnecting.value = null
    }

    fun select(entry: SshSessionEntry) {
        mutableSelectedId.value = entry.id
    }

    /// Done leaves the shell running on the host. The entry stays in the list
    /// so Open sessions is the way back; only [close] ends the shell.
    fun dismiss() {
        mutableSelectedId.value = null
    }

    suspend fun close(entry: SshSessionEntry) {
        closingIds.add(entry.id)
        mutableSessions.update { current -> current.filterNot { it.id == entry.id } }
        if (mutableSelectedId.value == entry.id) {
            mutableSelectedId.value = mutableSessions.value.lastOrNull()?.id
        }
        runCatching { call("ssh.session.close", buildJsonObject { put("id", entry.id) }) }
    }

    /// Close every session on one host. Used when a saved record is deleted.
    suspend fun closeAll(hostId: String) {
        for (entry in sessionsFor(hostId)) close(entry)
    }

    /// Adopt what the host is holding and mark what it has forgotten.
    ///
    /// A session the host no longer lists is marked ended locally, not
    /// removed: `ssh.session.list` reaps an ended shell before answering, and
    /// removing the entry here would erase the command's final output before
    /// it has been read. A failed list call changes nothing: a refresh that
    /// cannot reach the host must not read as every session having ended.
    suspend fun reconcile() {
        val summaries = runCatching { call("ssh.session.list", buildJsonObject {}) }
            .getOrNull() as? JsonArray ?: return
        val held = summaries.mapNotNull { SshSessionEntry.of(it) }
        mutableSessions.update { current -> reconcileSessions(current, held, closingIds) }
        val heldIds = held.map { it.id }.toSet()
        closingIds.retainAll(heldIds)
        if (mutableSelectedId.value != null &&
            mutableSessions.value.none { it.id == mutableSelectedId.value }
        ) {
            mutableSelectedId.value = mutableSessions.value.lastOrNull()?.id
        }
    }
}

/// Pure half of [SshConnectionState.reconcile], so unit tests pin the same
/// answers. Adopts unknown live sessions, marks known-alive ones the host
/// forgot as locally ended, and never removes or resurrects an entry.
fun reconcileSessions(
    current: List<SshSessionEntry>,
    held: List<SshSessionEntry>,
    closing: Set<String>,
): List<SshSessionEntry> {
    val known = current.map { it.id }.toSet()
    val heldIds = held.map { it.id }.toSet()
    val out = current.map { entry ->
        if (entry.alive && !entry.locallyEnded && !heldIds.contains(entry.id)) {
            entry.copy(locallyEnded = true)
        } else {
            entry
        }
    }.toMutableList()
    for (summary in held) {
        if (!known.contains(summary.id) && !closing.contains(summary.id)) {
            out.add(summary)
        }
    }
    return out
}

/// The on-connect commands for a host: saved snippets flagged to run, without
/// placeholders. Placeholder snippets are skipped, because asking for values
/// is a sheet, and a sheet that opens by itself the moment a connection lands
/// is not something to do to somebody. Port of `runStartup`'s filter.
fun startupCommands(hostId: String?, snippets: JsonArray): List<String> {
    if (hostId.isNullOrEmpty()) return emptyList()
    return snippets.mapNotNull { it as? JsonObject }
        .filter { snippet ->
            (snippet["runOnConnect"] as? JsonPrimitive)?.booleanOrNull == true &&
                snippet.sshString("hostId").let { owner -> owner.isNullOrEmpty() || owner == hostId }
        }
        .mapNotNull { it.sshString("command")?.takeIf { command -> command.isNotBlank() } }
        .filter { SnippetRun.placeholders(it).isEmpty() }
}

/// Live shells, above everything. Without this row a shell somebody left
/// running is running with nothing on any screen that mentions it. Port of
/// the iOS library's Open sessions section plus `sessionRow`.
@Composable
fun SshOpenSessionsSection(
    state: SshConnectionState,
    onOpen: (SshSessionEntry) -> Unit,
    onEnd: (SshSessionEntry) -> Unit,
) {
    val sessions by state.sessions.collectAsState()
    if (sessions.isEmpty()) return
    val colors = LocalTsColors.current
    Column(Modifier.fillMaxWidth()) {
        Text(
            "Open sessions",
            style = MaterialTheme.typography.labelLarge,
            color = colors.textSecondary,
        )
        Spacer(Modifier.size(Space.s))
        sessions.forEach { session ->
            TsCard(Modifier.clickable { onOpen(session) }) {
                Row(verticalAlignment = Alignment.CenterVertically, modifier = Modifier.fillMaxWidth()) {
                    Box(
                        Modifier.size(8.dp).background(
                            if (session.alive && !session.locallyEnded) colors.accent else colors.stateIdle,
                            CircleShape,
                        ),
                    )
                    Spacer(Modifier.width(Space.s))
                    Column(Modifier.weight(1f)) {
                        Text(
                            session.label,
                            maxLines = 1,
                            overflow = TextOverflow.Ellipsis,
                            color = colors.textPrimary,
                        )
                        Text(
                            if (session.alive && !session.locallyEnded) "Running" else "Ended",
                            style = MaterialTheme.typography.bodySmall,
                            color = colors.textSecondary,
                        )
                    }
                    androidx.compose.material3.TextButton(onClick = { onEnd(session) }) {
                        Text("End", color = colors.danger)
                    }
                }
            }
            Spacer(Modifier.size(Space.s))
        }
    }
}
