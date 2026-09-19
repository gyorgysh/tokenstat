// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
package ai.tokenstat.tokenstat.ui.terminal

import androidx.activity.compose.BackHandler
import ai.tokenstat.tokenstat.ui.chrome.HideTabBar

import ai.tokenstat.tokenstat.ui.chrome.HideTopBar

import android.annotation.SuppressLint
import android.content.ClipData
import android.content.ClipboardManager
import android.content.Context
import android.webkit.JavascriptInterface
import android.webkit.WebView
import android.webkit.WebViewClient
import androidx.compose.foundation.isSystemInDarkTheme
import androidx.compose.foundation.horizontalScroll
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.imePadding
import androidx.compose.foundation.layout.navigationBarsPadding
import androidx.compose.foundation.layout.WindowInsets
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.ime
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.ui.Alignment
import androidx.compose.ui.draw.clip
import androidx.compose.ui.text.TextStyle
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import android.util.Base64
import ai.tokenstat.tokenstat.ui.theme.LocalTsColors
import ai.tokenstat.tokenstat.ui.theme.Space
import ai.tokenstat.tokenstat.ui.theme.TsColors
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.ArrowBack
import androidx.compose.material.icons.filled.Keyboard
import androidx.compose.material.icons.filled.KeyboardHide
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.foundation.layout.size
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.material3.TopAppBar
import androidx.compose.runtime.Composable
import androidx.lifecycle.Lifecycle
import androidx.lifecycle.compose.LocalLifecycleOwner
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.currentCoroutineContext
import kotlinx.coroutines.ensureActive
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.key
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.platform.LocalContext
import kotlinx.coroutines.delay
import androidx.compose.ui.Modifier
import androidx.compose.ui.viewinterop.AndroidView
import androidx.lifecycle.viewModelScope
import ai.tokenstat.tokenstat.AppViewModel
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.channels.Channel
import kotlinx.coroutines.launch
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.put

