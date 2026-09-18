// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
package ai.tokenstat.tokenstat.notifications

import android.content.Context
import android.content.SharedPreferences
import androidx.annotation.VisibleForTesting
import ai.tokenstat.tokenstat.core.CoreClient
import com.google.firebase.messaging.FirebaseMessaging
import kotlin.coroutines.resume
import kotlinx.coroutines.suspendCancellableCoroutine
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import kotlinx.serialization.json.booleanOrNull
import kotlinx.serialization.json.longOrNull
import kotlinx.serialization.json.put

/** FCM issues a token at install, usually while still signed out. Re-register
 *  after every confirmed sign-in, and unregister on sign-out, matching the
 *  Apple client's PushRegistrar: off until asked for, every launch
 *  re-registers while on, and a removal that never landed is retried first.
 *
 *  Needs `app/google-services.json` from the Firebase console (gitignored)
 *  plus a server that accepts the android platform and holds an FCM key.
 *  Without both, registration fails and the settings row says so. */
object PushRegistrar {
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

    /** Whether this device wants notifications. Off until asked for. */
    fun isOn(): Boolean = prefs()?.getBoolean(KEY_ON, false) == true

    /** Turn notifications on: remember the choice, drop a moot pending
     *  removal, and register. A removal that never landed is moot now: this
     *  device is asking to be sent to again, and retrying it later would
     *  take it back off. */
    suspend fun enable() {
        val prefs = prefs() ?: return
        prefs.edit().putBoolean(KEY_ON, true).remove(KEY_PENDING).apply()
        refresh()
    }

    /** Stop notifications at the account rather than only on this device, so
     *  nothing is sent that Do Not Disturb happens to hide. The token comes
     *  from the stored one when FCM has not handed one over yet this launch,
     *  and a removal that does not reach the account is remembered rather
     *  than dropped. */
    suspend fun disable() {
        val prefs = prefs() ?: return
        prefs.edit().putBoolean(KEY_ON, false).apply()
        dropServerRow(prefs)
    }

    /** Re-register at launch, and after signing in. Cheap, and the only
     *  thing that keeps a reissued token reachable. Also finishes a removal
     *  that never reached the account, before registering, or a device that
     *  was switched off offline and switched back on would race its own
     *  removal. Does nothing while switched off. */
    suspend fun refresh() {
        val prefs = prefs() ?: return
        runCatching {
            val pending = prefs.getString(KEY_PENDING, null)
            if (pending != null) {
                unregisterToken(pending)
                prefs.edit().remove(KEY_PENDING).apply()
            }
            if (!isOn()) return
            val token = currentToken() ?: prefs.getString(KEY_TOKEN, null) ?: return
            persist(token)
            CoreClient.call("push.register", buildJsonObject {
                put("token", token)
                put("platform", "android")
                put("environment", "production")
            })
        }
    }

    /** Sign-out: drop this device's server row but keep the switch, so
     *  signing back in re-registers through `refresh()`.
     *
     *  Differs from `disable()` on purpose. The Apple client keeps its
     *  preference across sign-out too, and a switch that silently turns
     *  itself off on sign-out is one nobody turns back on: the toggle
     *  would read off for somebody who asked for on. */
    suspend fun unregister() {
        prefs()?.let { dropServerRow(it) }
    }

    /** Remove the stored token from the account, remembering a removal that
     *  never landed so `refresh()` retries it before registering again. */
    private suspend fun dropServerRow(prefs: SharedPreferences) {
        val token = prefs.getString(KEY_TOKEN, null) ?: return
        runCatching { unregisterToken(token) }
            .onSuccess { prefs.edit().remove(KEY_PENDING).apply() }
            .onFailure { prefs.edit().putString(KEY_PENDING, token).apply() }
    }

    /** Ask the account to send one, so somebody can tell "on" from "on but
     *  nothing has happened yet". Returns the settings sentence, or null
     *  when the test landed. Throws when the request itself failed. */
    suspend fun test(): String? {
        val answer = CoreClient.call("push.test").jsonObject
        val signedIn = answer["signedIn"]?.jsonPrimitive?.booleanOrNull ?: true
        val enabled = answer["enabled"]?.jsonPrimitive?.booleanOrNull ?: true
        val sent = answer["sent"]?.jsonPrimitive?.longOrNull ?: 1
        if (!signedIn) return "Sign in first. A notification has to reach this device from your account."
        if (!enabled) return "Notifications are not switched on for the service yet. Nothing is wrong with this device."
        if (sent == 0L) return "The account has no device to notify yet."
        return null
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

    @VisibleForTesting
    internal var prefsOverride: SharedPreferences? = null

    private fun prefs() = prefsOverride ?: app?.getSharedPreferences(PREF, Context.MODE_PRIVATE)
}
