// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
package ai.tokenstat.tokenstat.ui.workspace

import ai.tokenstat.tokenstat.ui.logic.UntouchedChats
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonObject

/// The workspaces session: which host is dialled, what it loaded, and the
/// last stable failure. Held on the model, next to the SSH sessions, so
/// navigating between tabs does not dial again: the tunnel underneath never
/// dropped, and a full connecting dance on every return is pure UI churn.
///
/// Only the session lives here. Screens keep their own UI state (search,
/// selection, sheets), which is correctly ephemeral.
class WorkspacesConnectionState {
    private var accountOwner: String? = null

    fun setAccountOwner(owner: String?) {
        if (accountOwner == owner) return
        accountOwner = owner
        clearAll()
        mutableHost.value = null
    }

    private data class HostSnapshot(
        val folders: JsonArray,
        val sessions: JsonArray,
        val chats: JsonArray,
    )

    // Keep loaded work under its peer key when navigation focuses another
    // machine. Raw workspace ids can overlap between hosts, so callers must
    // always select a peer before using one of these lists.
    private val hostSnapshots = mutableMapOf<String, HostSnapshot>()
    private val mutableConnectedHosts = MutableStateFlow<Set<String>>(emptySet())
    val connectedHosts: StateFlow<Set<String>> = mutableConnectedHosts.asStateFlow()
    private val backgroundAttempts = mutableMapOf<String, Int>()
    private val backgroundNextAt = mutableMapOf<String, Long>()
    private val mutableBackgroundConnecting = MutableStateFlow<Set<String>>(emptySet())
    val backgroundConnecting: StateFlow<Set<String>> = mutableBackgroundConnecting.asStateFlow()

    fun beginBackground(peer: String, owner: String, nowMs: Long = System.currentTimeMillis()): Boolean {
        if (accountOwner != owner || peer in hostSnapshots ||
            peer in mutableBackgroundConnecting.value ||
            nowMs < (backgroundNextAt[peer] ?: 0L)) return false
        mutableBackgroundConnecting.value = mutableBackgroundConnecting.value + peer
        return true
    }

    fun finishBackground(peer: String, owner: String, success: Boolean, nowMs: Long = System.currentTimeMillis()) {
        if (accountOwner != owner) return
        mutableBackgroundConnecting.value = mutableBackgroundConnecting.value - peer
        if (success) {
            backgroundAttempts.remove(peer)
            backgroundNextAt.remove(peer)
        } else {
            val failures = (backgroundAttempts[peer] ?: 0) + 1
            backgroundAttempts[peer] = failures
            backgroundNextAt[peer] = nowMs + minOf(60_000L, 2_000L shl minOf(failures - 1, 5))
        }
    }

    fun publishBackground(peer: String, owner: String, folders: JsonArray, sessions: JsonArray, chats: JsonArray): Boolean {
        if (accountOwner != owner || peer !in mutableBackgroundConnecting.value) return false
        // A foreground dial owns the visible lists. Background results never
        // overwrite that selected host, even when the two requests overlap.
        if (mutableConnectedPeer.value == peer || mutableConnectingPeer.value == peer) return false
        hostSnapshots[peer] = HostSnapshot(folders, sessions, filteredChats(chats))
        mutableConnectedHosts.value = hostSnapshots.keys.toSet()
        return true
    }

    private val mutableConnectingPeer = MutableStateFlow<String?>(null)
    val connectingPeer: StateFlow<String?> = mutableConnectingPeer.asStateFlow()
    private var connectionTicket = 0L

    /// Home and Workspaces share the same dial. An explicit host choice can
    /// replace a background warmup; the old result then loses its ticket.
    fun beginConnecting(peer: String, explicit: Boolean = false): Long? {
        if (mutableConnectingPeer.value != null && !explicit) return null
        connectionTicket++
        mutableConnectingPeer.value = peer
        return connectionTicket
    }

    fun isCurrentConnection(ticket: Long): Boolean = ticket == connectionTicket

    fun finishConnecting(ticket: Long) {
        if (isCurrentConnection(ticket)) mutableConnectingPeer.value = null
    }

    private val mutableHost = MutableStateFlow<JsonObject?>(null)
    val host: StateFlow<JsonObject?> = mutableHost.asStateFlow()

    private val mutableConnectedPeer = MutableStateFlow<String?>(null)
    val connectedPeer: StateFlow<String?> = mutableConnectedPeer.asStateFlow()

    private val mutableAllowed = MutableStateFlow<Boolean?>(null)
    val allowed: StateFlow<Boolean?> = mutableAllowed.asStateFlow()

