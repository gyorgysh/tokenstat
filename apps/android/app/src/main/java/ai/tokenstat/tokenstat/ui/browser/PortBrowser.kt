// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
package ai.tokenstat.tokenstat.ui.browser

import androidx.activity.compose.BackHandler
import ai.tokenstat.tokenstat.ui.chrome.HideTabBar

import ai.tokenstat.tokenstat.ui.chrome.HideTopBar

import android.annotation.SuppressLint
import android.net.http.SslError
import android.os.Build
import android.webkit.SslErrorHandler
import android.webkit.WebChromeClient
import android.webkit.WebResourceError
import android.webkit.WebResourceRequest
import android.webkit.WebView
import android.webkit.WebViewClient
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.material.icons.automirrored.filled.ArrowBack
import androidx.compose.material.icons.Icons
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.LinearProgressIndicator
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.material3.TopAppBar
import androidx.compose.runtime.Composable
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableFloatStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.text.input.KeyboardCapitalization
import androidx.compose.ui.unit.dp
import androidx.compose.ui.viewinterop.AndroidView
import ai.tokenstat.tokenstat.AppViewModel
import ai.tokenstat.tokenstat.ui.theme.LocalTsColors
import kotlinx.coroutines.launch
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.put

/// Port-forwarded localhost on this phone, matching Apple
/// `ClientBrowserScreen`.
///
/// The URL is the tunnel proxy's, so host localhost resolves through the
/// tunnel and never touches this device's own localhost. Leaving the screen
/// unlistens the forward, the way closing the Apple cover does. Only web
/// pages load here; anything else is refused rather than stalled on.
@SuppressLint("SetJavaScriptEnabled")
@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun PortBrowserScreen(
    model: AppViewModel,
    peer: String,
    url: String,
    port: Int,
    onClose: () -> Unit,
) {
    // Its own header and its own way out, so the app chrome steps aside.
    HideTopBar()
    HideTabBar()
    val scope = rememberCoroutineScope()
    var progress by remember { mutableFloatStateOf(0f) }
    var address by remember { mutableStateOf(url) }
    var shownHost by remember { mutableStateOf(BrowserPolicy.title(url)) }
    var loadError by remember { mutableStateOf<String?>(null) }
    var view by remember { mutableStateOf<WebView?>(null) }
    // A pushed screen owns the system back. Without it the gesture falls
    // through to the activity and closes the app instead of stepping back.
    // History first: followed links and address-bar loads are pages, and
    // back walks them before it leaves the screen.
    BackHandler { if (view?.canGoBack() == true) view?.goBack() else onClose() }
    DisposableEffect(peer, port) {
        onDispose {
            scope.launch {
                runCatching {
                    model.core(
                        "proxy.unlisten",
                        buildJsonObject {
                            put("peer", peer)
                            put("host", "127.0.0.1")
                            put("port", port)
                        },
                    )
                }
            }
        }
    }
    Column(Modifier.fillMaxSize()) {
        TopAppBar(
            title = { Text(shownHost) },
            navigationIcon = {
                IconButton(onClick = onClose) { Icon(Icons.AutoMirrored.Filled.ArrowBack, "Back") }
            },
            actions = {
                TextButton(onClick = {
                    loadError = null
                    // Reload through the same gate a fresh address goes
                    // through, so a blocked scheme cannot return that way.
                    val current = address
                    if (BrowserPolicy.allows(current)) view?.loadUrl(current)
                    else view?.reload()
                }) { Text("Reload") }
                TextButton(onClick = onClose) { Text("Done") }
            },
        )
        Row(
            Modifier.fillMaxWidth().padding(horizontal = 12.dp),
            verticalAlignment = Alignment.CenterVertically,
        ) {
            OutlinedTextField(
                value = address,
                onValueChange = { address = it },
                label = { Text("URL") },
                singleLine = true,
                keyboardOptions = KeyboardOptions(
                    capitalization = KeyboardCapitalization.None,
                    autoCorrectEnabled = false,
                ),
                modifier = Modifier.weight(1f),
            )
            TextButton(onClick = {
                loadError = null
                val target = address.trim()
                if (BrowserPolicy.allows(target)) {
                    shownHost = BrowserPolicy.title(target)
                    view?.loadUrl(target)
                } else {
                    loadError = "That address cannot open here."
                }
            }) { Text("Go") }
        }
        loadError?.let { error ->
            Text(
                error,
                color = LocalTsColors.current.danger,
                modifier = Modifier.fillMaxWidth().padding(horizontal = 12.dp),
            )
        }
        if (progress in 0f..<1f) {
            LinearProgressIndicator(progress = { progress }, modifier = Modifier.fillMaxWidth())
        }
        AndroidView(
            modifier = Modifier.fillMaxSize(),
            factory = { context ->
                WebView(context).apply {
                    settings.javaScriptEnabled = true
                    webViewClient = object : WebViewClient() {
                        override fun shouldOverrideUrlLoading(v: WebView?, request: WebResourceRequest?): Boolean {
                            val target = request?.url?.toString()
                            return if (BrowserPolicy.allows(target)) false else true
                        }

                        @Suppress("DEPRECATION")
                        override fun shouldOverrideUrlLoading(v: WebView?, url: String?): Boolean {
                            return if (BrowserPolicy.allows(url)) false else true
                        }

                        override fun onPageCommitVisible(v: WebView?, url: String?) {
                            // The title follows committed navigation the way
                            // the Apple bar follows didCommit. The address
                            // field stays what was typed until Go runs.
                            shownHost = BrowserPolicy.title(url)
                        }

                        override fun onReceivedError(
                            v: WebView?,
                            request: WebResourceRequest?,
                            error: WebResourceError?,
                        ) {
                            if (Build.VERSION.SDK_INT >= 23 && request?.isForMainFrame == true) {
                                loadError = error?.description?.toString() ?: "The page failed to load."
                            }
                        }

                        @Suppress("DEPRECATION")
                        override fun onReceivedError(
                            v: WebView?,
                            errorCode: Int,
                            description: String?,
                            failingUrl: String?,
                        ) {
                            loadError = description ?: "The page failed to load."
                        }

                        override fun onReceivedSslError(v: WebView?, handler: SslErrorHandler?, error: SslError?) {
                            handler?.cancel()
                            loadError = "The secure connection failed."
                        }
                    }
                    webChromeClient = object : WebChromeClient() {
                        override fun onProgressChanged(view: WebView?, newProgress: Int) {
                            progress = newProgress / 100f
                        }
                    }
                    view = this
                    loadUrl(url)
                }
            },
            onRelease = {
                if (view == it) view = null
                it.destroy()
            },
        )
    }
}