/// A full-screen live remote terminal, the phone counterpart of
/// `ClientTerminalSession.swift`. The emulator is xterm.js running in a local
/// WebView (bundled under assets/term — no network needed); bytes travel the
/// same pty.* tunnel methods the Apple client uses.
///
/// The read loop keeps a long-poll (`waitMs`) outstanding so keystrokes and
/// output feel live without a socket.
@SuppressLint("SetJavaScriptEnabled")
@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun TerminalScreen(
    model: AppViewModel,
    peer: String,
    hostLabel: String,
    workspaceId: String,
    existingSessionId: String?,
    onClose: () -> Unit,
    onSessionOpened: (String) -> Unit = {},
) {
    // Its own header and its own way out, so the app chrome steps aside.
    HideTopBar()
    HideTabBar()
    // Back is Done: it stops showing the session without stopping the
    // process. Ending it is the Close button, which asks first.
    BackHandler { onClose() }
    val scope = rememberCoroutineScope()
    val context = LocalContext.current
    val dark = isSystemInDarkTheme()
    val bridge = remember {
        TerminalBridge().also {
            it.onCopy = { text -> copyToClipboard(context, text) }
        }
    }
    bridge.lifecycle = LocalLifecycleOwner.current.lifecycle
    var sessionId by remember { mutableStateOf(existingSessionId) }
    var confirmClose by remember { mutableStateOf(false) }
    // The bar's Ctrl key reads the bridge, which is what spends the flag.
    var controlArmed by remember { mutableStateOf(false) }
    bridge.onControlChanged = { controlArmed = it }
    var keyboardUp by remember { mutableStateOf(false) }
    bridge.onKeyboardChanged = { keyboardUp = it }
    ReconcileKeyboard(keyboardUp) { keyboardUp = false; bridge.noteKeyboardHidden() }
    // A redraw tick for bridge-owned read state (transport error, dropped
    // output, exit). The loop sets the fields and nudges this.
    var tick by remember { mutableIntStateOf(0) }
    bridge.onProgress = { tick++ }

    // Follow the system appearance the way the Apple client repaints its
    // terminal view, using the same TerminalPalette shades on both sides.
    LaunchedEffect(dark) { bridge.pushTheme(dark) }

    fun fail(message: String) {
        bridge.fatalError = message
        bridge.alive = false
        bridge.onProgress()
    }

    /// A fresh shell after a dead session or a failed spawn. The page
    /// reload re-runs the bind flow from the top.
    fun retryFreshShell() {
        sessionId = null
        bridge.fatalError = null
        bridge.transportError = null
        bridge.exitCode = null
        bridge.alive = true
        bridge.sessionBound = false
        bridge.onProgress()
        bridge.webView?.reload()
    }

    fun bind(id: String) {
        sessionId = id
        onSessionOpened(id)
        scope.launch {
            // The header names the process and folder, like the Apple screen.
            // A failed info call is a transport hiccup: the read loop owns
            // that case with its backoff. But an answer that names a dead
            // session ends here with a way out, instead of the blank
            // terminal a dead attach used to draw.
            runCatching {
                model.workspaceSection(peer, "pty.info", ptyViewerParams(id))
            }.onSuccess { element ->
                bridge.readInfo(element as? JsonObject)
                if (bridge.exitCode != null || !bridge.alive) {
                    fail("This session has ended.")
                    return@launch
                }
            }
            bridge.startReadLoop(model, peer, id, scope)
            bridge.pumpInput(model, peer, id, scope)
        }
    }

    // The keyboard takes room from the terminal rather than covering it.
    //
    // Nothing consumed the IME inset, so the soft keyboard sat on top of the
    // bottom rows and the key bar, and the page was never told its size had
    // changed. The emulator shrinks, the page re-fits, and the rows come back
    // when the keyboard goes away.
    Column(Modifier.fillMaxSize().navigationBarsPadding().imePadding()) {
        TopAppBar(
            title = {
                key(tick) {
                    Column {
                        Text(bridgeTitle(bridge))
                        Text(
                            bridgeSubtitle(bridge),
                            style = androidx.compose.material3.MaterialTheme.typography.bodySmall,
                            color = LocalTsColors.current.textSecondary,
                        )
                    }
                }
            },
            navigationIcon = {
                IconButton(onClick = onClose) { Icon(Icons.AutoMirrored.Filled.ArrowBack, "Back") }
            },
            actions = {
                TextButton(onClick = { confirmClose = true }) { Text("Close") }
                TextButton(onClick = onClose) { Text("Done") }
            },
        )
        // Bridge fields are plain volatiles; keying on the tick it nudges is
        // what redraws these when the read loop reports.
        key(tick) {
            if (bridge.outputPaused) {
                Text(
                    "Output paused while the terminal catches up.",
                    color = LocalTsColors.current.warning,
                    modifier = Modifier.fillMaxWidth().padding(horizontal = Space.s),
                )
            }
            if (bridge.droppedOutput) {
                Text(
                    "Some output was dropped.",
                    color = LocalTsColors.current.warning,
                    modifier = Modifier.fillMaxWidth().padding(horizontal = Space.s),
                )
            }
            bridge.transportError?.let { error ->
                Text(
                    error,
                    color = LocalTsColors.current.danger,
                    modifier = Modifier.fillMaxWidth().padding(horizontal = Space.s),
                )
            }
            bridge.fatalError?.let { error ->
                Row(
                    Modifier.fillMaxWidth().padding(horizontal = Space.s, vertical = Space.xs),
                    verticalAlignment = Alignment.CenterVertically,
                    horizontalArrangement = Arrangement.spacedBy(Space.s),
                ) {
                    Text(
                        error,
                        color = LocalTsColors.current.danger,
                        modifier = Modifier.weight(1f),
                    )
                    TextButton(onClick = { retryFreshShell() }) { Text("New shell") }
                }
            }
        }
        AndroidView(
            modifier = Modifier.weight(1f).fillMaxSize(),
            factory = { ctx ->
                WebView(ctx).apply {
                    // Match the space Compose gives this view, explicitly.
                    // `AndroidView` leaves a child on wrap-content, and a
                    // WebView measured that way lays its page out against a
                    // containing block of zero height: `html { height: 100% }`
                    // computes to 0px, so the terminal can never fit itself to
                    // the screen and never follows the keyboard.
                    layoutParams = android.view.ViewGroup.LayoutParams(
                        android.view.ViewGroup.LayoutParams.MATCH_PARENT,
                        android.view.ViewGroup.LayoutParams.MATCH_PARENT,
                    )
                    settings.javaScriptEnabled = true
                    settings.allowFileAccess = false
                    settings.allowContentAccess = false
                    settings.blockNetworkLoads = true
                    settings.domStorageEnabled = false
                    // The page is sized to this view and cannot overflow it,
                    // so there is nothing to scroll to and no bar to show.
                    // A scrollable page pans to follow the focused textarea
                    // at the cursor, which is what jumped the picture.
                    isVerticalScrollBarEnabled = false
                    isHorizontalScrollBarEnabled = false
                    overScrollMode = android.view.View.OVER_SCROLL_NEVER
                    // Both, explicitly. A WebView inside Compose is not given
                    // focus by the focus system, and without focus the page's
                    // textarea cannot be what the keyboard types into.
                    isFocusable = true
                    isFocusableInTouchMode = true
                    // The size the page fits to arrives with layout, not with
                    // the page load, so every layout asks it to measure again.
                    // The measured view size travels with the ask: with the
                    // keyboard open the window pans instead of resizing, so
                    // the page's own viewport stays tall behind a short view.
                    addOnLayoutChangeListener { view, l, t, r, b, ol, ot, or_, ob ->
                        if (r - l == or_ - ol && b - t == ob - ot) return@addOnLayoutChangeListener
                        val density = view.resources.displayMetrics.density
                        bridge.fitSize(
                            TerminalKeysLogic.cssPx(r - l, density),
                            TerminalKeysLogic.cssPx(b - t, density),
                        )
                    }
                    addJavascriptInterface(bridge.jsApi, "TermBridge")
                    webChromeClient = TermChromeClient
                    webViewClient = object : WebViewClient() {
                        override fun shouldOverrideUrlLoading(view: WebView, request: android.webkit.WebResourceRequest): Boolean =
                            request.url.toString() != "file:///android_asset/term/term.html"

                        override fun onPageFinished(view: WebView, url: String?) {
                            bridge.webView = view
                            bridge.pushTheme(dark)
                            bridge.fit()
                            if (bridge.sessionBound) return
                            bridge.sessionBound = true
                            val existing = sessionId
                            if (existing != null) {
                                bind(existing)
                            } else {
                                scope.launch {
                                    runCatching {
                                        model.workspaceSection(peer, "pty.spawn", buildJsonObject {
                                            put("workspaceId", workspaceId)
                                            put("command", "/bin/bash")
                                            put("args", kotlinx.serialization.json.JsonArray(emptyList()))
                                            put("rows", 30)
                                            put("cols", 90)
                                            put("noColor", false)
                                            put("dark", dark)
                                        })
                                    }.onSuccess { info ->
                                        val id = (info as? JsonObject)?.get("id")
                                            ?.let { (it as? kotlinx.serialization.json.JsonPrimitive)?.content }
                                        if (id != null) {
                                            bind(id)
                                        } else {
                                            fail("The host would not start a shell.")
                                        }
                                    }.onFailure { error ->
                                        fail(
                                            ai.tokenstat.tokenstat.ui.logic.TunnelCopy.display(
                                                error.message ?: "The request failed.",
                                                hostLabel,
                                            ),
                                        )
                                    }
                                }
                            }
                        }
                    }
                    loadUrl("file:///android_asset/term/term.html")
                }
            },
            onRelease = { view ->
                val id = sessionId
                bridge.alive = false
                if (id != null && !bridge.killed) {
                    // Stop showing a session without stopping its process on
                    // the Mac (`pty.detach`). Close is what ends the process.
                    //
                    // On the view model's scope, not the composable's: this
                    // runs as the screen leaves, and the remembered scope is
                    // cancelled in the same breath, so the request was a coin
                    // toss. Losing it means the phone keeps its claim on the
                    // session's geometry until the host's lease expires, and
                    // the Mac stays at the phone's width in the meantime.
                    model.viewModelScope.launch {
                        runCatching {
                            model.workspaceSection(peer, "pty.detach", ptyViewerParams(id))
                        }
                    }
                }
                view.removeJavascriptInterface("TermBridge")
                bridge.webView = null
            },
        )
        TerminalKeys(
            onSend = { bytes -> bridge.sendBytes(bytes) },
            onToggleKeyboard = { bridge.toggleKeyboard() },
            onScrolls = { bridge.setScrolls(it) },
            control = controlArmed,
            onControl = { bridge.armControl(it) },
            keyboardUp = keyboardUp,
        )
    }
    if (confirmClose) {
        AlertDialog(
            onDismissRequest = { confirmClose = false },
            title = { Text("Close this session?") },
            text = { Text("Stops the process on $hostLabel.") },
            confirmButton = {
                TextButton(onClick = {
                    confirmClose = false
                    val id = sessionId
                    scope.launch {
                        if (id != null) {
                            runCatching {
                                model.workspaceSection(peer, "pty.close", buildJsonObject { put("id", id) })
                            }
                        }
                        bridge.killed = true
                        onClose()
                    }
                }) { Text("Close") }
            },
            dismissButton = {
                TextButton(onClick = { confirmClose = false }) { Text("Keep it") }
            },
        )
    }
}

