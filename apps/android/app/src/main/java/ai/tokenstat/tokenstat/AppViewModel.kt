// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
package ai.tokenstat.tokenstat

import ai.tokenstat.tokenstat.ui.localization.L10n

import android.app.Application
import androidx.lifecycle.AndroidViewModel
import androidx.lifecycle.viewModelScope
import ai.tokenstat.tokenstat.core.ConnectivityMonitor
import ai.tokenstat.tokenstat.core.CoreClient
import ai.tokenstat.tokenstat.ecosystem.UsageWidgetStore
import ai.tokenstat.tokenstat.core.CoreFailure
import ai.tokenstat.tokenstat.core.CoreObserver
import ai.tokenstat.tokenstat.core.NetworkGate
import ai.tokenstat.tokenstat.notifications.PushRegistrar
import ai.tokenstat.tokenstat.ui.logic.ConnectionTracker
import ai.tokenstat.tokenstat.ui.logic.GeneralFolder
import ai.tokenstat.tokenstat.ui.logic.ConnectionUiState
import ai.tokenstat.tokenstat.ui.logic.NetworkClassifier
import ai.tokenstat.tokenstat.ui.logic.NetworkPlane
import ai.tokenstat.tokenstat.ui.logic.tagSignInUrl
import ai.tokenstat.tokenstat.ui.ssh.SshConnectionState
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.Job
import kotlinx.coroutines.NonCancellable
import kotlinx.coroutines.cancelAndJoin
import kotlinx.coroutines.supervisorScope
import kotlinx.coroutines.withContext
import kotlinx.coroutines.async
import kotlinx.coroutines.delay
import kotlinx.coroutines.ensureActive
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.update
import kotlinx.coroutines.launch
import kotlinx.serialization.json.booleanOrNull
import kotlinx.serialization.json.longOrNull
import kotlinx.serialization.json.contentOrNull
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.JsonNull
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import kotlinx.serialization.json.put

typealias ConnectionUi = ConnectionUiState

