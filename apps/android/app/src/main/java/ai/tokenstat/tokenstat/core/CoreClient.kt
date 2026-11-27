// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
package ai.tokenstat.tokenstat.core

import ai.tokenstat.tokenstat.ui.localization.L10n

import java.io.File
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.contentOrNull
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import kotlinx.serialization.json.put

class CoreFailure(val code: String, override val message: String) : Exception(message)

object CoreObserver {
    @Volatile
    var report: ((String, String?, Throwable?) -> Unit)? = null

    @Volatile
    var precheck: ((String) -> Throwable?)? = null

    fun note(method: String, peer: String?, error: Throwable?) {
        runCatching { report?.invoke(method, peer, error) }
    }
}

object CoreClient {
    val json = Json { ignoreUnknownKeys = true; explicitNulls = false }
    @Volatile private var initialized = false

    fun initialize(dataDir: File, cacheDir: File, deviceName: String) {
        if (initialized) return
        dataDir.mkdirs(); cacheDir.mkdirs()
        decodeResponse(NativeBridge.nativeInit(dataDir.absolutePath, cacheDir.absolutePath, deviceName))
        runCatching {
            NativeBridge.nativeCall("app.identify", buildJsonObject {
                put("version", ai.tokenstat.tokenstat.BuildConfig.VERSION_NAME)
                put("build", ai.tokenstat.tokenstat.BuildConfig.VERSION_CODE.toString())
            }.toString())
        }
        initialized = true
    }

    suspend fun call(method: String, params: JsonObject = buildJsonObject {}): JsonElement =
        withContext(Dispatchers.IO) {
            check(initialized) { L10n.text("android.coreclient.tokenstat_core_was_not_initialized.9a9100ab") }
            val peer = (params["peer"] as? JsonPrimitive)?.contentOrNull
            CoreObserver.precheck?.invoke(method)?.let { refusal ->
                CoreObserver.note(method, peer, refusal)
                throw refusal
            }
            try {
                val value = decodeResponse(NativeBridge.nativeCall(method, params.toString()))
                CoreObserver.note(method, peer, null)
                value
            } catch (cancelled: CancellationException) {
                throw cancelled
            } catch (error: Throwable) {
                CoreObserver.note(method, peer, error)
                throw error
            }
        }

    suspend fun remote(peer: String, method: String, params: JsonObject = buildJsonObject {}): JsonElement =
        call("remote.call", buildJsonObject {
            put("peer", peer); put("method", method); put("params", params)
        })

    internal fun decodeResponse(raw: String): JsonElement {
        val envelope = json.parseToJsonElement(raw).jsonObject
        if (envelope["ok"]?.jsonPrimitive?.content == "true") {
            return envelope["result"] ?: buildJsonObject {}
        }
        val error = envelope["error"]?.jsonObject
        throw CoreFailure(
            error?.get("code")?.jsonPrimitive?.content ?: "core",
            error?.get("message")?.jsonPrimitive?.content ?: L10n.text("android.coreclient.the_tokenstat_core_rejected_the_call.0e4909c6"),
        )
    }
}