private fun copyToClipboard(context: Context, text: String) {
    if (text.isEmpty()) return
    val manager = context.getSystemService(ClipboardManager::class.java) ?: return
    manager.setPrimaryClip(ClipData.newPlainText("terminal", text))
}

/// Forwards the xterm page's console to logcat. A blank terminal with a
/// JavaScript error used to be undiagnosable; now the reason is one grep
/// away under the TermWeb tag.
private object TermChromeClient : android.webkit.WebChromeClient() {
    override fun onConsoleMessage(message: android.webkit.ConsoleMessage): Boolean {
        android.util.Log.d("TermWeb", "${message.lineNumber()}: ${message.message()}")
        return true
    }
}

private fun bridgeTitle(bridge: TerminalBridge): String =
    TerminalKeysLogic.basename(bridge.command).ifBlank { "Terminal" }

private fun bridgeSubtitle(bridge: TerminalBridge): String {
    bridge.exitCode?.let { return "exited $it" }
    if (!bridge.alive) return "stopped"
    return bridge.cwd.ifBlank { "" }
}

/// An SSH session on this phone: same xterm surface, local `ssh.session.*`.
///
/// Done leaves the session running on the server, End session stops it,
/// with the same confirm the Apple screen asks. A session that has ended
/// keeps its last screenful and says so.
@SuppressLint("SetJavaScriptEnabled")
@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun SshTerminalScreen(
    model: AppViewModel,
    sessionId: String,
    hostLabel: String,
    snippets: kotlinx.serialization.json.JsonArray = kotlinx.serialization.json.JsonArray(emptyList()),
    onClose: () -> Unit,
    startup: List<String> = emptyList(),
    onEnded: () -> Unit = {},
) {
    // Its own header and its own way out, so the app chrome steps aside.
    HideTopBar()
    HideTabBar()
    // Back is Done: it stops showing the session without stopping the
    // process. Ending it is the Close button, which asks first.
    BackHandler { onClose() }
    val scope = rememberCoroutineScope()
    val context = LocalContext.current
    val dark = isSystemInDarkTheme()
    val bridge = remember {
        TerminalBridge().also {
            it.onCopy = { text -> copyToClipboard(context, text) }
        }
    }
    bridge.lifecycle = LocalLifecycleOwner.current.lifecycle
    var tick by remember { mutableIntStateOf(0) }
    bridge.onProgress = { tick++ }
    var controlArmed by remember { mutableStateOf(false) }
    bridge.onControlChanged = { controlArmed = it }
    var keyboardUp by remember { mutableStateOf(false) }
    bridge.onKeyboardChanged = { keyboardUp = it }
    ReconcileKeyboard(keyboardUp) { keyboardUp = false; bridge.noteKeyboardHidden() }
    var confirmEnd by remember { mutableStateOf(false) }
    var filling by remember { mutableStateOf<JsonObject?>(null) }
    // On-connect commands, once the shell is there to hear them. The channel
    // is buffered, so this survives the page still loading.
    LaunchedEffect(sessionId) {
        if (startup.isNotEmpty()) {
            delay(600)
            startup.forEach { bridge.sendBytes(ai.tokenstat.tokenstat.ui.ssh.SnippetRun.runBytes(it)) }
        }
    }

    fun runSnippet(item: JsonObject) {
        val command = (item["command"] as? kotlinx.serialization.json.JsonPrimitive)?.content ?: return
        if (ai.tokenstat.tokenstat.ui.ssh.SnippetRun.placeholders(command).isEmpty()) {
            bridge.sendBytes(ai.tokenstat.tokenstat.ui.ssh.SnippetRun.runBytes(command))
        } else {
            filling = item
        }
    }

    // The keyboard takes room from the terminal rather than covering it.
    //
    // Nothing consumed the IME inset, so the soft keyboard sat on top of the
    // bottom rows and the key bar, and the page was never told its size had
    // changed. The emulator shrinks, the page re-fits, and the rows come back
    // when the keyboard goes away.
    Column(Modifier.fillMaxSize().navigationBarsPadding().imePadding()) {
        TopAppBar(
            title = {
                key(tick) {
                    Row(verticalAlignment = Alignment.CenterVertically) {
                        Text(hostLabel)
                        if (bridge.ended) {
                            Text(
                                "ended",
                                color = LocalTsColors.current.textSecondary,
                                modifier = Modifier.padding(start = Space.s),
                            )
                        }
                    }
                }
            },
            navigationIcon = {
                IconButton(onClick = onClose) { Icon(Icons.AutoMirrored.Filled.ArrowBack, "Back") }
            },
            actions = {
                TextButton(onClick = { confirmEnd = true }) { Text("End session") }
                // Done leaves it running, which is why it is not Close.
                TextButton(onClick = onClose) { Text("Done") }
            },
        )
        key(tick) {
            bridge.transportError?.let { error ->
                Text(
                    error,
                    color = LocalTsColors.current.danger,
                    modifier = Modifier.fillMaxWidth().padding(horizontal = Space.s),
                )
            }
        }
        AndroidView(
            modifier = Modifier.weight(1f).fillMaxSize(),
            factory = { ctx ->
                WebView(ctx).apply {
                    // Match the space Compose gives this view, explicitly.
                    // `AndroidView` leaves a child on wrap-content, and a
                    // WebView measured that way lays its page out against a
                    // containing block of zero height: `html { height: 100% }`
                    // computes to 0px, so the terminal can never fit itself to
                    // the screen and never follows the keyboard.
                    layoutParams = android.view.ViewGroup.LayoutParams(
                        android.view.ViewGroup.LayoutParams.MATCH_PARENT,
                        android.view.ViewGroup.LayoutParams.MATCH_PARENT,
                    )
                    settings.javaScriptEnabled = true
                    settings.allowFileAccess = false
                    settings.allowContentAccess = false
                    settings.blockNetworkLoads = true
                    settings.domStorageEnabled = false
                    // The page is sized to this view and cannot overflow it,
                    // so there is nothing to scroll to and no bar to show.
                    // A scrollable page pans to follow the focused textarea
                    // at the cursor, which is what jumped the picture.
                    isVerticalScrollBarEnabled = false
                    isHorizontalScrollBarEnabled = false
                    overScrollMode = android.view.View.OVER_SCROLL_NEVER
                    // Both, explicitly. A WebView inside Compose is not given
                    // focus by the focus system, and without focus the page's
                    // textarea cannot be what the keyboard types into.
                    isFocusable = true
                    isFocusableInTouchMode = true
                    // The size the page fits to arrives with layout, not with
                    // the page load, so every layout asks it to measure again.
                    // The measured view size travels with the ask: with the
                    // keyboard open the window pans instead of resizing, so
                    // the page's own viewport stays tall behind a short view.
                    addOnLayoutChangeListener { view, l, t, r, b, ol, ot, or_, ob ->
                        if (r - l == or_ - ol && b - t == ob - ot) return@addOnLayoutChangeListener
                        val density = view.resources.displayMetrics.density
                        bridge.fitSize(
                            TerminalKeysLogic.cssPx(r - l, density),
                            TerminalKeysLogic.cssPx(b - t, density),
                        )
                    }
                    addJavascriptInterface(bridge.jsApi, "TermBridge")
                    webChromeClient = TermChromeClient
                    webViewClient = object : WebViewClient() {
                        override fun shouldOverrideUrlLoading(view: WebView, request: android.webkit.WebResourceRequest): Boolean =
                            request.url.toString() != "file:///android_asset/term/term.html"

                        override fun onPageFinished(view: WebView, url: String?) {
                            bridge.webView = view
                            bridge.pushTheme(dark)
                            bridge.fit()
                            if (!bridge.sessionBound) {
                                bridge.sessionBound = true
                                bridge.startSshLoop(model, sessionId, scope)
                                bridge.pumpSshInput(model, sessionId, scope)
                            }
                        }
                    }
                    loadUrl("file:///android_asset/term/term.html")
                }
            },
            onRelease = { view ->
                bridge.alive = false
                // Done only stops watching. Only an ended session closes.
                //
                // The view model's scope for the same reason the pty detach
                // uses it: a teardown call launched on the composable's scope
                // races the cancellation of that scope, and the one that loses
                // leaves a session open on the server.
                if (bridge.killed) {
                    model.viewModelScope.launch {
                        runCatching {
                            model.core("ssh.session.close", buildJsonObject { put("id", sessionId) })
                        }
                    }
                }
                view.removeJavascriptInterface("TermBridge")
                bridge.webView = null
            },
        )
        TerminalKeys(
            onSend = { bytes -> bridge.sendBytes(bytes) },
            onToggleKeyboard = { bridge.toggleKeyboard() },
            onScrolls = { bridge.setScrolls(it) },
            control = controlArmed,
            onControl = { bridge.armControl(it) },
            keyboardUp = keyboardUp,
            leading = {
                if (snippets.isNotEmpty()) {
                    SnippetKey(snippets, onRun = ::runSnippet)
                }
            },
        )
    }
    if (confirmEnd) {
        AlertDialog(
            onDismissRequest = { confirmEnd = false },
            title = { Text("End this session?") },
            text = { Text("Whatever is running in it stops. Nothing else on the server changes.") },
            confirmButton = {
                TextButton(onClick = {
                    confirmEnd = false
                    scope.launch {
                        val ended = runCatching {
                            model.core("ssh.session.close", buildJsonObject { put("id", sessionId) })
                        }.isSuccess
                        bridge.killed = true
                        if (ended) onEnded()
                        onClose()
                    }
                }) { Text("End session") }
            },
            dismissButton = {
                TextButton(onClick = { confirmEnd = false }) { Text("Cancel") }
            },
        )
    }
    filling?.let { item ->
        SnippetFillSheet(
            item = item,
            onDismiss = { filling = null },
            onRun = { command ->
                filling = null
                bridge.sendBytes(ai.tokenstat.tokenstat.ui.ssh.SnippetRun.runBytes(command))
            },
        )
    }
}