data class ClientState(
    val loading: Boolean = true,
    val account: JsonObject? = null,
    val home: JsonObject? = null,
    val limits: JsonArray = JsonArray(emptyList()),
    val limitsError: String? = null,
    val error: String? = null,
    val connection: ConnectionUi = ConnectionUi(),
    val authChecked: Boolean = false,
    val authError: String? = null,
) {
    val signedIn: Boolean get() = account?.get("signedIn")?.jsonPrimitive?.content == "true"

    val authPending: Boolean get() = !authChecked && authError == null

    val authNeedsRetry: Boolean get() = !authChecked && authError != null
    val canRemote: Boolean
        get() {
            val flag = account?.get("canRemote")
            if (flag != null && flag !is JsonNull) {
                return flag.jsonPrimitive.content == "true"
            }
            val tier = account?.get("tier")?.jsonPrimitive?.content?.lowercase()
            return signedIn && tier in listOf("free", "supporter", "patron", "legend")
        }
    val vaultAllowed: Boolean
        get() {
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
    private var refreshJob: Job? = null
    private var dashboardJob: Job? = null
    private var signingOut = false
    val chatTurnTimes = ai.tokenstat.tokenstat.ui.logic.ChatTurnTimes()

    private val mutableState = MutableStateFlow(ClientState())
    val state = mutableState.asStateFlow()

    val chatDrafts = ai.tokenstat.tokenstat.ui.logic.ChatDraftFiles(java.io.File(app.filesDir, "chat-drafts"))

    val chatComposers = ai.tokenstat.tokenstat.ui.logic.ChatComposerSessions<ai.tokenstat.tokenstat.ui.workspace.StagedAttachment>(
        attachmentCost = { it.data.length.toLong() * 2 + it.name.length.toLong() * 2 },
        saved = chatDrafts,
    )
    private val mutableNewChatSetups = MutableStateFlow<Map<String, ai.tokenstat.tokenstat.ui.workspace.NewChatSetup>>(emptyMap())
    val newChatSetups = mutableNewChatSetups.asStateFlow()
    fun rememberNewChatSetup(owner: String?, setup: ai.tokenstat.tokenstat.ui.workspace.NewChatSetup?) {
        if (owner != null && setup != null) mutableNewChatSetups.value = mutableNewChatSetups.value + (owner to setup)
    }

    fun finishNewChatSetup(request: ai.tokenstat.tokenstat.ui.workspace.NewChatRequest) {
        val owner = request.source.owner ?: return
        val current = mutableNewChatSetups.value[owner]
        val next = ai.tokenstat.tokenstat.ui.workspace.nextNewChatSetup(current, request.setup,
            request.sourceTransferred, chatComposers.hasWriting(owner))
        if (next != null && next != current) mutableNewChatSetups.value = mutableNewChatSetups.value + (owner to next)
    }

    val sshConnections = SshConnectionState(::core)

    val workspacesConnection = ai.tokenstat.tokenstat.ui.workspace.WorkspacesConnectionState()

    private val mutableNetworkRecoveryEpoch = MutableStateFlow(0L)
    val networkRecoveryEpoch = mutableNetworkRecoveryEpoch.asStateFlow()

    private val tracker = ConnectionTracker()
    private val connectivity = ConnectivityMonitor(app, viewModelScope)

    private val planLimits = ai.tokenstat.tokenstat.ui.logic.PlanLimitsReader(
        scope = viewModelScope,
        owner = {
            UsageWidgetStore.lease()?.takeIf { lease ->
                !signingOut && lease.owner == state.value.account?.let(ai.tokenstat.tokenstat.ecosystem.UsageSnapshot::owner)
            }
        },
        read = { force ->
            CoreClient.call("usage.limits", buildJsonObject { put("force", force) }) as? JsonArray
                ?: throw CoreFailure("invalid_response", L10n.text("common.chat.stats.unavailable"))
        },
        publish = { result ->
            val lease = UsageWidgetStore.lease()
            result.onSuccess { limits ->
                if (lease != null) UsageWidgetStore.publishLimits(getApplication(), lease, limits)
                mutableState.update { it.copy(limits = limits, limitsError = null) }
            }.onFailure { error ->
                if (lease != null) UsageWidgetStore.failedLimits(getApplication(), lease)
                mutableState.update { it.copy(limitsError = error.message ?: L10n.text("common.chat.stats.unavailable")) }
            }
        },
    )

    suspend fun refreshLimits(force: Boolean = false) = planLimits.refresh(force)

    init {
        CoreObserver.report = { method, peer, error -> noteCall(method, peer, error) }
        CoreObserver.precheck = { method ->
            if (NetworkGate.isOffline && NetworkPlane.of(method) != null) {
                CoreFailure("offline", L10n.text("android.appviewmodel.this_device_is_offline.84b7cf97"))
            } else {
                null
            }
        }
        connectivity.start()
        tracker.setPath(connectivity.status.value)
        publishConnection()
        viewModelScope.launch {
            connectivity.status.collect { path ->
                tracker.setPath(path)
                publishConnection()
            }
        }
        viewModelScope.launch {
            connectivity.restored.collect {
                tracker.reset()
                publishConnection()
                refresh()
                nudgeTunnel(reconnect = true)
                mutableNetworkRecoveryEpoch.value += 1
            }
        }
        refresh()
    }

    override fun onCleared() {
        super.onCleared()
        connectivity.stop()
        CoreObserver.report = null
        CoreObserver.precheck = null
    }

    private fun noteCall(method: String, peer: String?, error: Throwable?) {
        val plane = NetworkPlane.of(method) ?: return
        val kind = error?.let {
            NetworkClassifier.kind((it as? CoreFailure)?.code.orEmpty(), it.message.orEmpty())
        }
        tracker.note(plane, peer, kind, System.currentTimeMillis())
        publishConnection()
    }

    private fun publishConnection() {
        NetworkGate.isOffline = tracker.offline
        val next = tracker.ui()
        mutableState.update { current ->
            if (current.connection == next) current else current.copy(connection = next)
        }
    }

    fun refresh(): Job {
        if (signingOut) return viewModelScope.launch { }
        refreshJob?.cancel()
        refreshJob = viewModelScope.launch { refreshAccount() }
        return refreshJob!!
    }

    private suspend fun refreshAccount() {
        val widgetEpoch = UsageWidgetStore.epoch()
        mutableState.value = mutableState.value.copy(loading = true, error = null)
        runCatching { CoreClient.call("account.status") }
            .onSuccess { account ->
                val accountObject = account.jsonObject
                if (signingOut || !UsageWidgetStore.verifyForeground(getApplication(), accountObject, widgetEpoch)) return@onSuccess
                ai.tokenstat.tokenstat.ecosystem.SystemProjects.verify(getApplication(), accountObject)
                syncWorkspaceAccount(accountObject)
                val sameOwner = ai.tokenstat.tokenstat.ecosystem.UsageSnapshot.owner(accountObject) ==
                    state.value.account?.let(ai.tokenstat.tokenstat.ecosystem.UsageSnapshot::owner)
                mutableState.value = mutableState.value.copy(
                    limits = if (sameOwner) state.value.limits else JsonArray(emptyList()),
                    limitsError = if (sameOwner) state.value.limitsError else null,
                    account = accountObject,
                    authChecked = true,
                    authError = null,
                )
                notePeerNames(
                    ((accountObject["machines"] as? JsonArray).orEmpty())
                        .mapNotNull { it as? JsonObject }
                        .mapNotNull { machine ->
                            val key = (machine["publicIdentity"] as? JsonPrimitive)?.contentOrNull
                            val label = (machine["label"] as? JsonPrimitive)?.contentOrNull
                            if (key.isNullOrBlank() || label.isNullOrBlank()) null else key to label
                        }
                        .toMap(),
                )
                if (accountObject["signedIn"]?.jsonPrimitive?.content == "true") {
                    PushRegistrar.refresh()
                    loadDashboard()
                } else {
                    mutableState.update { it.copy(home = null) }
                }
            }
            .onFailure { err ->
                if (err is CancellationException) throw err
                mutableState.value = mutableState.value.copy(
                    error = err.message,
                    authError = err.message ?: L10n.text("android.appviewmodel.the_account_could_not_be_reached.3159ef5a"),
                )
            }
        mutableState.value = mutableState.value.copy(loading = false)
    }

    fun retryConnection() {
        connectivity.checkNow()
        tracker.reset()
        publishConnection()
        refresh()
    }

    fun notePeerNames(names: Map<String, String>) {
        tracker.setPeerNames(names)
        publishConnection()
    }

    private suspend fun loadDashboard() = supervisorScope {
        val widgetLease = UsageWidgetStore.lease()
        val calendar = async {
            CoreClient.call("activity.calendar", buildJsonObject {
                put("weeks", 53); put("scope", "account"); put("force", false)
            })
        }
        val limits = async { refreshLimits() }
        runCatching { calendar.await() }.onFailure {
            if (it is CancellationException) throw it
        }.onSuccess {
            mutableState.value = mutableState.value.copy(home = (it as? JsonObject))
            if (widgetLease != null && (it is JsonObject || it is JsonNull)) UsageWidgetStore.publish(getApplication(), widgetLease, it as? JsonObject)
        }.onFailure {
            UsageWidgetStore.failed(getApplication(), widgetLease)
        }
        limits.await()
    }

    suspend fun accountReport(group: String, weeks: Int = 53): JsonObject =
        core("account.report", buildJsonObject { put("group", group); put("weeks", weeks) }) as JsonObject

    private val _pendingLogin = MutableStateFlow<PendingLogin?>(null)
    val pendingLogin = _pendingLogin.asStateFlow()
    private val _signInNotice = MutableStateFlow<String?>(null)
    val signInNotice = _signInNotice.asStateFlow()
    private val _signInError = MutableStateFlow<String?>(null)
    val signInError = _signInError.asStateFlow()
    private var signInJob: Job? = null

    fun signIn(openPage: (String) -> Unit) {
        if (signInJob?.isActive == true) {
            _pendingLogin.value?.let { openPage(it.url) }
            return
        }
        if (signingOut) return
        _signInError.value = null
        val previous = signInJob
        signInJob = viewModelScope.launch {
            previous?.join()
            try {
                val device = CoreClient.call("account.deviceStart").jsonObject
                val raw = device["openUrl"]?.jsonPrimitive?.content
                    ?: throw IllegalStateException(L10n.text("android.appviewmodel.the_account_did_not_return_a_sign_in_url.f1bc27a1"))
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
                                    _signInNotice.value = L10n.text("android.appviewmodel.waiting_for_the_network.76a08f16")
                                    delay(maxOf(interval, 3L) * 1_000)
                                    continue
                                }
                                cancelLogin()
                                throw SignInFailed(L10n.text("android.appviewmodel.the_account_service_could_not_be_reached_a.445bdbf0"))
                            }
                            SignInPollFailure.INVALID_GRANT -> {
                                cancelLogin()
                                throw SignInFailed(L10n.text("android.appviewmodel.that_sign_in_expired_start_again.28cffde9"))
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
                _signInError.value = L10n.text("android.appviewmodel.the_sign_in_code_expired_before_it_was_con.84ac1b4b")
            } catch (e: CancellationException) {
                withContext(NonCancellable) { cancelLogin() }
                throw e
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

    fun presentSignInPage(openPage: (String) -> Unit) {
        _pendingLogin.value?.let { openPage(it.url) }
    }

    fun cancelSignIn() {
        signInJob?.cancel()
    }

    private suspend fun cancelLogin() {
        runCatching { CoreClient.call("account.cancelLogin") }
    }

    fun signOut() = viewModelScope.launch {
        if (signingOut) return@launch
        signingOut = true
        chatTurnTimes.clear()
        UsageWidgetStore.clear(getApplication(), block = true)
        ai.tokenstat.tokenstat.ecosystem.SystemProjects.clear(getApplication())
        try {
            planLimits.retire()
            signInJob?.cancelAndJoin()
            refreshJob?.cancelAndJoin()
            dashboardJob?.cancelAndJoin()
            ai.tokenstat.tokenstat.ecosystem.SystemProjects.flush()
            PushRegistrar.unregister { CoreClient.call("account.logout") }
            workspacesConnection.setAccountOwner(null)
            ai.tokenstat.tokenstat.notifications.VisibleChat.hidden()
            mutableState.value = ClientState(loading = false, authChecked = true,
                connection = mutableState.value.connection)
        } catch (error: CancellationException) {
            throw error
        } catch (error: Exception) {
            mutableState.update { it.copy(loading = false, error = error.message) }
        } finally {
            signingOut = false
        }
    }

    fun applyAccount(element: JsonElement) = viewModelScope.launch {
        if (signingOut || !state.value.signedIn) return@launch
        val account = element as? JsonObject ?: return@launch
        if (ai.tokenstat.tokenstat.ecosystem.UsageSnapshot.owner(account) != state.value.account?.let(ai.tokenstat.tokenstat.ecosystem.UsageSnapshot::owner)) return@launch
        if (!UsageWidgetStore.verifyForeground(getApplication(), account, UsageWidgetStore.epoch())) return@launch
        ai.tokenstat.tokenstat.ecosystem.SystemProjects.verify(getApplication(), account)
        syncWorkspaceAccount(account)
        mutableState.value = mutableState.value.copy(account = account)
        if (account["signedIn"]?.jsonPrimitive?.content == "true") {
            dashboardJob?.cancel()
            dashboardJob = viewModelScope.launch { loadDashboard() }
        }
    }

    data class HandleAnswer(val available: Boolean, val reason: String?, val message: String)

    suspend fun checkHandle(handle: String): HandleAnswer {
        val answer = CoreClient.call("account.checkHandle", buildJsonObject { put("handle", handle) }).jsonObject
        return HandleAnswer(
            available = answer["available"]?.jsonPrimitive?.booleanOrNull == true,
            reason = (answer["reason"] as? JsonPrimitive)?.contentOrNull,
            message = (answer["message"] as? JsonPrimitive)?.contentOrNull.orEmpty(),
        )
    }

    suspend fun claimHandle(handle: String) =
        changeProfile("account.claimHandle", buildJsonObject { put("handle", handle) })

    suspend fun setProfile(public: Boolean? = null, indexable: Boolean? = null) =
        changeProfile("account.setVisibility", buildJsonObject {
            public?.let { put("public", it) }
            indexable?.let { put("indexable", it) }
        })

    fun answerHandleOffer() {
        val account = state.value.account
        ai.tokenstat.tokenstat.ui.account.HandleOffer.markAnswered(getApplication(), account)
        if (ai.tokenstat.tokenstat.ui.account.AccountProfile.from(account)?.handle != null) return
        viewModelScope.launch {
            try { changeProfile("account.skipHandle", buildJsonObject {}) }
            catch (cancelled: CancellationException) { throw cancelled }
            catch (_: Exception) { }
        }
    }

    private suspend fun changeProfile(method: String, params: JsonObject) {
        refreshJob?.join()
        applyAccount(CoreClient.call(method, params)).join()
    }

    private fun syncWorkspaceAccount(account: JsonObject) {
        workspacesConnection.setAccountOwner(ai.tokenstat.tokenstat.ui.home.HomeStores.pinIdentity(account).ifBlank { null })
        (account["machines"] as? JsonArray)?.let { machines ->
            val thisId = account["thisMachineId"]?.jsonPrimitive?.contentOrNull
            workspacesConnection.setKnownHosts(machines.mapNotNull { machine ->
                val entry = machine as? JsonObject ?: return@mapNotNull null
                if (entry["kind"]?.jsonPrimitive?.contentOrNull == "client" ||
                    (thisId != null && entry["id"]?.jsonPrimitive?.contentOrNull == thisId)) return@mapNotNull null
                entry["publicIdentity"]?.jsonPrimitive?.contentOrNull
            }.toSet())
        }
    }

    suspend fun machineIdentity(): JsonObject =
        CoreClient.call("machine.identity") as? JsonObject ?: buildJsonObject {}

    suspend fun machinePeers(): JsonArray =
        CoreClient.call("machine.peers") as? JsonArray ?: JsonArray(emptyList())

    suspend fun prepareHost(peer: String, label: String) {
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

    suspend fun nudgeTunnel(reconnect: Boolean = false) {
        runCatching {
            CoreClient.call("remote.nudge", buildJsonObject { put("reconnect", reconnect) })
        }
    }

    suspend fun nudgeTunnelOnForeground() {
        val offline = runCatching {
            val status = CoreClient.call("remote.status") as? JsonObject
            (status?.get("tunnelOnline") as? kotlinx.serialization.json.JsonPrimitive)?.booleanOrNull == false
        }.getOrNull() == true
        nudgeTunnel(reconnect = offline)
    }

    suspend fun pairPeer(peer: String, label: String) {
        CoreClient.call("machine.pair", buildJsonObject {
            put("key", peer)
            put("label", label)
            put("address", "")
        })
    }

    suspend fun workspaces(peer: String): JsonArray {
        val owner = ai.tokenstat.tokenstat.ecosystem.SystemProjects.owner
        val folders = workspaceFolders(peer) ?: JsonArray(emptyList())
        ai.tokenstat.tokenstat.ecosystem.SystemProjects.replace(getApplication(), peer, folders, owner)
        return folders
    }

    suspend fun hostStats(peer: String): JsonObject =
        CoreClient.remote(peer, "host.stats") as? JsonObject ?: buildJsonObject {}

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

    suspend fun workspaceFolders(peer: String, includeGit: Boolean = true): JsonArray? {
        val params = buildJsonObject {
            put(GeneralFolder.INCLUDE, true)
            put("includeGit", includeGit)
        }
        val folders = CoreClient.remote(peer, "workspace.list", params) as? JsonArray ?: return null
        return GeneralFolder.present(folders, L10n.text("common.new_chat.no_repository"))
    }

    data class AgentUpdateNotice(val text: String, val done: Boolean, val failed: Boolean)
    private val mutableAgentUpdate = MutableStateFlow<AgentUpdateNotice?>(null)
    val agentUpdate = mutableAgentUpdate.asStateFlow()
    private val mutableUpdatingAgent = MutableStateFlow<String?>(null)
    val updatingAgent = mutableUpdatingAgent.asStateFlow()

    fun dismissAgentUpdate() {
        if (mutableAgentUpdate.value?.done == true) mutableAgentUpdate.value = null
    }

    fun updateAgent(peer: String, id: String, label: String, finished: (JsonObject?) -> Unit = {}) {
        if (mutableUpdatingAgent.value != null) {
            finished(null)
            return
        }
        mutableUpdatingAgent.value = id
        mutableAgentUpdate.value = AgentUpdateNotice(L10n.text("common.agent_updates.toast_updating", label), done = false, failed = false)
        viewModelScope.launch {
            val result = runCatching {
                workspaceSection(peer, "launcher.update", buildJsonObject { put("id", id) }) as? JsonObject
            }.getOrNull()
            fun text(key: String) = (result?.get(key) as? JsonPrimitive)?.contentOrNull
            val ok = (result?.get("ok") as? JsonPrimitive)?.booleanOrNull == true
            val before = text("before")
            val after = text("after")
            val message = when {
                !ok -> L10n.text("common.agent_updates.toast_failed", label)
                before != null && after != null && before != after ->
                    L10n.text("common.agent_updates.toast_updated", label, before, after)
                after != null -> L10n.text("common.agent_updates.toast_current", label, after)
                else -> L10n.text("common.agent_updates.toast_finished", label)
            }
            mutableAgentUpdate.value = AgentUpdateNotice(message, done = true, failed = !ok)
            mutableUpdatingAgent.value = null
            finished(result)
        }
    }

    suspend fun core(method: String, params: JsonObject = buildJsonObject {}): JsonElement =
        CoreClient.call(method, params)
}
