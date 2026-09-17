// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
package ai.tokenstat.tokenstat.ui.workspace

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
    private val mutableHost = MutableStateFlow<JsonObject?>(null)
    val host: StateFlow<JsonObject?> = mutableHost.asStateFlow()

    private val mutableConnectedPeer = MutableStateFlow<String?>(null)
    val connectedPeer: StateFlow<String?> = mutableConnectedPeer.asStateFlow()

    private val mutableAllowed = MutableStateFlow<Boolean?>(null)
    val allowed: StateFlow<Boolean?> = mutableAllowed.asStateFlow()

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

    fun setConnected(peer: String?, allowed: Boolean?) {
        mutableConnectedPeer.value = peer
        mutableAllowed.value = allowed
    }

    fun setAllowed(allowed: Boolean?) {
        mutableAllowed.value = allowed
    }

    fun setLists(folders: JsonArray, sessions: JsonArray, chats: JsonArray) {
        mutableFolders.value = folders
        mutableSessions.value = sessions
        mutableChats.value = chats
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
        mutableConnectedPeer.value = null
        mutableAllowed.value = null
        mutableRequestNotice.value = null
        mutableError.value = null
        clearLists()
    }
}