/// Saved commands as one key. Nothing when there is nothing to offer,
/// because a menu that opens on an empty list is a key that does nothing.
@Composable
private fun SnippetKey(
    snippets: kotlinx.serialization.json.JsonArray,
    onRun: (JsonObject) -> Unit,
) {
    val colors = LocalTsColors.current
    var open by remember { mutableStateOf(false) }
    Box {
        Text(
            "snip",
            style = TextStyle(fontSize = 13.sp, fontFamily = androidx.compose.ui.text.font.FontFamily.Monospace),
            color = colors.textPrimary,
            textAlign = TextAlign.Center,
            modifier = Modifier
                .padding(end = 6.dp)
                .clip(RoundedCornerShape(7.dp))
                .background(colors.panel)
                .clickable { open = true }
                .padding(horizontal = 10.dp, vertical = 8.dp),
        )
        androidx.compose.material3.DropdownMenu(
            expanded = open,
            onDismissRequest = { open = false },
        ) {
            snippets.filterIsInstance<JsonObject>().forEach { item ->
                val title = (item["title"] as? kotlinx.serialization.json.JsonPrimitive)?.content
                    ?: (item["label"] as? kotlinx.serialization.json.JsonPrimitive)?.content
                    ?: "Snippet"
                androidx.compose.material3.DropdownMenuItem(
                    text = { Text(title) },
                    onClick = {
                        open = false
                        onRun(item)
                    },
                )
            }
        }
    }
}

