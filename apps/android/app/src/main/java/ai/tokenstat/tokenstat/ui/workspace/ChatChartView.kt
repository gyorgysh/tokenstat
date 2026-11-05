// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
package ai.tokenstat.tokenstat.ui.workspace

import android.annotation.SuppressLint
import android.app.Activity
import android.content.ClipData
import android.content.ClipboardManager
import android.content.Context
import android.content.Intent
import android.os.Handler
import android.os.Looper
import android.provider.Settings
import android.util.Base64
import android.webkit.JavascriptInterface
import android.webkit.WebResourceRequest
import android.webkit.WebResourceResponse
import android.webkit.WebView
import android.webkit.WebViewClient
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.luminance
import androidx.compose.ui.layout.boundsInWindow
import androidx.compose.ui.layout.onGloballyPositioned
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.unit.dp
import androidx.compose.ui.viewinterop.AndroidView
import androidx.lifecycle.Lifecycle
import androidx.lifecycle.compose.LocalLifecycleOwner
import androidx.lifecycle.compose.currentStateAsState
import ai.tokenstat.tokenstat.ui.localization.L10n
import ai.tokenstat.tokenstat.ui.theme.LocalTsColors
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import org.json.JSONObject
import java.io.ByteArrayInputStream
import java.util.Locale

internal data class ChartExport(val format: String, val mime: String, val data: ByteArray)
private const val MAX_CHART_SOURCE_BYTES = 256 * 1024

/** The chart owns a bundled page. It never joins a browsing session or makes a network request. */
@Composable
internal fun ChatChartView(source: String, pending: Boolean = false) {
    val context = LocalContext.current
    val scope = rememberCoroutineScope()
    val colors = LocalTsColors.current
    val dark = colors.background.luminance() < 0.5f
    val lifecycle by LocalLifecycleOwner.current.lifecycle.currentStateAsState()
    var height by remember(source) { mutableStateOf(430f) }
    var visible by remember { mutableStateOf(false) }
    var failure by remember(source) { mutableStateOf<String?>(null) }
    var exported by remember { mutableStateOf<ChartExport?>(null) }
    val tooLarge = remember(source, pending) {
        !pending && (source.length > MAX_CHART_SOURCE_BYTES || source.toByteArray(Charsets.UTF_8).size > MAX_CHART_SOURCE_BYTES)
    }
    val save = rememberLauncherForActivityResult(ActivityResultContracts.StartActivityForResult()) { result ->
        val file = exported
        exported = null
        val uri = result.data?.data
        if (result.resultCode == Activity.RESULT_OK && uri != null && file != null) {
            scope.launch {
                try {
                    withContext(Dispatchers.IO) {
                        val output = context.contentResolver.openOutputStream(uri, "wt") ?: error(L10n.text("common.chart.unavailable"))
                        output.use { it.write(file.data) }
                    }
                } catch (error: Exception) { failure = error.localizedMessage }
            }
        }
    }
    if (pending) {
        Text(L10n.text("common.chart.loading"), modifier = Modifier.padding(16.dp), color = colors.textSecondary)
    } else if (tooLarge) {
        Text(L10n.text("common.chart.too_large"), modifier = Modifier.padding(16.dp), color = colors.textSecondary)
    } else if (failure != null) {
        Text(L10n.text("common.chart.unavailable") + failure?.takeIf { it.isNotBlank() }?.let { ": $it" }.orEmpty(), modifier = Modifier.padding(16.dp), color = colors.textSecondary)
    } else {
        // Keep every chart's place in the reply while only visible charts own
        // a browser. Clipped bounds include the transcript's scroll viewport.
        Box(Modifier.fillMaxWidth().height(height.dp).onGloballyPositioned { coordinates ->
            val bounds = coordinates.boundsInWindow()
            visible = bounds.width > 0 && bounds.height > 0
        }) {
            if (visible && lifecycle.isAtLeast(Lifecycle.State.STARTED)) AndroidView(
                factory = { ChartWebSurface(it) },
                modifier = Modifier.fillMaxSize(),
                onReset = null,
                onRelease = { it.shutdown() },
                update = { view ->
                    view.onHeight = { height = it }
                    view.onError = { failure = it }
                    view.onExport = { file ->
                        if (exported == null) {
                            exported = file
                            try {
                                save.launch(Intent(Intent.ACTION_CREATE_DOCUMENT).apply {
                                    addCategory(Intent.CATEGORY_OPENABLE)
                                    type = file.mime
                                    putExtra(Intent.EXTRA_TITLE, "chart." + file.format)
                                })
                            } catch (error: Exception) { exported = null; failure = error.localizedMessage }
                        }
                    }
                    view.render(source, dark)
                },
            )
        }
    }
}

