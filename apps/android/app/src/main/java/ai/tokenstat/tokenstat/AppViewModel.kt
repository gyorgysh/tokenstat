// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
package ai.tokenstat.tokenstat

import android.app.Application
import androidx.lifecycle.AndroidViewModel
import androidx.lifecycle.viewModelScope
import ai.tokenstat.tokenstat.core.CoreClient
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

data class ClientState(
    val loading: Boolean = true,
    val account: JsonObject? = null,
    val home: JsonObject? = null,
    val limits: JsonArray = JsonArray(emptyList()),
    val insights: JsonElement? = null,
    val error: String? = null,
) {
    val signedIn: Boolean get() = account?.get("signedIn")?.jsonPrimitive?.content == "true"
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
                mutableState.value = mutableState.value.copy(account = accountObject)
                if (accountObject["signedIn"]?.jsonPrimitive?.content == "true") loadDashboard()
            }
            .onFailure { mutableState.value = mutableState.value.copy(error = it.message) }
        mutableState.value = mutableState.value.copy(loading = false)
    }

    private suspend fun loadDashboard() {
        val calendar = viewModelScope.async {
            CoreClient.call("activity.calendar", buildJsonObject {
                put("weeks", 53); put("scope", "account"); put("force", false)
            })
        }
        val limits = viewModelScope.async { CoreClient.call("usage.limits") }
        val report = viewModelScope.async {
            CoreClient.call("account.report", buildJsonObject { put("group", "model"); put("weeks", 53) })
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
        runCatching { CoreClient.call("account.logout") }
        mutableState.value = ClientState(loading = false)
    }

    suspend fun workspaces(peer: String): JsonArray =
        CoreClient.remote(peer, "workspace.list") as? JsonArray ?: JsonArray(emptyList())

    suspend fun workspaceSection(peer: String, method: String, params: JsonObject): JsonElement =
        CoreClient.remote(peer, method, params)
}