/// Fill in a snippet's placeholders before it is typed into the terminal.
/// Values are asked for every time and never stored.
@Composable
private fun SnippetFillSheet(
    item: JsonObject,
    onDismiss: () -> Unit,
    onRun: (String) -> Unit,
) {
    val command = (item["command"] as? kotlinx.serialization.json.JsonPrimitive)?.content.orEmpty()
    val names = remember(command) { ai.tokenstat.tokenstat.ui.ssh.SnippetRun.placeholders(command) }
    val values = remember(command) { mutableMapOf<String, String>().apply { names.forEach { put(it, "") } } }
    var tick by remember { mutableIntStateOf(0) }
    AlertDialog(
        onDismissRequest = onDismiss,
        title = {
            Text(
                (item["title"] as? kotlinx.serialization.json.JsonPrimitive)?.content ?: "Run snippet",
            )
        },
        text = {
            key(tick) {
                Column {
                    names.forEach { name ->
                        androidx.compose.material3.OutlinedTextField(
                            value = values[name].orEmpty(),
                            onValueChange = { values[name] = it; tick++ },
                            label = { Text(name) },
                            singleLine = true,
                            modifier = Modifier.fillMaxWidth(),
                        )
                    }
                }
            }
        },
        confirmButton = {
            TextButton(onClick = {
                onRun(ai.tokenstat.tokenstat.ui.ssh.SnippetRun.fill(command, values.toMap()))
            }) { Text("Run") }
        },
        dismissButton = {
            TextButton(onClick = onDismiss) { Text("Cancel") }
        },
    )
}

/// The WebView ↔ tunnel plumbing: JS hands us input bytes, we hand JS output
/// bytes. Everything crosses as base64 so no escaping can corrupt a stream.
class TerminalBridge {
    var lifecycle: Lifecycle? = null

    private suspend fun awaitForeground() {
        currentCoroutineContext().ensureActive()
        lifecycle?.currentStateFlow?.first { it.isAtLeast(Lifecycle.State.STARTED) }
    }
    @Volatile var webView: WebView? = null
    @Volatile var alive = true
    @Volatile var sessionBound = false
    /// Set once `pty.close` ended the process, so release does not detach a
    /// session that is already gone.
    @Volatile var killed = false
    @Volatile var droppedOutput = false
    @Volatile var outputPaused = false
    @Volatile var transportError: String? = null
    /// A spawn or attach that failed before any output. The screen shows
    /// this with a retry instead of a blank terminal that explains nothing.
    @Volatile var fatalError: String? = null
    @Volatile var exitCode: Int? = null
    @Volatile var command = ""
    @Volatile var cwd = ""
    /// The screen nudges its redraw tick through here when read state moves.
    var onProgress: () -> Unit = {}
    /// A selection in the emulator leaves for the system clipboard.
    var onCopy: (String) -> Unit = {}
    private val inbound = Channel<String>(capacity = 256)

    val jsApi: JsApi by lazy { JsApi() }

    fun writeBase64(base64: String) {
        webView?.post {
            webView?.evaluateJavascript("termWriteB64(${kotlinx.serialization.json.JsonPrimitive(base64)});", null)
        }
    }

    fun pushTheme(dark: Boolean) {
        webView?.post {
            webView?.evaluateJavascript("termSetTheme(${if (dark) "true" else "false"});", null)
        }
    }

