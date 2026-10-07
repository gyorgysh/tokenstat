// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
package ai.tokenstat.tokenstat.ui.logic

import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.contentOrNull
import kotlinx.serialization.json.put

private const val VAULT_ACCOUNT_CHANGED = "the signed-in account changed; retry from the current account"

/** Capture a login receipt once, including for the cancelled watcher's release. */
data class WatchingOwner(val scope: JsonObject, val receipt: String?) {
    fun parameters(conversation: String, watcher: String): JsonObject = buildJsonObject {
        put("conversationId", conversation)
        put("watcherId", watcher)
        put("_accountScope", scope)
        receipt?.let { put("_accountSession", it) }
    }

    companion object {
        fun from(account: JsonObject?): WatchingOwner? {
            ProjectOwner.from(account, "watcher", "watcher") ?: return null
            fun field(name: String) = (account?.get(name) as? JsonPrimitive)?.contentOrNull
            val origin = ProjectOwner.canonicalOrigin(field("host")) ?: return null
            val identity = RecentPlaces.accountIdentity(field("handle"), field("accountId")) ?: return null
            return WatchingOwner(buildJsonObject {
                put("kind", "account"); put("origin", origin); put("identity", identity)
            }, field("accountSession"))
        }
    }
}

/// Name the account that started a vault call. The host drops the call when
/// that login is no longer the one holding the credentials.
fun JsonObject.withVaultScope(account: JsonObject?): JsonObject {
    val scope = WatchingOwner.from(account)?.scope ?: throw IllegalStateException(VAULT_ACCOUNT_CHANGED)
    return buildJsonObject {
        for ((key, value) in this@withVaultScope) put(key, value)
        put("_accountScope", scope)
    }
}
