// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
package ai.tokenstat.tokenstat

import android.app.Application
import androidx.lifecycle.AndroidViewModel
import androidx.lifecycle.viewModelScope
import ai.tokenstat.tokenstat.core.CoreClient
import ai.tokenstat.tokenstat.core.CoreFailure
import ai.tokenstat.tokenstat.notifications.PushRegistrar
import kotlinx.coroutines.async
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.launch
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
    val insights: JsonElement? = null,
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
}

class AppViewModel(app: Application) : AndroidViewModel(app) {
    private val mutableState = MutableStateFlow(ClientState())
    val state = mutableState.asStateFlow()

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
        // Proto 5 coherent snapshot first (what the Mac Insights model uses);
        // fall back to the legacy per-model report when the host is older.
        val report = viewModelScope.async {
            runCatching { CoreClient.call("insights.snapshot", buildJsonObject {}) }.getOrElse {
                CoreClient.call("account.report", buildJsonObject { put("group", "model"); put("weeks", 53) })
            }
        }
        runCatching { calendar.await() }.onSuccess {
            mutableState.value = mutableState.value.copy(home = (it as? JsonObject))
        }
        runCatching { limits.await() }.onSuccess {
            mutableState.value = mutableState.value.copy(limits = it as? JsonArray ?: JsonArray(emptyList()))
        }
        runCatching { report.await() }.onSuccess {
            mutableState.value = mutableState.value.copy(insights = it)
        }
    }

    suspend fun beginLogin(): String {
        val login = CoreClient.call("account.deviceStart").jsonObject
        val url = login["openUrl"]?.jsonPrimitive?.content
            ?: throw IllegalStateException("The account did not return a sign-in URL.")
        viewModelScope.launch {
            repeat(120) {
                delay(2_000)
                val poll = runCatching { CoreClient.call("account.devicePoll") }.getOrNull() ?: return@repeat
                if (poll.jsonObject["state"]?.jsonPrimitive?.content == "confirmed") {
                    refresh(); return@launch
                }
            }
        }
        return url
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

    suspend fun prepareHost(peer: String, label: String) {
        CoreClient.call("machine.pair", buildJsonObject {
            put("key", peer)
            put("label", label)
            put("address", "")
        })
        CoreClient.call("remote.serve", buildJsonObject { put("tunnel", true) })
    }

    suspend fun workspaces(peer: String): JsonArray =
        CoreClient.remote(peer, "workspace.list") as? JsonArray ?: JsonArray(emptyList())

    suspend fun hostStats(peer: String): JsonObject =
        CoreClient.remote(peer, "host.stats") as? JsonObject ?: buildJsonObject {}

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
