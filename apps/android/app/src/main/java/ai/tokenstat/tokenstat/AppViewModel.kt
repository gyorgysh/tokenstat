// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
package ai.tokenstat.tokenstat

import android.app.Application
import androidx.lifecycle.AndroidViewModel
import androidx.lifecycle.viewModelScope
import ai.tokenstat.tokenstat.core.CoreClient
import ai.tokenstat.tokenstat.core.CoreFailure
import ai.tokenstat.tokenstat.notifications.PushRegistrar
import ai.tokenstat.tokenstat.ui.logic.tagSignInUrl
import ai.tokenstat.tokenstat.ui.ssh.SshConnectionState
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.Job
import kotlinx.coroutines.async
import kotlinx.coroutines.delay
import kotlinx.coroutines.ensureActive
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.launch
import kotlinx.serialization.json.booleanOrNull
import kotlinx.serialization.json.longOrNull
import kotlinx.serialization.json.contentOrNull
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.JsonNull
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import kotlinx.serialization.json.put

data class ConnectionUi(
    val ok: Boolean = true,
    val down: Boolean = false,
    val offline: Boolean = false,
    val service: Boolean = false,
    val title: String = "",
    val detail: String = "",
)

data class ClientState(
    val loading: Boolean = true,
    val account: JsonObject? = null,
    val home: JsonObject? = null,
    val limits: JsonArray = JsonArray(emptyList()),
    val limitsError: String? = null,
    val error: String? = null,
    val connection: ConnectionUi = ConnectionUi(),
) {
    val signedIn: Boolean get() = account?.get("signedIn")?.jsonPrimitive?.content == "true"
    val canRemote: Boolean
        get() {
            val flag = account?.get("canRemote")
            if (flag != null && flag !is JsonNull) {
                return flag.jsonPrimitive.content == "true"
            }
            val tier = account?.get("tier")?.jsonPrimitive?.content?.lowercase()
            return tier == "patron" || tier == "legend"
        }
    val vaultAllowed: Boolean
        get() {
            if (canRemote) return true
            val tier = account?.get("tier")?.jsonPrimitive?.content?.lowercase()
            return tier == "supporter" || tier == "patron" || tier == "legend"
        }
    val appAccountToken: String?
        get() = (account?.get("billing") as? JsonObject)
            ?.get("appAccountToken")
            ?.takeUnless { it is JsonNull }
            ?.jsonPrimitive
            ?.content
            ?.takeIf { it.isNotBlank() }

    /// Whether this account has already had its one trial, on any store. The
    /// gate is account-scoped on the server, so a trial taken on the App Store
    /// or through the website counts here too.
    val trialUsed: Boolean
        get() = (account?.get("billing") as? JsonObject)
            ?.get("trialUsed")
            ?.takeUnless { it is JsonNull }
            ?.jsonPrimitive
            ?.content == "true"
}

data class PendingLogin(val url: String, val code: String)

private enum class SignInPollFailure { TRANSPORT, INVALID_GRANT, TERMINAL }

private class SignInFailed(message: String) : Exception(message)

// The core gives device polling its own codes. Transport errors below the
// core envelope stay retryable too.
private fun signInPollFailure(error: Exception): SignInPollFailure {
    val code = (error as? CoreFailure)?.code
    if (code == "device_transport" || code == "offline" || code == "host_timeout" || code == "host_unreachable") {
        return SignInPollFailure.TRANSPORT
    }
    if (code == "device_invalid_grant") return SignInPollFailure.INVALID_GRANT
    if (error is java.net.UnknownHostException || error is java.net.SocketException || error is java.io.IOException) {
        return SignInPollFailure.TRANSPORT
    }
    return SignInPollFailure.TERMINAL
}

class AppViewModel(app: Application) : AndroidViewModel(app) {
    private val mutableState = MutableStateFlow(ClientState())
    val state = mutableState.asStateFlow()

    /// The live SSH shells, in one place. Held here so navigating between
    /// tabs cannot orphan a shell: a refresh reconciles against what the host
    /// is holding and never drops a live connection. See `SshConnectionState`.
    val sshConnections = SshConnectionState(::core)

