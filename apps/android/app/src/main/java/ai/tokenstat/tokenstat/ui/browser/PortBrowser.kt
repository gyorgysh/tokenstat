// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
package ai.tokenstat.tokenstat.ui.browser

import ai.tokenstat.tokenstat.ui.localization.L10n

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
import android.webkit.WebResourceResponse
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
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.input.KeyboardCapitalization
import androidx.compose.ui.unit.dp
import androidx.compose.ui.viewinterop.AndroidView
import androidx.lifecycle.viewModelScope
import ai.tokenstat.tokenstat.AppViewModel
import ai.tokenstat.tokenstat.ui.logic.ProjectOwner
import ai.tokenstat.tokenstat.ui.theme.LocalTsColors
import kotlinx.coroutines.launch
import java.io.ByteArrayInputStream

/// Port-forwarded localhost on this phone, matching Apple
/// `ClientBrowserScreen`.
///
/// Original loopback addresses resolve through the paired computer's tunnel.
/// Listener URLs live only for this screen, and every owned forward is
/// released on exit. Only web pages pass the navigation gate.
@SuppressLint("SetJavaScriptEnabled")
@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun PortBrowserScreen(
    model: AppViewModel,
    request: BrowserOpenRequest,
    onClose: () -> Unit,
) {
    // Its own header and its own way out, so the app chrome steps aside.
    HideTopBar()
    HideTabBar()
    val context = LocalContext.current
    val store = remember(context) { BrowserHistoryStore(context) }
    val active = remember(request) { booleanArrayOf(true) }
    var progress by remember { mutableFloatStateOf(0f) }
    var address by remember(request) { mutableStateOf(request.target.url) }
    var shownHost by remember(request) { mutableStateOf(request.target.host) }
    var loadError by remember { mutableStateOf<String?>(null) }
    var opening by remember { mutableStateOf(false) }
    var view by remember { mutableStateOf<WebView?>(null) }

    fun ownsContext(): Boolean = active[0] && request.owner != null && model.state.value.signedIn &&
        ProjectOwner.from(model.state.value.account, request.peer, request.workspace) == request.owner

    val listeners = remember(request) {
        BrowserListenerSession(request.target, request.lease, ::ownsContext,
            acquire = { target, current -> model.acquireBrowserListener(request.peer, target, request.lease.accountScope, current) })
    }

    fun original(url: String?): BrowserTarget? = listeners.original(url)

    fun navigate(url: String) {
        if (opening || !ownsContext()) return
        val value = url.trim()
        if (!BrowserPolicy.allows(value)) {
            loadError = L10n.text("android.portbrowser.that_address_cannot_open_here.5de454ec")
            return
        }
        loadError = null
        val target = BrowserTarget.parse(value)
        if (target == null) {
            address = value
            view?.loadUrl(value)
            return
        }
        opening = true
        // Listener cleanup must also run if the screen leaves during the call.
        model.viewModelScope.launch {
            runCatching {
                val forwarded = listeners.open(target) ?: return@runCatching
                if (ownsContext()) {
                    store.record(request.owner, target)
                    address = target.url
                    shownHost = target.host
                    view?.loadUrl(forwarded)
                }
            }.onFailure { loadError = it.message }
            opening = false
        }
    }

    fun blockedResponse(): WebResourceResponse = WebResourceResponse(
        "text/plain", "utf-8", 403, L10n.text("android.portbrowser.forbidden.78342a09"), emptyMap(),
        ByteArrayInputStream(L10n.text("android.portbrowser.open_this_preview_s_port_before_loading_th.4a4d565e").toByteArray()),
    )

    fun blockNavigation() { loadError = L10n.text("android.portbrowser.open_this_preview_s_port_before_loading_th.4a4d565e") }
    // A pushed screen owns the system back. Without it the gesture falls
    // through to the activity and closes the app instead of stepping back.
    // History first: followed links and address-bar loads are pages, and
    // back walks them before it leaves the screen.
    BackHandler { if (listeners.isCurrent && view?.canGoBack() == true) view?.goBack() else onClose() }
    DisposableEffect(request) {
        onDispose {
            active[0] = false
            // Cleanup must outlive the composition that owns this screen.
            model.viewModelScope.launch {
                listeners.close()
            }
        }
    }
    Column(Modifier.fillMaxSize()) {
        TopAppBar(
            title = { Text(shownHost) },
            navigationIcon = {
                IconButton(onClick = onClose) { Icon(Icons.AutoMirrored.Filled.ArrowBack, L10n.text("common.back")) }
            },
            actions = {
                TextButton(enabled = !opening, onClick = {
                    val actual = view?.url ?: address
                    navigate(original(actual)?.url ?: actual)
                }) { Text(L10n.text("android.portbrowser.reload.bdc090ec")) }
                TextButton(onClick = onClose) { Text(L10n.text("common.done")) }
            },
        )
        Row(
            Modifier.fillMaxWidth().padding(horizontal = 12.dp),
            verticalAlignment = Alignment.CenterVertically,
        ) {
            OutlinedTextField(
                value = address,
                onValueChange = { address = it },
                label = { Text(L10n.text("android.portbrowser.url.e7a241de")) },
                singleLine = true,
                keyboardOptions = KeyboardOptions(
                    capitalization = KeyboardCapitalization.None,
                    autoCorrectEnabled = false,
                ),
                modifier = Modifier.weight(1f),
            )
            TextButton(enabled = !opening, onClick = { navigate(address) }) { Text(L10n.text("android.portbrowser.go.6cc8519b")) }
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
                    settings.allowFileAccess = false
                    settings.allowContentAccess = false
                    webViewClient = object : WebViewClient() {
                        override fun shouldOverrideUrlLoading(v: WebView?, request: WebResourceRequest?): Boolean {
                            val target = request?.url?.toString()
                            return when (listeners.route(target, request?.isForMainFrame == true, request?.method)) {
                                BrowserListenerSession.Route.Direct -> false
                                BrowserListenerSession.Route.Open -> { navigate(original(target)!!.url); true }
                                BrowserListenerSession.Route.Block -> { blockNavigation(); true }
                            }
                        }

                        @Suppress("DEPRECATION")
                        override fun shouldOverrideUrlLoading(v: WebView?, url: String?): Boolean {
                            // This callback carries neither method nor frame;
                            // an unmapped request cannot be replayed as GET.
                            val direct = listeners.route(url, false, null) == BrowserListenerSession.Route.Direct
                            if (!direct) blockNavigation()
                            return !direct
                        }

                        override fun shouldInterceptRequest(v: WebView?, request: WebResourceRequest?): WebResourceResponse? {
                            val target = request?.url?.toString()
                            // WebView omits POST and resource loads from the
                            // override callback. This hook runs off the UI
                            // thread and refuses direct device loopback too.
                            return when (listeners.route(target, request?.isForMainFrame == true, request?.method)) {
                                BrowserListenerSession.Route.Direct -> null
                                BrowserListenerSession.Route.Open -> {
                                    val canonical = original(target)!!
                                    v?.post { navigate(canonical.url) }
                                    blockedResponse()
                                }
                                BrowserListenerSession.Route.Block -> {
                                    v?.post { blockNavigation() }
                                    blockedResponse()
                                }
                            }
                        }

                        override fun onPageCommitVisible(v: WebView?, url: String?) {
                            if (!listeners.isCurrent) return
                            val canonical = original(url)
                            address = canonical?.url ?: url.orEmpty()
                            shownHost = canonical?.host ?: BrowserPolicy.title(url)
                        }

                        override fun onReceivedError(
                            v: WebView?,
                            request: WebResourceRequest?,
                            error: WebResourceError?,
                        ) {
                            if (Build.VERSION.SDK_INT >= 23 && request?.isForMainFrame == true) {
                                loadError = error?.description?.toString() ?: L10n.text("android.portbrowser.the_page_failed_to_load.b7ee8af7")
                            }
                        }

                        @Suppress("DEPRECATION")
                        override fun onReceivedError(
                            v: WebView?,
                            errorCode: Int,
                            description: String?,
                            failingUrl: String?,
                        ) {
                            loadError = description ?: L10n.text("android.portbrowser.the_page_failed_to_load.b7ee8af7")
                        }

                        override fun onReceivedSslError(v: WebView?, handler: SslErrorHandler?, error: SslError?) {
                            handler?.cancel()
                            loadError = L10n.text("android.portbrowser.the_secure_connection_failed.7b74150f")
                        }
                    }
                    webChromeClient = object : WebChromeClient() {
                        override fun onProgressChanged(view: WebView?, newProgress: Int) {
                            progress = newProgress / 100f
                        }
                    }
                    view = this
                    val forwarded = request.target.through(request.listenerUrl)
                    if (listeners.isCurrent && forwarded != null && BrowserPolicy.allows(forwarded)) loadUrl(forwarded)
                    else loadError = L10n.text("android.portbrowser.that_address_cannot_open_here.5de454ec")
                }
            },
            onRelease = {
                if (view == it) view = null
                it.destroy()
            },
        )
    }
}
