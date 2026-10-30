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
    private var knownHosts: Set<String>? = null

    fun setAccountOwner(owner: String?) {
        if (accountOwner == owner) return
        accountOwner = owner
        clearAll()
        mutableHost.value = null
        knownHosts = null
    }

    fun setKnownHosts(peers: Set<String>) {
        knownHosts = peers
        hostSnapshots.keys.retainAll(peers)
        mutableConnectedHosts.value = hostSnapshots.keys.toSet()
        mutableStaleHosts.value = mutableStaleHosts.value.intersect(peers)
        mutableAccessDeniedHosts.value = mutableAccessDeniedHosts.value.intersect(peers)
        backgroundAttempts.keys.retainAll(peers)
        backgroundNextAt.keys.retainAll(peers)
        backgroundTickets.keys.retainAll(peers)
        mutableBackgroundConnecting.value = mutableBackgroundConnecting.value.intersect(peers)
        mutableConnectingPeer.value?.takeIf { it !in peers }?.let(::cancelConnecting)
        if (mutableConnectedPeer.value?.let { it !in peers } == true) {
            disconnect()
            mutableHost.value = null
        }
    }

    private data class HostSnapshot(
        val folders: JsonArray,
        val sessions: JsonArray,
        val chats: JsonArray,
        val loadedAtMs: Long,
    )

    // Keep loaded work under its peer key when navigation focuses another
    // machine. Raw workspace ids can overlap between hosts, so callers must
    // always select a peer before using one of these lists.
    private val hostSnapshots = mutableMapOf<String, HostSnapshot>()
    private val mutableConnectedHosts = MutableStateFlow<Set<String>>(emptySet())
    val connectedHosts: StateFlow<Set<String>> = mutableConnectedHosts.asStateFlow()
    private val mutableStaleHosts = MutableStateFlow<Set<String>>(emptySet())
    val staleHosts: StateFlow<Set<String>> = mutableStaleHosts.asStateFlow()
    private val mutableAccessDeniedHosts = MutableStateFlow<Set<String>>(emptySet())
    val accessDeniedHosts: StateFlow<Set<String>> = mutableAccessDeniedHosts.asStateFlow()
    fun foldersFor(peer: String): JsonArray = hostSnapshots[peer]?.folders ?: JsonArray(emptyList())
    fun sessionsFor(peer: String): JsonArray = hostSnapshots[peer]?.sessions ?: JsonArray(emptyList())
    fun chatsFor(peer: String): JsonArray = hostSnapshots[peer]?.chats ?: JsonArray(emptyList())
    private val backgroundAttempts = mutableMapOf<String, Int>()
    private val backgroundNextAt = mutableMapOf<String, Long>()
    private val backgroundTickets = mutableMapOf<String, Long>()
    private var nextBackgroundTicket = 0L
    private val mutableBackgroundConnecting = MutableStateFlow<Set<String>>(emptySet())
    val backgroundConnecting: StateFlow<Set<String>> = mutableBackgroundConnecting.asStateFlow()

    fun beginBackground(peer: String, owner: String, nowMs: Long = System.currentTimeMillis(), forceRefresh: Boolean = false): Long? {
        if (accountOwner != owner || (knownHosts != null && peer !in knownHosts.orEmpty()) ||
            peer == mutableConnectedPeer.value || peer == mutableConnectingPeer.value ||
            (!forceRefresh && hostSnapshots[peer]?.let { nowMs - it.loadedAtMs < 60_000L } == true) ||
            peer in mutableBackgroundConnecting.value ||
            (!forceRefresh && nowMs < (backgroundNextAt[peer] ?: 0L))) return null
        val ticket = ++nextBackgroundTicket
        backgroundTickets[peer] = ticket
        mutableBackgroundConnecting.value = mutableBackgroundConnecting.value + peer
        return ticket
    }

    fun isCurrentBackground(peer: String, owner: String, ticket: Long): Boolean =
        accountOwner == owner && backgroundTickets[peer] == ticket

    fun invalidateBackground(peer: String) {
        backgroundTickets.remove(peer)
        mutableBackgroundConnecting.value = mutableBackgroundConnecting.value - peer
    }

    fun finishBackground(peer: String, owner: String, ticket: Long, success: Boolean, nowMs: Long = System.currentTimeMillis(), cancelled: Boolean = false) {
        if (accountOwner != owner || backgroundTickets[peer] != ticket) return
        invalidateBackground(peer)
        if (success) {
            backgroundAttempts.remove(peer)
            backgroundNextAt.remove(peer)
            mutableStaleHosts.value = mutableStaleHosts.value - peer
        } else if (!cancelled && peer != mutableConnectedPeer.value && peer != mutableConnectingPeer.value) {
            val failures = (backgroundAttempts[peer] ?: 0) + 1
            backgroundAttempts[peer] = failures
            backgroundNextAt[peer] = nowMs + minOf(60_000L, 2_000L shl minOf(failures - 1, 5))
            if (peer in hostSnapshots) mutableStaleHosts.value = mutableStaleHosts.value + peer
        }
    }

    fun publishBackground(peer: String, owner: String, ticket: Long, folders: JsonArray, sessions: JsonArray, chats: JsonArray,
                          nowMs: Long = System.currentTimeMillis()): Boolean {
        if (accountOwner != owner || (knownHosts != null && peer !in knownHosts.orEmpty()) ||
            backgroundTickets[peer] != ticket) return false
        // A foreground dial owns the visible lists. Background results never
        // overwrite that selected host, even when the two requests overlap.
        if (mutableConnectedPeer.value == peer || mutableConnectingPeer.value == peer) return false
        hostSnapshots[peer] = HostSnapshot(folders, sessions, filteredChats(chats), nowMs)
        mutableConnectedHosts.value = hostSnapshots.keys.toSet()
        mutableStaleHosts.value = mutableStaleHosts.value - peer
        mutableAccessDeniedHosts.value = mutableAccessDeniedHosts.value - peer
        return true
    }

    fun dropBackgroundHost(peer: String, owner: String, ticket: Long): Boolean {
        if (!isCurrentBackground(peer, owner, ticket)) return false
        hostSnapshots.remove(peer)
        mutableConnectedHosts.value = hostSnapshots.keys.toSet()
        mutableStaleHosts.value = mutableStaleHosts.value - peer
        mutableAccessDeniedHosts.value = mutableAccessDeniedHosts.value + peer
        return true
    }

    private val mutableConnectingPeer = MutableStateFlow<String?>(null)
    val connectingPeer: StateFlow<String?> = mutableConnectingPeer.asStateFlow()
    private var connectionTicket = 0L

    /// Home and Workspaces share the same dial. An explicit host choice can
    /// replace a background warmup; the old result then loses its ticket.
    fun beginConnecting(peer: String, explicit: Boolean = false): Long? {
        if (mutableConnectingPeer.value != null && !explicit) return null
        invalidateBackground(peer)
        connectionTicket++
        mutableConnectingPeer.value = peer
        return connectionTicket
    }

    fun isCurrentConnection(ticket: Long): Boolean = ticket == connectionTicket

    fun finishConnecting(ticket: Long) {
        if (isCurrentConnection(ticket)) mutableConnectingPeer.value = null
    }

    private fun cancelConnecting(peer: String) {
        if (mutableConnectingPeer.value != peer) return
        // The caller checks this ticket after every remote step. Revoking a
        // host while its access check is in flight must invalidate the answer
        // before it can publish folders for a machine no longer on the account.
        connectionTicket++
        mutableConnectingPeer.value = null
        if (mutableConnectedPeer.value == null) {
            if (mutableHost.value?.str("publicIdentity") == peer) mutableHost.value = null
            mutableAllowed.value = null
            mutableLoadingFolders.value = false
            mutableRequestNotice.value = null
            mutableError.value = null
            clearLists()
        }
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
        // Keep a failed background refresh visible as a host, but never
        // present its old work as a live connection during a later handoff.
        if (peer in mutableStaleHosts.value) return false
        val snapshot = hostSnapshots[peer] ?: return false
        invalidateBackground(peer)
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
        mutableAccessDeniedHosts.value = mutableAccessDeniedHosts.value - peer
        return true
    }

    fun setConnected(peer: String?, allowed: Boolean?) {
        mutableConnectedPeer.value = peer
        mutableAllowed.value = allowed
    }

    fun setAllowed(allowed: Boolean?) {
        mutableAllowed.value = allowed
        mutableHost.value?.str("publicIdentity")?.let { peer ->
            if (allowed == true) mutableAccessDeniedHosts.value = mutableAccessDeniedHosts.value - peer
            if (allowed == false) mutableAccessDeniedHosts.value = mutableAccessDeniedHosts.value + peer
        }
        if (allowed == false) {
            mutableHost.value?.str("publicIdentity")?.let { hostSnapshots.remove(it) }
            mutableConnectedHosts.value = hostSnapshots.keys.toSet()
            mutableStaleHosts.value = mutableStaleHosts.value.intersect(hostSnapshots.keys)
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
        hostSnapshots[peer] = HostSnapshot(mutableFolders.value, mutableSessions.value, mutableChats.value, System.currentTimeMillis())
        mutableConnectedHosts.value = hostSnapshots.keys.toSet()
        mutableStaleHosts.value = mutableStaleHosts.value - peer
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
        mutableConnectedPeer.value?.let {
            hostSnapshots.remove(it)
            mutableStaleHosts.value = mutableStaleHosts.value - it
        }
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

    fun disconnectHost(peer: String) {
        hostSnapshots.remove(peer)
        mutableConnectedHosts.value = hostSnapshots.keys.toSet()
        mutableStaleHosts.value = mutableStaleHosts.value - peer
        mutableAccessDeniedHosts.value = mutableAccessDeniedHosts.value - peer
        invalidateBackground(peer)
        backgroundAttempts.remove(peer)
        backgroundNextAt.remove(peer)
        if (mutableConnectedPeer.value == peer) disconnect()
        else cancelConnecting(peer)
    }

    fun clearAll() {
        hostSnapshots.clear()
        mutableStaleHosts.value = emptySet()
        mutableAccessDeniedHosts.value = emptySet()
        backgroundAttempts.clear()
        backgroundNextAt.clear()
        backgroundTickets.clear()
        mutableBackgroundConnecting.value = emptySet()
        disconnect()
    }
}
