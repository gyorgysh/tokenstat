// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
package ai.tokenstat.tokenstat.notifications

import ai.tokenstat.tokenstat.ui.localization.L10n

import android.content.Context
import android.content.SharedPreferences
import androidx.annotation.VisibleForTesting
import ai.tokenstat.tokenstat.core.CoreClient
import com.google.firebase.messaging.FirebaseMessaging
import kotlin.coroutines.resume
import kotlinx.coroutines.suspendCancellableCoroutine
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.withTimeoutOrNull
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import kotlinx.serialization.json.booleanOrNull
import kotlinx.serialization.json.longOrNull
import kotlinx.serialization.json.put

object PushRegistrar {
    private val operation = Mutex()
    @VisibleForTesting
    internal var call: suspend (String, kotlinx.serialization.json.JsonObject) -> kotlinx.serialization.json.JsonElement =
        { method, params -> CoreClient.call(method, params) }
    private const val PREF = "ai.tokenstat.push"
    private const val KEY_ON = "enabled"
    private const val KEY_TOKEN = "token"
    private const val KEY_PENDING = "pendingRemoval"

    @Volatile private var app: Context? = null

    fun init(context: Context) {
        app = context.applicationContext
    }

    fun persist(token: String) {
        prefs()?.edit()?.putString(KEY_TOKEN, token)?.apply()
    }

    fun isOn(): Boolean = prefs()?.getBoolean(KEY_ON, false) == true

    suspend fun enable() = operation.withLock {
        val prefs = prefs() ?: return
        prefs.edit().putBoolean(KEY_ON, true).remove(KEY_PENDING).apply()
        refreshLocked()
    }

    suspend fun disable() = operation.withLock {
        val prefs = prefs() ?: return
        prefs.edit().putBoolean(KEY_ON, false).apply()
        dropServerRow(prefs)
    }

    suspend fun refresh() = operation.withLock { refreshLocked() }

    private suspend fun refreshLocked() {
        val prefs = prefs() ?: return
        runCatching {
            val pending = prefs.getString(KEY_PENDING, null)
            if (pending != null) {
                unregisterToken(pending)
                prefs.edit().remove(KEY_PENDING).apply()
            }
            if (!isOn()) return
            val token = withTimeoutOrNull(10_000) { currentToken() } ?: prefs.getString(KEY_TOKEN, null) ?: return
            persist(token)
            call("push.register", buildJsonObject {
                put("token", token)
                put("platform", "android")
                put("environment", "production")
            })
        }.onFailure { if (it is CancellationException) throw it }
    }

    suspend fun unregister(afterRemoval: suspend () -> Unit = {}) = operation.withLock {
        prefs()?.let { dropServerRow(it) }
        afterRemoval()
    }

    private suspend fun dropServerRow(prefs: SharedPreferences) {
        val token = prefs.getString(KEY_TOKEN, null) ?: return
        runCatching { unregisterToken(token) }
            .onSuccess { prefs.edit().remove(KEY_PENDING).apply() }
            .onFailure {
                prefs.edit().putString(KEY_PENDING, token).apply()
                if (it is CancellationException) throw it
            }
    }

    suspend fun test(): String? {
        val answer = call("push.test", buildJsonObject {}).jsonObject
        val signedIn = answer["signedIn"]?.jsonPrimitive?.booleanOrNull ?: true
        val enabled = answer["enabled"]?.jsonPrimitive?.booleanOrNull ?: true
        val sent = answer["sent"]?.jsonPrimitive?.longOrNull ?: 1
        if (!signedIn) return L10n.text("android.pushregistrar.sign_in_first_a_notification_has_to_reach.c1314d42")
        if (!enabled) return L10n.text("android.pushregistrar.notifications_are_not_switched_on_for_the.b82ba3c6")
        if (sent == 0L) return L10n.text("android.pushregistrar.the_account_has_no_device_to_notify_yet.bf208fe3")
        return null
    }

    fun registered(): Boolean = prefs()?.getString(KEY_TOKEN, null) != null

    private suspend fun unregisterToken(token: String) {
        call("push.unregister", buildJsonObject {
            put("token", token)
            put("platform", "android")
        })
    }

    private suspend fun currentToken(): String? = suspendCancellableCoroutine { cont ->
        runCatching {
            FirebaseMessaging.getInstance().token.addOnCompleteListener { task ->
                if (!cont.isActive) return@addOnCompleteListener
                val token = if (task.isSuccessful) task.result else null
                cont.resume(token)
            }
        }.onFailure {
            if (cont.isActive) cont.resume(null)
        }
    }

    @VisibleForTesting
    internal var prefsOverride: SharedPreferences? = null

    private fun prefs() = prefsOverride ?: app?.getSharedPreferences(PREF, Context.MODE_PRIVATE)
}
