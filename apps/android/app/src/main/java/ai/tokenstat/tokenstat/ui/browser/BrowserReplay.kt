// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
package ai.tokenstat.tokenstat.ui.browser

import android.webkit.WebResourceResponse
import java.io.ByteArrayInputStream
import kotlinx.coroutines.runBlocking
import kotlinx.serialization.json.JsonPrimitive

/** Called on WebView's resource thread, after classifying a main-frame GET. */
internal fun BrowserListenerSession.replayResponse(target: BrowserTarget): WebResourceResponse? {
    val forwarded = runBlocking { open(target) } ?: return null
    // Back has already selected its old entry when this document runs.
    // replace() refreshes that entry's temporary proxy without adding one.
    val destination = JsonPrimitive(forwarded).toString().replace("<", "\\u003c")
    val html = "<!doctype html><meta charset=\"utf-8\"><script>location.replace($destination);</script>"
    return WebResourceResponse("text/html", "utf-8", 200, "OK", mapOf("Cache-Control" to "no-store"),
        ByteArrayInputStream(html.toByteArray(Charsets.UTF_8)))
}
