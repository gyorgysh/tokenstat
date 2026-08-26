// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
package ai.tokenstat.tokenstat.core

import java.io.File
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import kotlinx.serialization.json.put

class CoreFailure(val code: String, override val message: String) : Exception(message)

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
            decodeResponse(NativeBridge.nativeCall(method, params.toString()))
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