    private val mutableLoadingFolders = MutableStateFlow(false)
    val loadingFolders: StateFlow<Boolean> = mutableLoadingFolders.asStateFlow()

    private val mutableFolders = MutableStateFlow(JsonArray(emptyList()))
    val folders: StateFlow<JsonArray> = mutableFolders.asStateFlow()

    private val mutableSessions = MutableStateFlow(JsonArray(emptyList()))
    val sessions: StateFlow<JsonArray> = mutableSessions.asStateFlow()

    private val mutableChats = MutableStateFlow(JsonArray(emptyList()))
    val chats: StateFlow<JsonArray> = mutableChats.asStateFlow()

    /// The last failure worth reading. Automatic retries fail silently into
    /// the log until they settle; only a stable failure lands here, so it
    /// never flashes past on the way to a connection.
    private val mutableError = MutableStateFlow<String?>(null)
    val error: StateFlow<String?> = mutableError.asStateFlow()

    private val mutableRequestNotice = MutableStateFlow<String?>(null)
    val requestNotice: StateFlow<String?> = mutableRequestNotice.asStateFlow()

    fun setHost(machine: JsonObject?) {
        mutableHost.value = machine
    }

    fun activateConnectedHost(machine: JsonObject): Boolean {
        val peer = machine.str("publicIdentity") ?: return false
        val snapshot = hostSnapshots[peer] ?: return false
        connectionTicket++
        mutableConnectingPeer.value = null
        mutableHost.value = machine
        mutableConnectedPeer.value = peer
        mutableAllowed.value = true
        mutableLoadingFolders.value = false
        mutableFolders.value = snapshot.folders
        mutableSessions.value = snapshot.sessions
        mutableChats.value = snapshot.chats
        mutableError.value = null
        mutableRequestNotice.value = null
        return true
    }

    fun setConnected(peer: String?, allowed: Boolean?) {
        mutableConnectedPeer.value = peer
        mutableAllowed.value = allowed
    }

    fun setAllowed(allowed: Boolean?) {
        mutableAllowed.value = allowed
        if (allowed == false) {
            mutableHost.value?.str("publicIdentity")?.let { hostSnapshots.remove(it) }
            mutableConnectedHosts.value = hostSnapshots.keys.toSet()
        }
    }

    fun setLoadingFolders(loading: Boolean) {
        mutableLoadingFolders.value = loading
    }

    fun setLists(folders: JsonArray, sessions: JsonArray, chats: JsonArray) {
        mutableFolders.value = folders
        mutableSessions.value = sessions
        // Recent chats leave out the ones opened and never used.
        mutableChats.value = filteredChats(chats)
        saveSelectedSnapshot()
    }

    private fun filteredChats(chats: JsonArray): JsonArray = JsonArray(chats.filterNot { element ->
            val chat = element as? JsonObject ?: return@filterNot false
            UntouchedChats.isUntouched(
                title = chat.str("title"),
                lastMessageAtMs = chat.long("lastMessageAtMs"),
                running = chat.bol("running"),
                id = chat.str("id"),
            )
        })

    fun setFolders(folders: JsonArray) {
        mutableFolders.value = folders
        saveSelectedSnapshot()
    }

    private fun saveSelectedSnapshot() {
        val peer = mutableConnectedPeer.value ?: return
        hostSnapshots[peer] = HostSnapshot(mutableFolders.value, mutableSessions.value, mutableChats.value)
        mutableConnectedHosts.value = hostSnapshots.keys.toSet()
    }

    fun clearLists() {
        mutableFolders.value = JsonArray(emptyList())
        mutableSessions.value = JsonArray(emptyList())
        mutableChats.value = JsonArray(emptyList())
    }

    fun setError(message: String?) {
        mutableError.value = message
    }

    fun setRequestNotice(notice: String?) {
        mutableRequestNotice.value = notice
    }

    /// What Disconnect does on every client: forget the session. The tunnel
    /// underneath is the host's to reap, exactly like iOS.
    fun disconnect() {
        mutableConnectedPeer.value?.let { hostSnapshots.remove(it) }
        mutableConnectedHosts.value = hostSnapshots.keys.toSet()
        connectionTicket++
        mutableConnectingPeer.value = null
        mutableConnectedPeer.value = null
        mutableAllowed.value = null
        mutableLoadingFolders.value = false
        mutableRequestNotice.value = null
        mutableError.value = null
        clearLists()
    }

    fun clearAll() {
        hostSnapshots.clear()
        backgroundAttempts.clear()
        backgroundNextAt.clear()
        mutableBackgroundConnecting.value = emptySet()
        disconnect()
    }
}
