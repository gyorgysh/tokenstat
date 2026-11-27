// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
package ai.tokenstat.tokenstat.ui.browser

import android.webkit.WebResourceResponse
import java.io.ByteArrayInputStream
import kotlinx.coroutines.runBlocking
import kotlinx.serialization.json.JsonPrimitive

internal fun BrowserListenerSession.replayResponse(target: BrowserTarget, currentRequest: () -> Boolean = { true }): WebResourceResponse? {
    val forwarded = runBlocking { open(target, currentRequest) } ?: return null
    val destination = JsonPrimitive(forwarded).toString().replace("<", "\\u003c")
    val html = "<!doctype html><meta charset=\"utf-8\"><script>location.replace($destination);</script>"
    return WebResourceResponse("text/html", "utf-8", 200, "OK", mapOf("Cache-Control" to "no-store"),
        ByteArrayInputStream(html.toByteArray(Charsets.UTF_8)))
}
