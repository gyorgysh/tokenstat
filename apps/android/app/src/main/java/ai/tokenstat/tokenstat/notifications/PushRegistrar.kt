// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
package ai.tokenstat.tokenstat.notifications

import android.content.Context
import ai.tokenstat.tokenstat.core.CoreClient
import com.google.firebase.messaging.FirebaseMessaging
import kotlin.coroutines.resume
import kotlinx.coroutines.suspendCancellableCoroutine
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.put

/** FCM issues a token at install, usually while still signed out. Re-register
 *  after every confirmed sign-in, and unregister on sign-out, matching iOS. */
object PushRegistrar {
    private const val PREF = "ai.tokenstat.push"
    private const val KEY_TOKEN = "token"
    private const val KEY_PENDING = "pendingRemoval"

    @Volatile private var app: Context? = null

    fun init(context: Context) {
        app = context.applicationContext
    }

    fun persist(token: String) {
        prefs()?.edit()?.putString(KEY_TOKEN, token)?.apply()
    }

    suspend fun refresh() {
        val prefs = prefs() ?: return
        runCatching {
            val pending = prefs.getString(KEY_PENDING, null)
            if (pending != null) {
                unregisterToken(pending)
                prefs.edit().remove(KEY_PENDING).apply()
            }
            val token = currentToken() ?: prefs.getString(KEY_TOKEN, null) ?: return
            persist(token)
            CoreClient.call("push.register", buildJsonObject {
                put("token", token)
                put("platform", "android")
                put("environment", "production")
            })
        }
    }

    suspend fun unregister() {
        val prefs = prefs() ?: return
        val token = prefs.getString(KEY_TOKEN, null) ?: return
        runCatching { unregisterToken(token) }
            .onSuccess { prefs.edit().remove(KEY_TOKEN).remove(KEY_PENDING).apply() }
            .onFailure { prefs.edit().putString(KEY_PENDING, token).apply() }
    }

    suspend fun test() {
        CoreClient.call("push.test")
    }

    fun registered(): Boolean = prefs()?.getString(KEY_TOKEN, null) != null

    private suspend fun unregisterToken(token: String) {
        CoreClient.call("push.unregister", buildJsonObject {
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

    private fun prefs() = app?.getSharedPreferences(PREF, Context.MODE_PRIVATE)
}