    /// The workspaces session: which host is dialled and what it loaded.
    /// Held here for the same reason as the shells, so leaving the tab does
    /// not dial again on return. See `WorkspacesConnectionState`.
    val workspacesConnection = ai.tokenstat.tokenstat.ui.workspace.WorkspacesConnectionState()

    init { refresh() }

    fun refresh() = viewModelScope.launch {
        mutableState.value = mutableState.value.copy(loading = true, error = null)
        runCatching { CoreClient.call("account.status") }
            .onSuccess { account ->
                val accountObject = account.jsonObject
                mutableState.value = mutableState.value.copy(
                    account = accountObject,
                    connection = ConnectionUi(),
                )
                if (accountObject["signedIn"]?.jsonPrimitive?.content == "true") {
                    PushRegistrar.refresh()
                    loadDashboard()
                }
            }
            .onFailure { err ->
                mutableState.value = mutableState.value.copy(
                    error = err.message,
                    connection = classify(err),
                )
            }
        mutableState.value = mutableState.value.copy(loading = false)
    }

    fun retryConnection() {
        mutableState.value = mutableState.value.copy(connection = ConnectionUi())
        refresh()
    }

    private suspend fun loadDashboard() {
        val calendar = viewModelScope.async {
            CoreClient.call("activity.calendar", buildJsonObject {
                put("weeks", 53); put("scope", "account"); put("force", false)
            })
        }
        val limits = viewModelScope.async { CoreClient.call("usage.limits") }
        runCatching { calendar.await() }.onSuccess {
            mutableState.value = mutableState.value.copy(home = (it as? JsonObject))
        }
        runCatching { limits.await() }
            .onSuccess {
                mutableState.value = mutableState.value.copy(
                    limits = it as? JsonArray ?: JsonArray(emptyList()),
                    limitsError = null,
                )
            }
            .onFailure {
                mutableState.value = mutableState.value.copy(limitsError = it.message)
            }
    }

    // One account-plane breakdown, the way the iOS Insights model loads it:
    // per cut, from `account.report`, because a client has no archive of its
    // own. `group` is "model", "source" or "day".
    suspend fun accountReport(group: String, weeks: Int = 53): JsonObject =
        core("account.report", buildJsonObject { put("group", group); put("weeks", weeks) }) as JsonObject

    private val _pendingLogin = MutableStateFlow<PendingLogin?>(null)
    val pendingLogin = _pendingLogin.asStateFlow()
    private val _signInNotice = MutableStateFlow<String?>(null)
    val signInNotice = _signInNotice.asStateFlow()
    private val _signInError = MutableStateFlow<String?>(null)
    val signInError = _signInError.asStateFlow()
    private var signInJob: Job? = null

