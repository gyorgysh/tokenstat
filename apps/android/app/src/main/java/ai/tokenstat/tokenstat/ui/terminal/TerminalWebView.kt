// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
package ai.tokenstat.tokenstat.ui.terminal

import android.content.Context
import android.webkit.WebView

internal class TerminalWebView(context: Context, private val bridge: TerminalBridge) : WebView(context) {
    var onRendererGone: () -> Unit = {}
    private var released = false

    fun rendererGone(): Boolean {
        if (!released) {
            val notify = onRendererGone
            (parent as? android.view.ViewGroup)?.removeView(this)
            shutdown()
            notify()
        }
        return true
    }

    fun shutdown() {
        if (released) return
        released = true
        if (bridge.webView == null || bridge.webView === this) {
            bridge.stopJobs()
            bridge.webView = null
            bridge.alive = false
        }
        onRendererGone = {}
        removeJavascriptInterface("TermBridge")
        stopLoading()
        destroy()
    }
}