    /// Ask the page to measure itself again.
    ///
    /// Called from the view's own layout, because that is the moment the page
    /// finally has a height. A WebView inside Compose loads before it is
    /// measured, and a terminal fitted against no height is one row tall.
    fun fit() {
        webView?.post {
            webView?.evaluateJavascript("termFit();", null)
        }
    }

    /// Fit to the measured view size, in CSS pixels. The page sizes its
    /// terminal box to this rather than to its own viewport, which stays
    /// tall behind a short view while the keyboard is open. See
    /// `termViewport` in term.html.
    fun fitSize(wCss: Int, hCss: Int) {
        if (wCss < 1 || hCss < 1) {
            fit()
            return
        }
        webView?.post {
            webView?.evaluateJavascript("termViewport($wCss,$hCss);", null)
        }
    }

    fun setScrolls(on: Boolean) {
        webView?.post {
            webView?.evaluateJavascript("termSetScrolls(${if (on) "true" else "false"});", null)
        }
    }

    fun readInfo(info: JsonObject?) {
        if (info == null) return
        (info["command"] as? kotlinx.serialization.json.JsonPrimitive)?.content?.let { command = it }
        (info["cwd"] as? kotlinx.serialization.json.JsonPrimitive)?.content?.let { cwd = it }
        (info["alive"] as? kotlinx.serialization.json.JsonPrimitive)?.content?.let { alive = it == "true" }
        (info["exitCode"] as? kotlinx.serialization.json.JsonPrimitive)?.content?.toIntOrNull()?.let {
            exitCode = it
            alive = false
        }
        onProgress()
    }

    /// The armed Ctrl.
    ///
    /// The key bar has no letter keys: the letters arrive through the
    /// emulator's own input path, so a fold that lives in the bar applies to
    /// everything except the keys it is for. Ctrl+C typed on the soft keyboard
    /// went to the shell as a plain `c` and nothing could be interrupted. The
    /// bridge holds the flag and folds the next byte from either source, the
    /// way `ClientTerminalSession.send` does on Apple.
    @Volatile var controlArmed = false
        private set

    /// Raised when the fold spends the flag, so the bar can unlight its key.
    var onControlChanged: (Boolean) -> Unit = {}

    private val main = android.os.Handler(android.os.Looper.getMainLooper())

    fun armControl(on: Boolean) {
        if (controlArmed == on) return
        controlArmed = on
        // The fold can happen on the JavaScript bridge's thread, and the bar
        // that reads this is Compose state.
        main.post { onControlChanged(on) }
    }

    fun sendBytes(bytes: ByteArray) {
        enqueue(bytes)
    }

    private fun enqueue(bytes: ByteArray) {
        var out = bytes
        if (controlArmed) {
            armControl(false)
            // One byte only. A paste under an armed Ctrl is a paste, not a
            // control code, and a cursor key is already an escape sequence.
            if (out.size == 1) {
                TerminalKeysLogic.controlCode(out[0].toInt() and 0xFF)?.let {
                    out = byteArrayOf(it.toByte())
                }
            }
        }
        inbound.trySend(Base64.encodeToString(out, Base64.NO_WRAP))
    }

    fun toggleKeyboard() {
        if (keyboardUp) hideKeyboard() else showKeyboard()
    }

    /// Whether the keyboard was last asked for. The WebView holds focus in
    /// both states, so `hasFocus` cannot answer this. The key bar reads it to
    /// say which way its key points.
    @Volatile var keyboardUp = false
        private set

    var onKeyboardChanged: (Boolean) -> Unit = {}

    /// Raise the keyboard onto the emulator's own textarea.
    ///
    /// The order matters and all three steps are needed. The WebView takes
    /// focus in the view hierarchy, `termFocus()` focuses the hidden textarea
    /// xterm types into, and only then does the IME have an editable to open
    /// against. Asking for the keyboard first opened it with an input type of
    /// zero: it appeared, and every keystroke went nowhere.
    fun showKeyboard() {
        val view = webView ?: return
        view.post {
            view.requestFocus()
            view.evaluateJavascript("termFocus();") {
                val imm = view.context
                    .getSystemService(android.content.Context.INPUT_METHOD_SERVICE)
                    as? android.view.inputmethod.InputMethodManager
                imm?.showSoftInput(view, android.view.inputmethod.InputMethodManager.SHOW_IMPLICIT)
                keyboardUp = true
                onKeyboardChanged(true)
            }
        }
    }

    fun hideKeyboard() {
        val view = webView ?: return
        view.post {
            val imm = view.context
                .getSystemService(android.content.Context.INPUT_METHOD_SERVICE)
                as? android.view.inputmethod.InputMethodManager
            imm?.hideSoftInputFromWindow(view.windowToken, 0)
            view.evaluateJavascript("termBlur();", null)
            keyboardUp = false
            onKeyboardChanged(false)
        }
    }

    /// The window says the keyboard is gone although nothing here hid it: a
    /// system dismissal. Records it so the key bar points at Show again.
    fun noteKeyboardHidden() {
        if (!keyboardUp) return
        keyboardUp = false
        onKeyboardChanged(false)
    }

