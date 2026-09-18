// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
package ai.tokenstat.tokenstat.core

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

/// What happened to a call that left this object. Installed once, at the
/// root, so no screen has to remember to report. Port of `BridgeObserver`.
object CoreObserver {
    /// Method name, the peer it was addressed to when there was one, and the
    /// failure, or null when it worked.
    ///
    /// The peer matters: "a machine is not answering" is a fact about that
    /// machine, and folding every peer into one verdict made a laptop asleep
    /// in a bag speak for the Mac being worked on.
    @Volatile
    var report: ((String, String?, Throwable?) -> Unit)? = null

    /// Asked before a call is made. Returning a failure refuses it without
    /// going near the transport.
    ///
    /// This exists for one case: a device with no internet. An account call
    /// made in airplane mode sits on its patience budget and then fails with
    /// the same answer it could have given immediately, and the screen waits
    /// half a minute to say "offline". Nothing else belongs here: a gate that
    /// starts guessing which calls are worth making is a gate that will block
    /// the one that would have recovered.
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
        initialized = true
    }

    suspend fun call(method: String, params: JsonObject = buildJsonObject {}): JsonElement =
        withContext(Dispatchers.IO) {
            check(initialized) { "tokenstat core was not initialized" }
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
            error?.get("message")?.jsonPrimitive?.content ?: "The tokenstat core rejected the call.",
        )
    }
}
