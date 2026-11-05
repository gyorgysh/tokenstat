// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
package ai.tokenstat.tokenstat.ui.browser

import android.content.Context
import android.webkit.WebView

internal class BrowserWebView(context: Context) : WebView(context) {
    var onRendererGone: (String?) -> Unit = {}
    @Volatile private var released = false
    val isAvailable: Boolean get() = !released

    fun rendererGone(): Boolean {
        if (!released) {
            val failedUrl = url
            val notify = onRendererGone
            (parent as? android.view.ViewGroup)?.removeView(this)
            shutdown()
            notify(failedUrl)
        }
        return true
    }

    fun shutdown() {
        if (released) return
        released = true
        onRendererGone = {}
        stopLoading()
        destroy()
    }
}
