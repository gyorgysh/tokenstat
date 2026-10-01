// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
package ai.tokenstat.tokenstat.ui.browser

import ai.tokenstat.tokenstat.ui.localization.L10n

import ai.tokenstat.tokenstat.AppViewModel
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.contentOrNull
import kotlinx.serialization.json.put

internal suspend fun AppViewModel.acquireBrowserListener(
    peer: String,
    target: BrowserTarget,
    accountScope: String,
    current: () -> Boolean,
): BrowserListenerPool.Lease? = BrowserListenerPool.Shared.acquire(
    BrowserListenerPool.Endpoint(peer, target.host, target.port), accountScope, current,
    listen = {
        val answer = core("proxy.listen", buildJsonObject {
            put("peer", peer); put("host", target.host); put("port", target.port)
        }) as? JsonObject
        (answer?.get("url") as? JsonPrimitive)?.contentOrNull
            ?: throw IllegalStateException(L10n.text("android.browserlistenercalls.the_browser_listener_did_not_return_an_add.dc0150b1"))
    },
    retire = {
        core("proxy.unlisten", buildJsonObject {
            put("peer", peer); put("host", target.host); put("port", target.port)
        })
        Unit
    },
)
