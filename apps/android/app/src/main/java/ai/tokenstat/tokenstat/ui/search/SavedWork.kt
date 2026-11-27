// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
package ai.tokenstat.tokenstat.ui.search

import ai.tokenstat.tokenstat.AppViewModel
import ai.tokenstat.tokenstat.ui.localization.L10n
import ai.tokenstat.tokenstat.ui.workspace.ChatDisplayItem
import android.content.Context
import android.security.keystore.KeyGenParameterSpec
import android.security.keystore.KeyProperties
import android.util.AtomicFile
import android.util.Base64
import java.io.DataInputStream
import java.io.File
import java.security.KeyStore
import java.security.MessageDigest
import java.security.SecureRandom
import javax.crypto.Cipher
import javax.crypto.KeyGenerator
import javax.crypto.SecretKey
import javax.crypto.spec.GCMParameterSpec
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import kotlinx.coroutines.withContext
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.booleanOrNull
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.contentOrNull
import kotlinx.serialization.json.jsonPrimitive
import kotlinx.serialization.json.put

internal class SavedWork private constructor(
    private val model: AppViewModel,
    private val context: Context,
    private val scope: String,
) {
    data class Copy(val id: String, val title: String, val text: String, val partial: Boolean)
    data class Transcript(val text: String, val partial: Boolean)

    fun isCurrent(): Boolean = scope == scope(model.state.value.account)

    suspend fun keep(peer: String, workspace: String, chat: String, title: String, text: String, partial: Boolean) {
        val id = digest("$peer\u0000$workspace\u0000$chat")
        val key = key(create = true) ?: error(L10n.text("android.savedwork.key_unavailable"))
        call("cache.put") {
            put("key", key); put("id", id); put("itemId", id); put("kind", "conversation")
            put("payload", buildJsonObject { put("title", title); put("text", text); put("partial", partial) })
        }
        call("cache.pin") { put("id", id); put("pinned", true) }
    }

    suspend fun ids(): List<String> = ((call("cache.list", {})["records"] as? JsonArray).orEmpty())
        .filterIsInstance<JsonObject>().filter { it.value("kind") == "conversation" }.mapNotNull { it.value("id") }

    suspend fun reader(): (suspend (String) -> Copy?)? {
        val key = key(create = false) ?: return null
        return { id ->
            val result = call("cache.get") { put("key", key); put("id", id) }
            val payload = result["payload"] as? JsonObject
            if (result.value("scope") != scope || result.value("kind") != "conversation" || result.value("id") != id || payload == null) null
            else Copy(id, payload.value("title").orEmpty(), payload.value("text").orEmpty(), payload["partial"]?.jsonPrimitive?.booleanOrNull == true)
        }
    }

    suspend fun remove(id: String) { call("cache.remove") { put("id", id) } }

    private suspend fun call(method: String, params: kotlinx.serialization.json.JsonObjectBuilder.() -> Unit): JsonObject {
        if (!isCurrent()) throw CancellationException()
        val result = model.core(method, buildJsonObject { put("scope", scope); params() }) as JsonObject
        if (!isCurrent()) throw CancellationException()
        return result
    }

    private suspend fun key(create: Boolean): String? = withContext(Dispatchers.IO) {
        keyGate.withLock {
            if (!isCurrent()) throw CancellationException()
            val file = AtomicFile(File(context.noBackupFilesDir, "$scope.key".replace(':', '-')))
            val keyStore = KeyStore.getInstance("AndroidKeyStore").apply { load(null) }
            val cipher = Cipher.getInstance("AES/GCM/NoPadding")
            val existing = keyStore.getKey(ALIAS, null) as? SecretKey
            val keyFile = try {
                DataInputStream(file.openRead()).use { input ->
                    ByteArray(60).also {
                        input.readFully(it)
                        check(input.read() == -1) { L10n.text("android.savedwork.key_unavailable") }
                    }
                }
            } catch (_: java.io.FileNotFoundException) { null }
            if (keyFile != null) {
                check(keyFile.size == 60 && existing != null) { L10n.text("android.savedwork.key_unavailable") }
                cipher.init(Cipher.DECRYPT_MODE, existing, GCMParameterSpec(128, keyFile, 0, 12))
                cipher.updateAAD(scope.toByteArray())
                val raw = cipher.doFinal(keyFile, 12, 48)
                try { return@withLock Base64.encodeToString(raw, Base64.NO_WRAP) } finally { raw.fill(0) }
            }
            if (!create) return@withLock null
            check(ids().isEmpty()) { L10n.text("android.savedwork.key_unavailable") }
            val wrappingKey = existing ?: KeyGenerator.getInstance(KeyProperties.KEY_ALGORITHM_AES, "AndroidKeyStore").run {
                init(KeyGenParameterSpec.Builder(ALIAS, KeyProperties.PURPOSE_ENCRYPT or KeyProperties.PURPOSE_DECRYPT)
                    .setBlockModes(KeyProperties.BLOCK_MODE_GCM)
                    .setEncryptionPaddings(KeyProperties.ENCRYPTION_PADDING_NONE)
                    .setKeySize(256).build())
                generateKey()
            }
            val raw = ByteArray(32).also(SecureRandom()::nextBytes)
            try {
                cipher.init(Cipher.ENCRYPT_MODE, wrappingKey)
                cipher.updateAAD(scope.toByteArray())
                val output = file.startWrite()
                try {
                    output.write(cipher.iv + cipher.doFinal(raw))
                    file.finishWrite(output)
                } catch (error: Exception) { file.failWrite(output); throw error }
                Base64.encodeToString(raw, Base64.NO_WRAP)
            } finally { raw.fill(0) }
        }
    }

    companion object {
        private const val ALIAS = "ai.tokenstat.saved-work.v1"
        private const val MaximumCharacters = 300_000
        private val keyGate = Mutex()

        fun open(model: AppViewModel, context: Context): SavedWork? =
            scope(model.state.value.account)?.let { SavedWork(model, context.applicationContext, it) }

        fun transcript(items: List<ChatDisplayItem>, hasEarlier: Boolean): Transcript? {
            val lines = ArrayList<String>()
            var remaining = MaximumCharacters
            var partial = hasEarlier
            for (item in items.asReversed()) {
                val text = when (item) {
                    is ChatDisplayItem.User -> item.text
                    is ChatDisplayItem.Assistant -> item.text
                    else -> continue
                }.trim()
                if (text.isEmpty()) continue
                val speaker = if (item is ChatDisplayItem.User) {
                    L10n.text("android.savedwork.you")
                } else {
                    L10n.text("android.savedwork.agent")
                }
                val line = "$speaker\n$text"
                if (line.length + 2 > remaining) {
                    if (lines.isEmpty()) {
                        var end = MaximumCharacters - 1
                        if (line[end - 1].isHighSurrogate()) end--
                        lines.add(line.take(end) + "…")
                    }
                    partial = true
                    break
                }
                lines.add(line)
                remaining -= line.length + 2
            }
            if (lines.isEmpty()) return null
            return Transcript(lines.asReversed().joinToString("\n\n"), partial)
        }

        private fun scope(account: JsonObject?): String? {
            if (account?.get("signedIn")?.jsonPrimitive?.booleanOrNull != true) return null
            val owner = account.value("accountId")?.takeIf(String::isNotBlank) ?: return null
            return "android:" + digest(account.value("host").orEmpty() + "\u0000" + owner)
        }

        private fun digest(value: String): String = MessageDigest.getInstance("SHA-256")
            .digest(value.toByteArray()).joinToString("") { "%02x".format(it) }
        private fun JsonObject.value(key: String) = get(key)?.jsonPrimitive?.contentOrNull
    }
}
