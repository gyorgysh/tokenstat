// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
package ai.tokenstat.tokenstat.ui.workspace

import android.annotation.SuppressLint
import android.content.Context
import android.os.Handler
import android.os.Looper
import android.util.Base64
import android.webkit.JavascriptInterface
import android.webkit.WebResourceRequest
import android.webkit.WebResourceResponse
import android.webkit.WebView
import android.webkit.WebViewClient
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.padding
import androidx.compose.ui.Alignment
import androidx.compose.material3.Text
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
import ai.tokenstat.tokenstat.ui.localization.L10n
import ai.tokenstat.tokenstat.ui.theme.LocalTsColors
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.delay
import kotlinx.coroutines.withContext
import java.io.File

internal fun canPreviewModel(name: String): Boolean =
    name.substringAfterLast('.', "").lowercase() in setOf("glb", "gltf", "fbx", "obj", "stl", "ply")

private sealed interface ModelPayload {
    data object Loading : ModelPayload
    data object Unavailable : ModelPayload
    data class Ready(val base64: String) : ModelPayload
}

@Composable
internal fun ChatModelView(name: String, file: File) {
    val colors = LocalTsColors.current
    val dark = colors.background.luminance() < 0.5f
    var payload by remember(file.path, file.lastModified()) { mutableStateOf<ModelPayload>(ModelPayload.Loading) }
    var failure by remember(file.path, file.lastModified()) { mutableStateOf<String?>(null) }
    var ready by remember(file.path, file.lastModified()) { mutableStateOf(false) }
    LaunchedEffect(file.path, file.lastModified()) {
        delay(10_000)
        if (!ready && failure == null) failure = L10n.text("android.chatmodel.preview_timed_out")
    }
    LaunchedEffect(file.path, file.lastModified()) {
        payload = withContext(Dispatchers.IO) {
            runCatching {
                if (file.length() !in 1..12L * 1024 * 1024) ModelPayload.Unavailable
                else ModelPayload.Ready(Base64.encodeToString(file.readBytes(), Base64.NO_WRAP))
            }.getOrDefault(ModelPayload.Unavailable)
        }
    }
    when (val result = payload) {
        ModelPayload.Loading -> return
        ModelPayload.Unavailable -> {
            Text(L10n.text("android.chatmodel.preview_unavailable"), color = colors.textSecondary)
            return
        }
        is ModelPayload.Ready -> {
            Box(Modifier.fillMaxWidth().height(320.dp), contentAlignment = Alignment.Center) {
                AndroidView(
                    factory = { ModelWebSurface(it) },
                    modifier = Modifier.fillMaxWidth().height(320.dp),
                    onReset = null,
                    onRelease = { it.shutdown() },
                    update = {
                        it.onResult = { message ->
                            if (message == null) ready = true else failure = message
                        }
                        it.render(result.base64, name.substringAfterLast('.', "").lowercase(), if (dark) "#08070d" else "#fbfbfd")
                    },
                )
                if (!ready) Text(failure ?: L10n.text("android.chatmodel.loading"), modifier = Modifier.padding(20.dp), color = colors.textSecondary)
            }
        }
    }
}

@SuppressLint("SetJavaScriptEnabled")
private class ModelWebSurface(context: Context) : WebView(context) {
    var onResult: (String?) -> Unit = {}
    private val main = Handler(Looper.getMainLooper())
    private var loaded = false
    private var pageRequested = false
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
        addJavascriptInterface(object {
            @JavascriptInterface fun report(message: String) {
                main.post { if (!stopped) onResult(message.ifEmpty { null }) }
            }
        }, "TokenstatModelHost")
        webViewClient = object : WebViewClient() {
            override fun onReceivedError(view: WebView, request: WebResourceRequest, error: android.webkit.WebResourceError) {
                if (request.isForMainFrame) main.post { if (!stopped) onResult(L10n.text("android.chatmodel.preview_unavailable")) }
            }
            override fun shouldOverrideUrlLoading(view: WebView, request: WebResourceRequest) = request.url.toString() != PAGE
            override fun shouldInterceptRequest(view: WebView, request: WebResourceRequest): WebResourceResponse {
                val name = request.url.toString().removePrefix(BASE)
                if (!request.url.toString().startsWith(BASE) || name !in setOf("model.html", "model-engine.js")) return denied()
                return try {
                    WebResourceResponse(if (name.endsWith(".js")) "application/javascript" else "text/html", "UTF-8", context.assets.open("charts/$name"))
                } catch (_: Exception) { denied() }
            }
            override fun onPageFinished(view: WebView, url: String) {
                if (!stopped && url == PAGE) {
                    loaded = true
                    evaluateJavascript("typeof TokenstatModel", { result ->
                        if (!stopped) {
                            if (result == "\"object\"") applyScript()
                            else onResult(L10n.text("android.chatmodel.preview_unavailable"))
                        }
                    })
                }
            }
        }
    }

    override fun onSizeChanged(w: Int, h: Int, oldw: Int, oldh: Int) {
        super.onSizeChanged(w, h, oldw, oldh)
        if (!pageRequested && w > 0 && h > 0) {
            pageRequested = true
            loadUrl(PAGE)
        } else if (loaded && !stopped && h > 0) {
            evaluateJavascript(VIEWPORT_SCRIPT, null)
        }
    }

    fun render(data: String, extension: String, background: String) {
        if (stopped) return
        script = "$VIEWPORT_SCRIPT TokenstatModel.load('$data','$extension','$background').then(ok => TokenstatModelHost.report(ok ? '' : (document.getElementById('status').textContent || '3D preview failed'))).catch(error => TokenstatModelHost.report(String(error)))"
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
        onResult = {}
        stopLoading()
        destroy()
    }

    private fun denied() = WebResourceResponse("text/plain", "UTF-8", 403, "Forbidden", emptyMap(), java.io.ByteArrayInputStream(ByteArray(0)))

    companion object {
        private const val BASE = "https://models.tokenstat.invalid/"
        private const val PAGE = BASE + "model.html"
        // Android WebView can report innerHeight while CSS 100vh is still zero
        // during its first layout. Set the canvas height in CSS pixels before loading.
        private const val VIEWPORT_SCRIPT = "var modelHeight=Math.max(1,innerHeight); document.documentElement.style.height=modelHeight+'px'; document.body.style.height=modelHeight+'px'; document.getElementById('model').style.height=modelHeight+'px';"
    }
}