    // Start the device flow, open the approval page, then poll until
    // confirmed, the way the iOS account model does. The cadence and the
    // deadline come from the server: polling faster than asked invites a
    // rate limit, and a fixed loop ends while somebody is still typing a
    // provider password.
    fun signIn(openPage: (String) -> Unit) {
        // A sign-in is already running. Do not start a second one: a second
        // device code orphans the first, and the poll that is running belongs
        // to the code the user is looking at. Put the page back in front of
        // them instead, which is what tapping the button again means.
        if (signInJob?.isActive == true) {
            _pendingLogin.value?.let { openPage(it.url) }
            return
        }
        _signInError.value = null
        signInJob = viewModelScope.launch {
            try {
                val device = CoreClient.call("account.deviceStart").jsonObject
                val raw = device["openUrl"]?.jsonPrimitive?.content
                    ?: throw IllegalStateException("The account did not return a sign-in URL.")
                val url = tagSignInUrl(raw)
                val code = device["userCode"]?.jsonPrimitive?.content ?: ""
                var interval = device["interval"]?.jsonPrimitive?.longOrNull ?: 5L
                val deadline = System.currentTimeMillis() +
                    (device["expiresIn"]?.jsonPrimitive?.longOrNull ?: 900L) * 1_000
                _pendingLogin.value = PendingLogin(url, code)
                openPage(url)
                var transportFailures = 0
                while (System.currentTimeMillis() < deadline) {
                    delay(interval * 1_000)
                    ensureActive()
                    val poll = try {
                        CoreClient.call("account.devicePoll")
                    } catch (e: CancellationException) {
                        throw e
                    } catch (e: Exception) {
                        when (signInPollFailure(e)) {
                            SignInPollFailure.TRANSPORT -> {
                                transportFailures += 1
                                if (transportFailures < 3) {
                                    _signInNotice.value = "Waiting for the network."
                                    delay(maxOf(interval, 3L) * 1_000)
                                    continue
                                }
                                cancelLogin()
                                throw SignInFailed("The account service could not be reached after several tries. Try again.")
                            }
                            SignInPollFailure.INVALID_GRANT -> {
                                cancelLogin()
                                throw SignInFailed("That sign-in expired. Start again.")
                            }
                            SignInPollFailure.TERMINAL -> {
                                cancelLogin()
                                throw e
                            }
                        }
                    }
                    transportFailures = 0
                    _signInNotice.value = null
                    if (poll.jsonObject["state"]?.jsonPrimitive?.content == "confirmed") {
                        refresh()
                        return@launch
                    }
                    interval = poll.jsonObject["interval"]?.jsonPrimitive?.longOrNull ?: interval
                }
                cancelLogin()
                _signInError.value = "The sign-in code expired before it was confirmed."
            } catch (e: CancellationException) {
                runCatching { CoreClient.call("account.cancelLogin") }
            } catch (e: SignInFailed) {
                _signInError.value = e.message
            } catch (e: Exception) {
                _signInError.value = e.message
            } finally {
                _pendingLogin.value = null
                _signInNotice.value = null
            }
        }
    }

    // Put the approval page back in front of the user. The browser tab can
    // be dismissed while the sign-in it started is still perfectly alive
    // underneath.
    fun presentSignInPage(openPage: (String) -> Unit) {
        _pendingLogin.value?.let { openPage(it.url) }
    }

    fun cancelSignIn() {
        signInJob?.cancel()
        signInJob = null
    }

    private suspend fun cancelLogin() {
        runCatching { CoreClient.call("account.cancelLogin") }
    }

    fun signOut() = viewModelScope.launch {
        runCatching { PushRegistrar.unregister() }
        runCatching { CoreClient.call("account.logout") }
        mutableState.value = ClientState(loading = false)
    }

    fun applyAccount(element: JsonElement) {
        val account = element as? JsonObject ?: return
        mutableState.value = mutableState.value.copy(account = account)
        if (account["signedIn"]?.jsonPrimitive?.content == "true") {
            viewModelScope.launch { loadDashboard() }
        }
    }

    // This phone's own key, so the workspaces list can leave it out the way
    // the iOS model does: a record from before the server knew client kinds
    // carries no kind and would otherwise list this phone as an asleep host.
    suspend fun machineIdentity(): JsonObject =
        CoreClient.call("machine.identity") as? JsonObject ?: buildJsonObject {}

    suspend fun machinePeers(): JsonArray =
        CoreClient.call("machine.peers") as? JsonArray ?: JsonArray(emptyList())

    suspend fun prepareHost(peer: String, label: String) {
        // Pair once: a peer this store already approves is paired, and
        // re-pairing on every connect would redo its grant bookkeeping for
        // nothing. Anything else (unknown, pending, revoked) pairs, which is
        // also what re-approves a peer the owner un-revoked elsewhere.
        val approved = runCatching {
            machinePeers().any {
                val entry = it as? JsonObject
                entry?.get("key")?.jsonPrimitive?.content == peer &&
                    entry.get("trust")?.jsonPrimitive?.content == "approved"
            }
        }.getOrNull() == true
        if (!approved) {
            CoreClient.call("machine.pair", buildJsonObject {
                put("key", peer)
                put("label", label)
                put("address", "")
            })
        }
        CoreClient.call("remote.serve", buildJsonObject { put("tunnel", true) })
    }