    fun startReadLoop(model: AppViewModel, peer: String, id: String, scope: CoroutineScope) {
        scope.launch {
            var offset = 0L
            var backoffMs = 50L
            var failures = 0
            while (alive) {
                awaitForeground()
                val chunk = runCatching {
                    model.workspaceSection(peer, "pty.read", ptyViewerParams(id) {
                        put("offset", offset); put("waitMs", 250)
                    })
                }.getOrNull()
                if (chunk == null) {
                    // A failed read is a transport outage, not proof the
                    // process is gone. Back off like the Apple poll loop, and
                    // ask the host whether the process is still running on a
                    // steady drumbeat rather than on every failure.
                    failures++
                    if (transportError == null) {
                        transportError = "Connection lost. Retrying…"
                        onProgress()
                    }
                    if (failures % 8 == 0) {
                        val info = runCatching {
                            model.workspaceSection(peer, "pty.info", ptyViewerParams(id))
                        }.getOrNull() as? JsonObject
                        if (info != null) {
                            readInfo(info)
                            if (exitCode != null || !alive) break
                            if (alive) transportError = null
                            onProgress()
                        }
                    }
                    delay(backoffMs)
                    backoffMs = minOf(backoffMs * 2, 2_000)
                    continue
                }
                backoffMs = 50
                failures = 0
                val obj = chunk as? JsonObject ?: continue
                val data = (obj["data"] as? kotlinx.serialization.json.JsonPrimitive)?.content.orEmpty()
                if (data.isNotEmpty()) writeBase64(data)
                // The host answers `nextOffset`: asking from any other key
                // replays the buffer from the wrong place forever.
                val next = (obj["nextOffset"] as? kotlinx.serialization.json.JsonPrimitive)
                    ?.content?.toLongOrNull()
                if (next != null && next > offset) offset = next
                val dropped = (obj["dropped"] as? kotlinx.serialization.json.JsonPrimitive)
                    ?.content?.toLongOrNull() ?: 0L
                if (dropped > 0 && !droppedOutput) {
                    droppedOutput = true
                    onProgress()
                }
                val paused = (obj["paused"] as? kotlinx.serialization.json.JsonPrimitive)?.content == "true"
                if (paused != outputPaused) {
                    outputPaused = paused
                    onProgress()
                }
                if (transportError != null) {
                    // The host answered, so the outage is over.
                    transportError = null
                    onProgress()
                }
            }
        }
    }

    fun pumpInput(model: AppViewModel, peer: String, id: String, scope: CoroutineScope) {
        scope.launch {
            for (message in inbound) {
                if (!alive) break
                if (message.startsWith("__resize__:")) {
                    val parts = message.removePrefix("__resize__:").split(":")
                    val rows = parts.getOrNull(0)?.toIntOrNull() ?: continue
                    val cols = parts.getOrNull(1)?.toIntOrNull() ?: continue
                    // Sending the ask rather than a command means the host
                    // picks the smaller geometry and the Mac is not left
                    // narrow after the phone closes. The viewer id is what
                    // makes it an ask: without one the host resizes the
                    // session outright. See `TerminalViewer`.
                    runCatching {
                        model.workspaceSection(peer, "pty.resize", ptyViewerParams(id) {
                            put("rows", rows); put("cols", cols)
                        })
                    }
                } else {
                    runCatching {
                        model.workspaceSection(peer, "pty.write", buildJsonObject {
                            put("id", id); put("data", message)
                        })
                    }
                }
            }
        }
    }

    inner class JsApi {
        @JavascriptInterface
        fun onInput(base64: String) {
            // Decoded rather than forwarded, so an armed Ctrl can fold the
            // key that was actually typed.
            enqueue(runCatching { Base64.decode(base64, Base64.DEFAULT) }.getOrNull() ?: return)
        }

        @JavascriptInterface
        fun onResize(rows: Int, cols: Int) {
            inbound.trySend("__resize__:$rows:$cols")
        }

        @JavascriptInterface
        fun onCopy(text: String) {
            onCopy(text)
        }

        /// A tap on the emulator asks for the keyboard, the way a tap on any
        /// other text surface does.
        @JavascriptInterface
        fun onWantsKeyboard() {
            showKeyboard()
        }
    }

    /// Set when the host reports the session closed. The screen shows it
    /// rather than pretending the shell is still there.
    @Volatile var ended = false

    fun startSshLoop(model: AppViewModel, id: String, scope: CoroutineScope) {
        scope.launch {
            var offset = 0L
            var backoffMs = 50L
            while (alive) {
                awaitForeground()
                val chunk = runCatching {
                    model.core("ssh.session.read", buildJsonObject {
                        put("id", id); put("offset", offset); put("waitMs", 250)
                    })
                }.getOrNull()
                if (chunk == null) {
                    // A failed read is a transport outage, not proof the
                    // session ended. Back off and keep polling.
                    if (transportError == null) {
                        transportError = "Connection lost. Retrying…"
                        onProgress()
                    }
                    delay(backoffMs)
                    backoffMs = minOf(backoffMs * 2, 2_000)
                    continue
                }
                backoffMs = 50
                val obj = chunk as? JsonObject ?: continue
                if (transportError != null) {
                    transportError = null
                    onProgress()
                }
                if ((obj["closed"] as? kotlinx.serialization.json.JsonPrimitive)?.content == "true") {
                    ended = true
                    onProgress()
                    break
                }
                val data = obj["data"] as? kotlinx.serialization.json.JsonArray
                if (data != null && data.size > 0) {
                    writeBase64(ai.tokenstat.tokenstat.ui.ssh.bytesToBase64(data))
                }
                val next = (obj["nextOffset"] as? kotlinx.serialization.json.JsonPrimitive)?.content?.toLongOrNull()
                if (next != null && next > offset) offset = next
                if (data == null || data.size == 0) delay(40)
            }
        }
    }