@SuppressLint("SetJavaScriptEnabled")
internal class ChartWebSurface(context: Context) : WebView(context) {
    var onHeight: (Float) -> Unit = {}
    var onError: (String) -> Unit = {}
    var onExport: (ChartExport) -> Unit = {}
    private val main = Handler(Looper.getMainLooper())
    private var stopped = false
    private var loaded = false
    private data class Render(val source: String, val encoded: String, val dark: Boolean,
        val locale: String, val reducedMotion: Boolean, val settings: String)
    private var pending: Render? = null
    private var revision = 0L
    private var renderedRevision = -1L
    private var wordsLocale: String? = null
    private var words: JSONObject? = null

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
        isVerticalScrollBarEnabled = false
        addJavascriptInterface(Bridge(), "TokenstatChartHost")
        webViewClient = object : WebViewClient() {
            override fun onRenderProcessGone(view: WebView, detail: android.webkit.RenderProcessGoneDetail): Boolean {
                if (!stopped) {
                    val notify = onError
                    (parent as? android.view.ViewGroup)?.removeView(this@ChartWebSurface)
                    shutdown()
                    notify("")
                }
                return true
            }
            override fun shouldOverrideUrlLoading(view: WebView, request: WebResourceRequest) = request.url.toString() != PAGE
            override fun shouldInterceptRequest(view: WebView, request: WebResourceRequest): WebResourceResponse {
                val name = request.url.toString().removePrefix(BASE)
                if (!request.url.toString().startsWith(BASE) || name !in ASSETS) return denied()
                return try {
                    val mime = when { name.endsWith(".js") -> "application/javascript"; name.endsWith(".css") -> "text/css"; name.endsWith(".ttf") -> "font/ttf"; else -> "text/html" }
                    WebResourceResponse(mime, "UTF-8", context.assets.open("charts/$name"))
                } catch (_: Exception) {
                    main.post { if (!stopped) onError(L10n.text("common.chart.resources_missing")) }
                    denied()
                }
            }
            override fun onPageFinished(view: WebView, url: String) {
                if (!stopped && url == PAGE) { loaded = true; applyScript() }
            }
        }
        loadUrl(PAGE)
    }

    fun render(source: String, dark: Boolean) {
        if (stopped) return
        val locale = Locale.getDefault().toLanguageTag()
        val reducedMotion = Settings.Global.getFloat(context.contentResolver, Settings.Global.ANIMATOR_DURATION_SCALE, 1f) == 0f
        val previous = pending
        val sameSettings = previous != null && previous.dark == dark && previous.locale == locale && previous.reducedMotion == reducedMotion
        if (previous != null && previous.source == source && sameSettings) return
        val encoded = if (previous != null && previous.source == source) previous.encoded else {
            if (source.length > MAX_CHART_SOURCE_BYTES) return
            val bytes = source.toByteArray(Charsets.UTF_8)
            if (bytes.size > MAX_CHART_SOURCE_BYTES) return
            Base64.encodeToString(bytes, Base64.NO_WRAP)
        }
        val settings = if (previous != null && sameSettings) previous.settings else {
            // The bundled labels depend only on L10n's current locale.
            if (wordsLocale != locale) { words = JSONObject(ChartWords.all()); wordsLocale = locale }
            JSONObject().put("dark", dark).put("locale", locale).put("reducedMotion", reducedMotion)
                .put("strings", words).toString()
        }
        pending = Render(source, encoded, dark, locale, reducedMotion, settings)
        revision++
        applyScript()
    }

    private fun applyScript() {
        val request = pending ?: return
        if (!loaded || stopped || renderedRevision == revision) return
        renderedRevision = revision
        val script = "window.TokenstatChart.render(new TextDecoder().decode(Uint8Array.from(atob('${request.encoded}'), c => c.charCodeAt(0))), Object.assign(${request.settings},{paintToken:$revision}));"
        evaluateJavascript(script, null)
    }

    fun shutdown() {
        if (stopped) return
        stopped = true
        onHeight = {}; onError = {}; onExport = {}
        pending = null; words = null; wordsLocale = null
        main.removeCallbacksAndMessages(null)
        stopLoading()
        removeJavascriptInterface("TokenstatChartHost")
        destroy()
    }

    private inner class Bridge {
        @JavascriptInterface fun postMessage(raw: String) {
            if (raw.length > 12 * 1024 * 1024) return
            main.post {
                if (stopped || url != PAGE) return@post
                try {
                    val message = JSONObject(raw)
                    when (message.optString("type")) {
                        "height" -> {
                            if (message.optLong("paintToken", -1L) != revision) return@post
                            val height = message.optDouble("height")
                            if (height.isFinite() && height in 180.0..2200.0) onHeight(height.toFloat())
                        }
                        "copy" -> {
                            val text = message.optString("text")
                            if (text.toByteArray(Charsets.UTF_8).size <= 64 * 1024) {
                                (context.getSystemService(Context.CLIPBOARD_SERVICE) as ClipboardManager).setPrimaryClip(ClipData.newPlainText("Chart", text))
                            }
                        }
                        "export" -> {
                            val format = message.optString("format")
                            val mime = mapOf("png" to "image/png", "svg" to "image/svg+xml", "csv" to "text/csv", "json" to "application/json")[format] ?: return@post
                            val content = message.optString("content")
                            if (content.length > 12 * 1024 * 1024) return@post
                            if (message.optBoolean("base64") != (format == "png")) return@post
                            val data = if (message.optBoolean("base64")) Base64.decode(content, Base64.DEFAULT) else content.toByteArray(Charsets.UTF_8)
                            if (data.size <= 8 * 1024 * 1024) onExport(ChartExport(format, mime, data))
                        }
                    }
                } catch (_: Exception) { /* A malformed bridge message has no effect. */ }
            }
        }
    }

    companion object {
        private const val BASE = "https://charts.tokenstat.invalid/"
        private const val PAGE = "${BASE}index.html"
        private val ASSETS = setOf("index.html", "engine.js", "contract.js", "chart.js", "chart.css", "Manrope.ttf")
        private fun denied() = WebResourceResponse("text/plain", "UTF-8", 403, "Blocked", emptyMap(), ByteArrayInputStream(ByteArray(0)))
    }
}
