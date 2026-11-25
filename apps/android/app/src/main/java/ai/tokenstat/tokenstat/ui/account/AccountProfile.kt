// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
package ai.tokenstat.tokenstat.ui.account

import android.content.Context
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.booleanOrNull
import kotlinx.serialization.json.contentOrNull
import kotlinx.serialization.json.intOrNull

/// The account's handle and who may open the page it names.
data class AccountProfile(
    val host: String,
    val handle: String?,
    val isPublic: Boolean,
    /// Null when the account service has no routes behind these settings, so
    /// no control is offered that could only fail.
    val settings: Settings?,
) {
    data class Settings(val indexable: Boolean, val changeDays: Int, val prompted: Boolean)

    /// A server without these settings and an account with no page leave
    /// nothing to show.
    val visible: Boolean get() = settings != null || handle != null

    companion object {
        fun from(account: JsonObject?): AccountProfile? {
            if (account?.flag("signedIn") != true) return null
            val raw = account["profile"] as? JsonObject
            return AccountProfile(
                host = account.text("host") ?: "https://tokenstat.ai",
                handle = account.text("handle"),
                isPublic = raw?.flag("public") ?: account.flag("profilePublic") ?: false,
                settings = raw?.let {
                    Settings(
                        indexable = it.flag("indexable") ?: true,
                        changeDays = (it["handleChangeDays"] as? JsonPrimitive)?.intOrNull ?: 0,
                        // An offer nobody can confirm was never made must not
                        // be made twice.
                        prompted = it.flag("handlePrompted") ?: true,
                    )
                },
            )
        }

        private fun JsonObject.flag(key: String) = (this[key] as? JsonPrimitive)?.booleanOrNull
        private fun JsonObject.text(key: String) =
            (this[key] as? JsonPrimitive)?.takeIf { it.isString }?.contentOrNull?.trim()?.ifEmpty { null }
    }
}

/// The one-time offer's answer on this device. The account keeps its own, and
/// this one is for when the account could not be told.
object HandleOffer {
    private fun prefs(context: Context) = context.getSharedPreferences("handleOffer", Context.MODE_PRIVATE)

    private fun key(account: JsonObject?): String? {
        fun field(name: String) = (account?.get(name) as? JsonPrimitive)?.contentOrNull
        return field("accountId")?.ifBlank { null }?.let { "${field("host")}|$it" }
    }

    /// An account with no handle that nobody has answered for, anywhere.
    fun isDue(context: Context, account: JsonObject?): Boolean {
        val profile = AccountProfile.from(account) ?: return false
        val key = key(account) ?: return false
        return profile.handle == null && profile.settings?.prompted == false && !prefs(context).getBoolean(key, false)
    }

    fun markAnswered(context: Context, account: JsonObject?) {
        key(account)?.let { prefs(context).edit().putBoolean(it, true).apply() }
    }
}