    fun pumpSshInput(model: AppViewModel, id: String, scope: CoroutineScope) {
        scope.launch {
            for (message in inbound) {
                if (!alive) break
                if (message.startsWith("__resize__:")) {
                    val parts = message.removePrefix("__resize__:").split(":")
                    val rows = parts.getOrNull(0)?.toIntOrNull() ?: continue
                    val cols = parts.getOrNull(1)?.toIntOrNull() ?: continue
                    runCatching {
                        model.core("ssh.session.resize", buildJsonObject {
                            put("id", id); put("rows", rows); put("cols", cols)
                        })
                    }
                } else {
                    val bytes = Base64.decode(message, Base64.DEFAULT)
                    runCatching {
                        model.core("ssh.session.write", buildJsonObject {
                            put("id", id)
                            put("data", ai.tokenstat.tokenstat.ui.ssh.rawToJsonBytes(bytes))
                        })
                    }
                }
            }
        }
    }
}

/// The bridge knows when it asked, the window knows what happened. A
/// system dismissal leaves the bar's key pointing at Hide until the two
/// are reconciled.
@Composable
private fun ReconcileKeyboard(keyboardUp: Boolean, onHidden: () -> Unit) {
    val imeVisible = WindowInsets.ime.getBottom(androidx.compose.ui.platform.LocalDensity.current) > 0
    LaunchedEffect(imeVisible) {
        if (!imeVisible) {
            // Past the show animation: without the wait a keyboard still
            // rising would be read as dismissed.
            delay(600)
            if (keyboardUp) onHidden()
        }
    }
}

/// The keys a phone keyboard does not have. Shift+Tab is CSI Z, not a shifted tab byte.
///
/// `leading` carries keys one session has that others do not: an SSH session
/// offers its saved snippets there, an agent session offers nothing. Same
/// slot as Apple `ClientTerminalKeys.leading`.
@Composable
fun TerminalKeys(
    onSend: (ByteArray) -> Unit,
    onToggleKeyboard: () -> Unit,
    onScrolls: (Boolean) -> Unit = {},
    /// Whether Ctrl is armed. Owned by the session that receives typed keys,
    /// because that is the path the letters arrive on. Twin of the `control`
    /// binding in `ClientTerminalKeys`.
    control: Boolean = false,
    onControl: (Boolean) -> Unit = {},
    /// Which way the keyboard key points. Mirrors `keyboardUp` in
    /// `ClientTerminalKeys`, where one key carries both directions.
    keyboardUp: Boolean = false,
    leading: (@Composable () -> Unit)? = null,
) {
    val colors = LocalTsColors.current
    var shift by remember { mutableStateOf(false) }
    var scrolls by remember { mutableStateOf(false) }
    fun fire(bytes: ByteArray) {
        // No fold here. Every byte goes the one way, and the session folds an
        // armed Ctrl into whichever one arrives first.
        onSend(bytes)
        shift = false
    }
    Row(
        Modifier
            .fillMaxWidth()
            .background(colors.tabStrip)
            .horizontalScroll(rememberScrollState())
            .padding(horizontal = Space.s, vertical = 6.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        leading?.invoke()
        IconKeyCap(
            icon = if (keyboardUp) Icons.Default.KeyboardHide else Icons.Default.Keyboard,
            label = if (keyboardUp) "Hide keyboard" else "Show keyboard",
            colors = colors,
            onClick = onToggleKeyboard,
        )
        KeyCap("scroll", colors, armed = scrolls) {
            scrolls = !scrolls
            onScrolls(scrolls)
        }
        KeyCap("esc", colors) { fire(byteArrayOf(0x1B)) }
        KeyCap("ctrl", colors, armed = control) { onControl(!control) }
        KeyCap("shift", colors, armed = shift) { shift = !shift }
        KeyCap(if (shift) "⇧⇥" else "⇥", colors) {
            fire(if (shift) TerminalKeysLogic.backTab else byteArrayOf(0x09))
        }
        KeyCap("↑", colors) { fire(byteArrayOf(0x1B, 0x5B, 0x41)) }
        KeyCap("↓", colors) { fire(byteArrayOf(0x1B, 0x5B, 0x42)) }
        KeyCap("←", colors) { fire(byteArrayOf(0x1B, 0x5B, 0x44)) }
        KeyCap("→", colors) { fire(byteArrayOf(0x1B, 0x5B, 0x43)) }
        listOf("/", "-", "|", "~").forEach { glyph ->
            KeyCap(glyph, colors) { fire(glyph.toByteArray(Charsets.UTF_8)) }
        }
    }
}

/// A keycap whose face is a glyph. The keyboard toggle is the only one: every
/// other key on this bar sends a byte whose name is the thing to draw.
@Composable
private fun IconKeyCap(
    icon: ImageVector,
    label: String,
    colors: TsColors,
    onClick: () -> Unit,
) {
    // The same cap as every other key. A bare glyph in a row of keycaps reads
    // as a label rather than as something to press.
    Icon(
        icon,
        label,
        tint = colors.textPrimary,
        modifier = Modifier
            .padding(end = 6.dp)
            .clip(RoundedCornerShape(7.dp))
            .background(colors.panel)
            .clickable(onClick = onClick)
            .padding(horizontal = 10.dp, vertical = 6.dp)
            .size(20.dp),
    )
}

@Composable
private fun KeyCap(
    label: String,
    colors: TsColors,
    armed: Boolean = false,
    onClick: () -> Unit,
) {
    Text(
        label,
        style = TextStyle(fontSize = 13.sp, fontFamily = androidx.compose.ui.text.font.FontFamily.Monospace),
        color = if (armed) colors.accent else colors.textPrimary,
        textAlign = TextAlign.Center,
        modifier = Modifier
            .padding(end = 6.dp)
            .clip(RoundedCornerShape(7.dp))
            .background(if (armed) colors.accent.copy(alpha = 0.28f) else colors.panel)
            .clickable(onClick = onClick)
            .padding(horizontal = 10.dp, vertical = 8.dp),
    )
}

/// Fold lives in [TerminalKeysLogic] so unit tests pin the same answers as
/// Apple `TerminalControlCode.fold`.