    /// Tell the tunnel the app is back, port of `Bridge.nudgeTunnel`. A
    /// plain nudge wakes the supervisor and starts a session that is not
    /// running. `reconnect` drops a live socket after a path change left
    /// it answering nothing. Without this a fresh process holds no tunnel
    /// session and the first dial fails with "tunnel session is not
    /// running" instead of opening.
    suspend fun nudgeTunnel(reconnect: Boolean = false) {
        runCatching {
            CoreClient.call("remote.nudge", buildJsonObject { put("reconnect", reconnect) })
        }
    }

    /// The nudge for coming back to the foreground, port of
    /// `Bridge.nudgeTunnelOnForeground`. Asking what the tunnel thinks
    /// first costs one local call and drops a socket only when the tunnel
    /// already says it is not connected, so a healthy session keeps its
    /// channels.
    suspend fun nudgeTunnelOnForeground() {
        val offline = runCatching {
            val status = CoreClient.call("remote.status") as? JsonObject
            (status?.get("tunnelOnline") as? kotlinx.serialization.json.JsonPrimitive)?.booleanOrNull == false
        }.getOrNull() == true
        nudgeTunnel(reconnect = offline)
    }

    /// Approve one machine key, and nothing else. Setup pairs the key that
    /// arrived over the verified SSH session so its own tunnel calls are not
    /// refused as unapproved; it does not turn on serving, which is a
    /// separate decision the Mac door owns.
    suspend fun pairPeer(peer: String, label: String) {
        CoreClient.call("machine.pair", buildJsonObject {
            put("key", peer)
            put("label", label)
            put("address", "")
        })
    }

    suspend fun workspaces(peer: String): JsonArray =
        CoreClient.remote(peer, "workspace.list") as? JsonArray ?: JsonArray(emptyList())

    suspend fun hostStats(peer: String): JsonObject =
        CoreClient.remote(peer, "host.stats") as? JsonObject ?: buildJsonObject {}

    /// Direct vs relay for a live peer, from this device's `remote.status`.
    /// Missing stays missing: never invent a path nobody observed.
    suspend fun peerRoute(peer: String): String? {
        val status = runCatching { CoreClient.call("remote.status") as? JsonObject }.getOrNull()
        val peers = ((status?.get("traffic") as? JsonObject)?.get("peers") as? JsonArray)
            .orEmpty().mapNotNull { it as? JsonObject }
        return peers.find { (it["peer"] as? kotlinx.serialization.json.JsonPrimitive)?.contentOrNull.equals(peer, ignoreCase = true) }
            ?.let { (it["route"] as? kotlinx.serialization.json.JsonPrimitive)?.contentOrNull }
            ?.takeIf { it == "direct" || it == "relay" }
    }

    suspend fun workspaceSection(peer: String, method: String, params: JsonObject): JsonElement =
        CoreClient.remote(peer, method, params)

    suspend fun core(method: String, params: JsonObject = buildJsonObject {}): JsonElement =
        CoreClient.call(method, params)
}

private fun classify(err: Throwable): ConnectionUi {
    val code = (err as? CoreFailure)?.code.orEmpty()
    val message = err.message.orEmpty().lowercase()
    val offline = code == "offline" ||
        message.contains("unable to resolve") ||
        message.contains("network") ||
        message.contains("enotconn")
    if (offline) {
        return ConnectionUi(
            ok = false,
            down = true,
            offline = true,
            title = "Offline",
            detail = "This device cannot reach the internet. Retrying from Try now.",
        )
    }
    if (code == "host_timeout" || code == "host_unreachable" || code.contains("peer")) {
        return ConnectionUi(
            ok = false,
            down = false,
            title = "Computer unreachable",
            detail = "The internet is fine and the computer stopped answering. It is asleep, or tokenstat is not running there.",
        )
    }
    return ConnectionUi(
        ok = false,
        down = true,
        service = true,
        title = "No connection",
        detail = "Signed in, but tokenstat is not answering. Your numbers are the last ones this device read.",
    )
}
