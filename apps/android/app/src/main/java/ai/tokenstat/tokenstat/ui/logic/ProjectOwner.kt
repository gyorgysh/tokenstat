// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
package ai.tokenstat.tokenstat.ui.logic

import java.net.URI
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.booleanOrNull
import kotlinx.serialization.json.contentOrNull

/// Device state belongs to an account on one server, a host, and a project.
/// Labels and tunnel listener addresses never contribute to this identity.
@ConsistentCopyVisibility
data class ProjectOwner private constructor(val key: String, val accountScope: String) {
    fun conversation(chatId: String): String? = item("conversation", chatId)

    fun terminal(sessionId: String): String? = item("terminal", sessionId)

    private fun item(kind: String, id: String): String? =
        if (valid(id)) "$key|$kind|${segment(id)}" else null

    companion object {
        fun from(account: JsonObject?, peer: String, workspace: String): ProjectOwner? {
            val signedInAccount = account ?: return null
            if ((signedInAccount["signedIn"] as? JsonPrimitive)?.booleanOrNull != true) return null
            fun field(name: String): String? = (signedInAccount[name] as? JsonPrimitive)
                ?.takeIf { it.isString }?.contentOrNull
            val origin = canonicalOrigin(field("host")) ?: return null
            val identity = RecentPlaces.accountIdentity(field("handle"), field("accountId")) ?: return null
            val host = peer.trim().lowercase()
            if (!listOf(origin, identity, host, workspace).all(::valid)) return null
            return ProjectOwner(
                "project.v1|" + listOf(origin, identity, host, workspace).joinToString("|", transform = ::segment),
                "account.v1|" + listOf(origin, identity).joinToString("|", transform = ::segment),
            )
        }

        private fun valid(value: String): Boolean =
            value.isNotBlank() && value.length <= 4096 && value.none { it.isISOControl() }

        private fun segment(value: String): String = "${value.length}:$value"

        /// Matches WorkReference.Scope.account: retain an account service's
        /// path prefix, remove query/fragment, trailing slash and default port.
        private fun canonicalOrigin(value: String?): String? {
            val parsed = runCatching { URI(value?.trim().orEmpty()) }.getOrNull() ?: return null
            val scheme = parsed.scheme?.lowercase() ?: return null
            val host = parsed.host?.lowercase()?.takeIf { it.isNotEmpty() } ?: return null
            if (scheme != "https" && scheme != "http" || parsed.rawUserInfo != null) return null
            val port = parsed.port
            if (port != -1 && port !in 1..65535) return null
            val explicitPort = if (port == -1 || scheme == "https" && port == 443 || scheme == "http" && port == 80) "" else ":$port"
            return "$scheme://$host$explicitPort${parsed.rawPath.orEmpty().trimEnd('/')}"
        }
    }
}
