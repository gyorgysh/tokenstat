// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
package ai.tokenstat.tokenstat.ui.logic

import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.contentOrNull
import kotlinx.serialization.json.put

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
