// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
package ai.tokenstat.tokenstat.ui.workspace

import android.annotation.SuppressLint
import android.content.Context
import android.util.Base64
import android.webkit.WebResourceRequest
import android.webkit.WebResourceResponse
import android.webkit.WebView
import android.webkit.WebViewClient
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.luminance
import androidx.compose.ui.unit.dp
import androidx.compose.ui.viewinterop.AndroidView
import ai.tokenstat.tokenstat.ui.theme.LocalTsColors
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import java.io.File

internal fun canPreviewModel(name: String): Boolean =
    name.substringAfterLast('.', "").lowercase() in setOf("glb", "gltf", "fbx", "obj", "stl", "ply")

@Composable
internal fun ChatModelView(name: String, file: File) {
    val dark = LocalTsColors.current.background.luminance() < 0.5f
    var encoded by remember(file.path, file.lastModified()) { mutableStateOf<String?>(null) }
    LaunchedEffect(file.path, file.lastModified()) {
        encoded = withContext(Dispatchers.IO) {
            if (file.length() !in 1..12L * 1024 * 1024) null
            else Base64.encodeToString(file.readBytes(), Base64.NO_WRAP)
        }
    }
    val data = encoded ?: return
    AndroidView(
        factory = { ModelWebSurface(it) },
        modifier = Modifier.fillMaxWidth().height(260.dp),
        onReset = null,
        onRelease = { it.shutdown() },
        update = { it.render(data, name.substringAfterLast('.', "").lowercase(), if (dark) "#08070d" else "#fbfbfd") },
    )
}

@SuppressLint("SetJavaScriptEnabled")
private class ModelWebSurface(context: Context) : WebView(context) {
    private var loaded = false
    private var stopped = false
    private var script = ""
    private var rendered = ""

    init {
        setBackgroundColor(android.graphics.Color.TRANSPARENT)
        settings.javaScriptEnabled = true
        settings.domStorageEnabled = false
        settings.allowFileAccess = false
        settings.allowContentAccess = false
        settings.blockNetworkLoads = true
        settings.javaScriptCanOpenWindowsAutomatically = false
        settings.mixedContentMode = android.webkit.WebSettings.MIXED_CONTENT_NEVER_ALLOW
        settings.cacheMode = android.webkit.WebSettings.LOAD_NO_CACHE
        webViewClient = object : WebViewClient() {
            override fun shouldOverrideUrlLoading(view: WebView, request: WebResourceRequest) = request.url.toString() != PAGE
            override fun shouldInterceptRequest(view: WebView, request: WebResourceRequest): WebResourceResponse {
                val name = request.url.toString().removePrefix(BASE)
                if (!request.url.toString().startsWith(BASE) || name !in setOf("model.html", "model-engine.js")) return denied()
                return try {
                    WebResourceResponse(if (name.endsWith(".js")) "application/javascript" else "text/html", "UTF-8", context.assets.open("charts/$name"))
                } catch (_: Exception) { denied() }
            }
            override fun onPageFinished(view: WebView, url: String) {
                if (!stopped && url == PAGE) { loaded = true; applyScript() }
            }
        }
        loadUrl(PAGE)
    }

    fun render(data: String, extension: String, background: String) {
        if (stopped) return
        script = "TokenstatModel.load('$data','$extension','$background')"
        applyScript()
    }

    private fun applyScript() {
        if (loaded && !stopped && script.isNotEmpty() && script != rendered) {
            rendered = script
            evaluateJavascript(script, null)
        }
    }

    fun shutdown() {
        stopped = true
        stopLoading()
        destroy()
    }

    private fun denied() = WebResourceResponse("text/plain", "UTF-8", 403, "Forbidden", emptyMap(), java.io.ByteArrayInputStream(ByteArray(0)))

    companion object {
        private const val BASE = "https://models.tokenstat.invalid/"
        private const val PAGE = BASE + "model.html"
    }
}
