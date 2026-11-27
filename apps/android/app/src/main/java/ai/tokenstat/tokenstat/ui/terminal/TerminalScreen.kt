// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
package ai.tokenstat.tokenstat.ui.terminal

import ai.tokenstat.tokenstat.ui.localization.L10n

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
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import androidx.lifecycle.repeatOnLifecycle
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.currentCoroutineContext
import kotlinx.coroutines.ensureActive
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.key
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.mutableStateMapOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.platform.LocalContext
import kotlinx.coroutines.delay
import androidx.compose.ui.Modifier
import androidx.compose.ui.viewinterop.AndroidView
import androidx.lifecycle.viewModelScope
import ai.tokenstat.tokenstat.AppViewModel
import ai.tokenstat.tokenstat.ui.logic.ProjectOwner
import ai.tokenstat.tokenstat.ui.logic.TerminalNames
import ai.tokenstat.tokenstat.ui.components.ActionIcon
import ai.tokenstat.tokenstat.ui.components.SessionIdentifierDialog
import ai.tokenstat.tokenstat.ui.logic.SessionIdentities
import ai.tokenstat.tokenstat.ui.logic.parseTerminalSessionIdentities
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.channels.Channel
import kotlinx.coroutines.launch
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.JsonNull
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.put

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
    HideTopBar()
    HideTabBar()
    BackHandler { onClose() }
    val scope = rememberCoroutineScope()
    val context = LocalContext.current
    val client by model.state.collectAsStateWithLifecycle()
    val names = remember(context) { TerminalNames(context) }
    val openingOwner = remember(peer, workspaceId) { ProjectOwner.from(model.state.value.account, peer, workspaceId) }
    val nameOwner = openingOwner?.takeIf { it == ProjectOwner.from(client.account, peer, workspaceId) }
    val dark = LocalTsColors.current.isDark
    val bridge = remember {
        TerminalBridge().also {
            it.onCopy = { text -> copyToClipboard(context, text) }
        }
    }
    bridge.lifecycle = LocalLifecycleOwner.current.lifecycle
    var sessionId by remember { mutableStateOf(existingSessionId) }
    var showingSessionDetails by remember(sessionId, nameOwner) { mutableStateOf(false) }
    var sessionIdentities by remember(sessionId, nameOwner) { mutableStateOf(SessionIdentities()) }
    val lifecycle = LocalLifecycleOwner.current.lifecycle
    LaunchedEffect(showingSessionDetails, sessionId, nameOwner, lifecycle) {
        val id = sessionId?.takeIf { it.isNotBlank() } ?: return@LaunchedEffect
        val owner = nameOwner ?: return@LaunchedEffect
        if (!showingSessionDetails) return@LaunchedEffect
        lifecycle.repeatOnLifecycle(Lifecycle.State.RESUMED) {
            while (ProjectOwner.from(model.state.value.account, peer, workspaceId) == owner) {
                try {
                    val info = model.workspaceSection(peer, "pty.info", ptyViewerParams(id)) as? JsonObject
                    currentCoroutineContext().ensureActive()
                    if (ProjectOwner.from(model.state.value.account, peer, workspaceId) != owner) break
                    sessionIdentities = parseTerminalSessionIdentities(info)
                } catch (cancelled: kotlinx.coroutines.CancellationException) { throw cancelled }
                catch (_: Exception) { }
                delay(5000)
            }
        }
    }
    val displayName = sessionId?.let { names.name(nameOwner, it) }
    var confirmClose by remember { mutableStateOf(false) }
    var rendererFailed by remember { mutableStateOf(false) }
    var controlArmed by remember { mutableStateOf(false) }
    bridge.onControlChanged = { controlArmed = it }
    var keyboardUp by remember { mutableStateOf(false) }
    bridge.onKeyboardChanged = { keyboardUp = it }
    var scrolls by remember { mutableStateOf(bridge.scrolls) }
    var readingOutput by remember { mutableStateOf(false) }
    bridge.onReadingChanged = { readingOutput = it }
    ReconcileKeyboard(keyboardUp) { keyboardUp = false; bridge.noteKeyboardHidden() }
    var tick by remember { mutableIntStateOf(0) }
    bridge.onProgress = { tick++ }

    LaunchedEffect(dark) { bridge.pushTheme(dark) }

    fun fail(message: String) {
        bridge.fatalError = message
        bridge.alive = false
        bridge.onProgress()
    }

    fun retryFreshShell() {
        bridge.stopJobs()
        sessionId = null
        bridge.fatalError = null
        bridge.transportError = null
        bridge.exitCode = null
        bridge.alive = true
        bridge.sessionBound = false
        bridge.onProgress()
        bridge.reloadPage()
    }

    fun bind(id: String) {
        val page = bridge.pageOwner() ?: return
        sessionId = id
        onSessionOpened(id)
        scope.launch {
            bridge.runForPage(page, request = {
                model.workspaceSection(peer, "pty.info", ptyViewerParams(id))
            }) { result ->
                result.onSuccess { element ->
                    bridge.readInfo(element as? JsonObject)
                    if (bridge.exitCode != null || !bridge.alive) {
                        fail(L10n.text("android.terminalscreen.this_session_has_ended.5ac92537"))
                        return@runForPage
                    }
                }
                bridge.startReadLoop(model, peer, id, scope)
                bridge.pumpInput(model, peer, id, scope)
            }
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
                        Text(displayName ?: bridgeTitle(bridge))
                        Text(
                            bridgeSubtitle(bridge),
                            style = androidx.compose.material3.MaterialTheme.typography.bodySmall,
                            color = LocalTsColors.current.textSecondary,
                        )
                    }
                }
            },
            navigationIcon = {
                IconButton(onClick = onClose) { Icon(Icons.AutoMirrored.Filled.ArrowBack, L10n.text("common.back")) }
            },
            actions = {
                IconButton(onClick = { showingSessionDetails = true }, enabled = nameOwner != null && !sessionId.isNullOrBlank()) {
                    Icon(ActionIcon.Docs.vector, L10n.text("common.session_identity.title"))
                }
                TextButton(onClick = { confirmClose = true }) { Text(L10n.text("common.close")) }
                TextButton(onClick = onClose) { Text(L10n.text("common.done")) }
            },
        )
        key(tick) {
            if (bridge.outputPaused) {
                Text(
                    L10n.text("android.terminalscreen.output_paused_while_the_terminal_catches_u.c3cbbc1c"),
                    color = LocalTsColors.current.warning,
                    modifier = Modifier.fillMaxWidth().padding(horizontal = Space.s),
                )
            }
            if (bridge.droppedOutput) {
                Text(
                    L10n.text("android.terminalscreen.some_output_was_dropped.80a58e7e"),
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
                    TextButton(onClick = { retryFreshShell() }) { Text(L10n.text("android.terminalscreen.new_shell.8a926ed7")) }
                }
            }
        }
        if (rendererFailed) Text(
            L10n.text("android.terminalscreen.display_stopped"),
            color = LocalTsColors.current.danger,
            modifier = Modifier.weight(1f).fillMaxWidth().padding(Space.s),
        ) else AndroidView(
            modifier = Modifier.weight(1f).fillMaxSize(),
            factory = { ctx ->
                TerminalWebView(ctx, bridge).apply {
                    onRendererGone = { rendererFailed = true }
                    layoutParams = android.view.ViewGroup.LayoutParams(
                        android.view.ViewGroup.LayoutParams.MATCH_PARENT,
                        android.view.ViewGroup.LayoutParams.MATCH_PARENT,
                    )
                    settings.javaScriptEnabled = true
                    settings.allowFileAccess = false
                    settings.allowContentAccess = false
                    settings.blockNetworkLoads = true
                    settings.domStorageEnabled = false
                    isVerticalScrollBarEnabled = false
                    isHorizontalScrollBarEnabled = false
                    overScrollMode = android.view.View.OVER_SCROLL_NEVER
                    isFocusable = true
                    isFocusableInTouchMode = true
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
                        override fun onRenderProcessGone(view: WebView, detail: android.webkit.RenderProcessGoneDetail): Boolean =
                            (view as TerminalWebView).rendererGone()

                        override fun shouldOverrideUrlLoading(view: WebView, request: android.webkit.WebResourceRequest): Boolean =
                            request.url.toString() != bridge.pageUrl()

                        override fun onPageFinished(view: WebView, url: String?) {
                            if (!bridge.acceptPage(view, url)) return
                            bridge.pushTheme(dark)
                            bridge.setScrolls(bridge.scrolls)
                            bridge.fit()
                            if (bridge.sessionBound) return
                            bridge.sessionBound = true
                            val existing = sessionId
                            if (existing != null) {
                                bind(existing)
                            } else {
                                val page = bridge.pageOwner() ?: return
                                scope.launch {
                                    bridge.runForPage(page, request = {
                                        model.workspaceSection(peer, "pty.spawn", buildJsonObject {
                                            put("workspaceId", workspaceId)
                                            put("command", terminalShell(
                                                ((model.state.value.account?.get("machines") as? kotlinx.serialization.json.JsonArray).orEmpty())
                                                    .filterIsInstance<JsonObject>()
                                                    .firstOrNull { (it["publicIdentity"] as? kotlinx.serialization.json.JsonPrimitive)?.content == peer }
                                                    ?.let { (it["platform"] as? kotlinx.serialization.json.JsonPrimitive)?.content },
                                            ))
                                            put("args", kotlinx.serialization.json.JsonArray(emptyList()))
                                            put("rows", 30)
                                            put("cols", 90)
                                            put("noColor", false)
                                            put("dark", dark)
                                        })
                                    }) { result ->
                                        result.onSuccess { info ->
                                            val id = (info as? JsonObject)?.get("id")
                                                ?.let { (it as? kotlinx.serialization.json.JsonPrimitive)?.content }
                                            if (id != null) {
                                                bind(id)
                                            } else {
                                                fail(L10n.text("android.terminalscreen.the_host_would_not_start_a_shell.144768c7"))
                                            }
                                        }.onFailure { error ->
                                            fail(
                                                ai.tokenstat.tokenstat.ui.logic.TunnelCopy.display(
                                                    error.message ?: L10n.text("android.terminalscreen.the_request_failed.db4fb447"),
                                                    hostLabel,
                                                ),
                                            )
                                        }
                                    }
                                }
                            }
                        }
                    }
                    loadUrl(bridge.pageUrl())
                }
            },
            onRelease = { view ->
                val id = sessionId
                view.shutdown()
                if (id != null && !bridge.killed) {
                    model.viewModelScope.launch {
                        runCatching {
                            model.workspaceSection(peer, "pty.detach", ptyViewerParams(id))
                        }
                    }
                }
            },
        )
        if (!rendererFailed) TerminalKeys(
            onSend = { bytes -> bridge.sendBytes(bytes) },
            onToggleKeyboard = { bridge.toggleKeyboard() },
            scrolls = scrolls,
            onScrolls = { scrolls = it; bridge.setScrolls(it) },
            readingOutput = readingOutput,
            onFollowOutput = { bridge.followOutput() },
            control = controlArmed,
            onControl = { bridge.armControl(it) },
            keyboardUp = keyboardUp,
        )
    }
    if (showingSessionDetails && nameOwner != null) sessionId?.takeIf { it.isNotBlank() }?.let { id ->
        SessionIdentifierDialog(id, sessionIdentities) { showingSessionDetails = false }
    }
    if (confirmClose) {
        AlertDialog(
            onDismissRequest = { confirmClose = false },
            title = { Text(L10n.text("android.terminalscreen.close_this_session.2b66ce2d")) },
            text = { Text(L10n.text("android.terminalscreen.stops_the_process_on_0.7aa0b494", "${hostLabel}")) },
            confirmButton = {
                TextButton(onClick = {
                    confirmClose = false
                    val id = sessionId
                    scope.launch {
                        try {
                            if (id != null) model.workspaceSection(peer, "pty.close", buildJsonObject { put("id", id) })
                            bridge.killed = true
                            onClose()
                        } catch (failure: Exception) {
                            if (failure is kotlinx.coroutines.CancellationException) throw failure
                            bridge.transportError = failure.message ?: L10n.text("android.terminalscreen.the_request_failed.db4fb447")
                            bridge.onProgress()
                        }
                    }
                }) { Text(L10n.text("common.close")) }
            },
            dismissButton = {
                TextButton(onClick = { confirmClose = false }) { Text(L10n.text("android.terminalscreen.keep_it.fdce5da2")) }
            },
        )
    }
}

private fun copyToClipboard(context: Context, text: String) {
    if (text.isEmpty()) return
    val manager = context.getSystemService(ClipboardManager::class.java) ?: return
    manager.setPrimaryClip(ClipData.newPlainText("terminal", text))
}

private object TermChromeClient : android.webkit.WebChromeClient() {
    override fun onConsoleMessage(message: android.webkit.ConsoleMessage): Boolean {
        android.util.Log.d("TermWeb", "${message.lineNumber()}: ${message.message()}")
        return true
    }
}

private fun bridgeTitle(bridge: TerminalBridge): String =
    TerminalKeysLogic.basename(bridge.command).ifBlank { L10n.text("android.terminalscreen.terminal.e0926fda") }

private fun bridgeSubtitle(bridge: TerminalBridge): String {
    bridge.exitCode?.let { return L10n.text("android.terminalscreen.exited_0.39ec5073", "${it}") }
    if (!bridge.alive) return L10n.text("android.terminalscreen.stopped.8322e87d")
    return bridge.cwd.ifBlank { "" }
}

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
    onStartupSent: () -> Unit = {},
    onEnded: () -> Unit = {},
) {
    HideTopBar()
    HideTabBar()
    BackHandler { onClose() }
    val scope = rememberCoroutineScope()
    val context = LocalContext.current
    val dark = LocalTsColors.current.isDark
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
    var scrolls by remember { mutableStateOf(bridge.scrolls) }
    var readingOutput by remember { mutableStateOf(false) }
    bridge.onReadingChanged = { readingOutput = it }
    ReconcileKeyboard(keyboardUp) { keyboardUp = false; bridge.noteKeyboardHidden() }
    LaunchedEffect(dark) { bridge.pushTheme(dark) }
    var confirmEnd by remember { mutableStateOf(false) }
    var rendererFailed by remember { mutableStateOf(false) }
    var showingSessionDetails by remember(sessionId) { mutableStateOf(false) }
    var filling by remember { mutableStateOf<JsonObject?>(null) }
    LaunchedEffect(sessionId, rendererFailed) {
        if (!rendererFailed && startup.isNotEmpty()) {
            delay(600)
            if (!bridge.alive) return@LaunchedEffect
            startup.forEach { bridge.sendBytes(ai.tokenstat.tokenstat.ui.ssh.SnippetRun.runBytes(it)) }
            onStartupSent()
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
                                L10n.text("android.terminalscreen.ended.e87ba7a0"),
                                color = LocalTsColors.current.textSecondary,
                                modifier = Modifier.padding(start = Space.s),
                            )
                        }
                    }
                }
            },
            navigationIcon = {
                IconButton(onClick = onClose) { Icon(Icons.AutoMirrored.Filled.ArrowBack, L10n.text("common.back")) }
            },
            actions = {
                IconButton(onClick = { showingSessionDetails = true }, enabled = sessionId.isNotBlank()) {
                    Icon(ActionIcon.Docs.vector, L10n.text("common.session_identity.title"))
                }
                TextButton(onClick = { confirmEnd = true }) { Text(L10n.text("android.terminalscreen.end_session.f00b921f")) }
                TextButton(onClick = onClose) { Text(L10n.text("common.done")) }
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
        if (rendererFailed) Text(
            L10n.text("android.terminalscreen.display_stopped"),
            color = LocalTsColors.current.danger,
            modifier = Modifier.weight(1f).fillMaxWidth().padding(Space.s),
        ) else AndroidView(
            modifier = Modifier.weight(1f).fillMaxSize(),
            factory = { ctx ->
                TerminalWebView(ctx, bridge).apply {
                    onRendererGone = { rendererFailed = true }
                    layoutParams = android.view.ViewGroup.LayoutParams(
                        android.view.ViewGroup.LayoutParams.MATCH_PARENT,
                        android.view.ViewGroup.LayoutParams.MATCH_PARENT,
                    )
                    settings.javaScriptEnabled = true
                    settings.allowFileAccess = false
                    settings.allowContentAccess = false
                    settings.blockNetworkLoads = true
                    settings.domStorageEnabled = false
                    isVerticalScrollBarEnabled = false
                    isHorizontalScrollBarEnabled = false
                    overScrollMode = android.view.View.OVER_SCROLL_NEVER
                    isFocusable = true
                    isFocusableInTouchMode = true
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
                        override fun onRenderProcessGone(view: WebView, detail: android.webkit.RenderProcessGoneDetail): Boolean =
                            (view as TerminalWebView).rendererGone()

                        override fun shouldOverrideUrlLoading(view: WebView, request: android.webkit.WebResourceRequest): Boolean =
                            request.url.toString() != bridge.pageUrl()

                        override fun onPageFinished(view: WebView, url: String?) {
                            if (!bridge.acceptPage(view, url)) return
                            bridge.pushTheme(dark)
                            bridge.setScrolls(bridge.scrolls)
                            bridge.fit()
                            if (!bridge.sessionBound) {
                                bridge.sessionBound = true
                                bridge.startSshLoop(model, sessionId, scope)
                                bridge.pumpSshInput(model, sessionId, scope)
                            }
                        }
                    }
                    loadUrl(bridge.pageUrl())
                }
            },
            onRelease = { view ->
                view.shutdown()
                if (bridge.killed) {
                    model.viewModelScope.launch {
                        runCatching {
                            model.core("ssh.session.close", buildJsonObject { put("id", sessionId) })
                        }
                    }
                }
            },
        )
        if (!rendererFailed) TerminalKeys(
            onSend = { bytes -> bridge.sendBytes(bytes) },
            onToggleKeyboard = { bridge.toggleKeyboard() },
            scrolls = scrolls,
            onScrolls = { scrolls = it; bridge.setScrolls(it) },
            readingOutput = readingOutput,
            onFollowOutput = { bridge.followOutput() },
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
    if (showingSessionDetails) SessionIdentifierDialog(sessionId) { showingSessionDetails = false }
    if (confirmEnd) {
        AlertDialog(
            onDismissRequest = { confirmEnd = false },
            title = { Text(L10n.text("android.terminalscreen.end_this_session.2a445dc0")) },
            text = { Text(L10n.text("android.terminalscreen.whatever_is_running_in_it_stops_nothing_el.f25aee6b")) },
            confirmButton = {
                TextButton(onClick = {
                    confirmEnd = false
                    scope.launch {
                        try {
                            model.core("ssh.session.close", buildJsonObject { put("id", sessionId) })
                            bridge.killed = true
                            onEnded()
                            onClose()
                        } catch (failure: Exception) {
                            if (failure is kotlinx.coroutines.CancellationException) throw failure
                            bridge.transportError = failure.message ?: L10n.text("android.terminalscreen.the_request_failed.db4fb447")
                            bridge.onProgress()
                        }
                    }
                }) { Text(L10n.text("android.terminalscreen.end_session.f00b921f")) }
            },
            dismissButton = {
                TextButton(onClick = { confirmEnd = false }) { Text(L10n.text("common.cancel")) }
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

@Composable
private fun SnippetKey(
    snippets: kotlinx.serialization.json.JsonArray,
    onRun: (JsonObject) -> Unit,
) {
    val colors = LocalTsColors.current
    var open by remember { mutableStateOf(false) }
    Box {
        Text(
            L10n.text("android.terminalscreen.snip.b0e6a23a"),
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
                    ?: L10n.text("android.terminalscreen.snippet.48f55cb8")
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

@Composable
private fun SnippetFillSheet(
    item: JsonObject,
    onDismiss: () -> Unit,
    onRun: (String) -> Unit,
) {
    val command = (item["command"] as? kotlinx.serialization.json.JsonPrimitive)?.content.orEmpty()
    val names = remember(command) { ai.tokenstat.tokenstat.ui.ssh.SnippetRun.placeholders(command) }
    val values = remember(command) { mutableStateMapOf<String, String>().apply { names.forEach { put(it, "") } } }
    AlertDialog(
        onDismissRequest = onDismiss,
        title = {
            Text(
                (item["title"] as? kotlinx.serialization.json.JsonPrimitive)?.content ?: L10n.text("android.terminalscreen.run_snippet.9fba9773"),
            )
        },
        text = {
            Column {
                    names.forEach { name ->
                        androidx.compose.material3.OutlinedTextField(
                            value = values[name].orEmpty(),
                            onValueChange = { values[name] = it },
                            label = { Text(name) },
                            singleLine = true,
                            modifier = Modifier.fillMaxWidth(),
                        )
                    }
            }
        },
        confirmButton = {
            TextButton(onClick = {
                onRun(ai.tokenstat.tokenstat.ui.ssh.SnippetRun.fill(command, values.toMap()))
            }) { Text(L10n.text("common.run")) }
        },
        dismissButton = {
            TextButton(onClick = onDismiss) { Text(L10n.text("common.cancel")) }
        },
    )
}

class TerminalBridge {
    var lifecycle: Lifecycle? = null

    private suspend fun awaitForeground() {
        currentCoroutineContext().ensureActive()
        lifecycle?.currentStateFlow?.first { it.isAtLeast(Lifecycle.State.STARTED) }
    }
    @Volatile var webView: WebView? = null
    @Volatile var alive = true
    @Volatile var sessionBound = false
    @Volatile var killed = false
    @Volatile var droppedOutput = false
    @Volatile var outputPaused = false
    @Volatile var transportError: String? = null
    @Volatile var fatalError: String? = null
    @Volatile var exitCode: Int? = null
    @Volatile var command = ""
    @Volatile var cwd = ""
    var onProgress: () -> Unit = {}
    var onCopy: (String) -> Unit = {}
    private val inbound = Channel<String>(capacity = 256)
    private val inputLock = Any()
    private var readJob: kotlinx.coroutines.Job? = null
    private var inputJob: kotlinx.coroutines.Job? = null
    @Volatile private var pageEpoch = 0L

    fun stopJobs() {
        synchronized(inputLock) {
            pageEpoch++
            while (inbound.tryReceive().isSuccess) { }
        }
        readJob?.cancel()
        inputJob?.cancel()
        readJob = null
        inputJob = null
    }

    val jsApi: JsApi get() = JsApi(pageEpoch)

    internal fun pageUrl(): String = "file:///android_asset/term/term.html?epoch=$pageEpoch"

    internal fun acceptPage(view: WebView, url: String?): Boolean {
        if (!alive || url != pageUrl()) return false
        webView = view
        return true
    }

    fun reloadPage() {
        webView?.let { view ->
            view.addJavascriptInterface(jsApi, "TermBridge")
            view.loadUrl(pageUrl())
        }
    }

    private fun ownsPage(view: WebView, epoch: Long): Boolean = webView === view && pageEpoch == epoch

    internal class PageOwner internal constructor(internal val view: WebView, internal val epoch: Long)

    internal fun pageOwner(): PageOwner? = webView?.let { PageOwner(it, pageEpoch) }

    internal suspend fun <T> runForPage(owner: PageOwner, request: suspend () -> T, complete: (Result<T>) -> Unit) {
        currentCoroutineContext().ensureActive()
        if (!ownsPage(owner.view, owner.epoch)) return
        val result = try { Result.success(request()) }
        catch (cancelled: kotlinx.coroutines.CancellationException) { throw cancelled }
        catch (error: Exception) { Result.failure(error) }
        currentCoroutineContext().ensureActive()
        if (ownsPage(owner.view, owner.epoch)) complete(result)
    }

    private fun postToPage(script: () -> String) {
        val view = webView ?: return
        val epoch = pageEpoch
        view.post {
            if (ownsPage(view, epoch)) view.evaluateJavascript(script(), null)
        }
    }

    fun writeBase64(base64: String) {
        postToPage { "termWriteB64(${kotlinx.serialization.json.JsonPrimitive(base64)});" }
    }

    fun pushTheme(dark: Boolean) {
        postToPage { "termSetTheme(${if (dark) "true" else "false"});" }
    }

    fun fit() {
        postToPage { "termFit();" }
    }

    fun fitSize(wCss: Int, hCss: Int) {
        if (wCss < 1 || hCss < 1) {
            fit()
            return
        }
        postToPage { "termViewport($wCss,$hCss);" }
    }

    @Volatile var scrolls = false
        private set
    var onReadingChanged: (Boolean) -> Unit = {}

    fun followOutput() {
        postToPage { "termFollowLatest();" }
    }

    fun setScrolls(on: Boolean) {
        scrolls = on
        postToPage { "termSetScrolls(${if (on) "true" else "false"});" }
    }

    fun readInfo(info: JsonObject?) {
        if (info == null) return
        val previousCommand = command
        val previousCwd = cwd
        val previousAlive = alive
        val previousExitCode = exitCode
        (info["command"] as? kotlinx.serialization.json.JsonPrimitive)?.content?.let { command = it }
        (info["cwd"] as? kotlinx.serialization.json.JsonPrimitive)?.content?.let { cwd = it }
        (info["alive"] as? kotlinx.serialization.json.JsonPrimitive)?.content?.let { alive = it == "true" }
        (info["exitCode"] as? kotlinx.serialization.json.JsonPrimitive)?.content?.toIntOrNull()?.let {
            exitCode = it
            alive = false
        }
        if (command != previousCommand || cwd != previousCwd ||
            alive != previousAlive || exitCode != previousExitCode
        ) onProgress()
    }

    @Volatile var controlArmed = false
        private set

    var onControlChanged: (Boolean) -> Unit = {}

    private val main = android.os.Handler(android.os.Looper.getMainLooper())

    fun armControl(on: Boolean) {
        if (controlArmed == on) return
        controlArmed = on
        main.post { onControlChanged(on) }
    }

    fun sendBytes(bytes: ByteArray) {
        enqueue(bytes)
    }

    private fun enqueue(bytes: ByteArray) {
        var out = bytes
        if (controlArmed) {
            armControl(false)
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
        val epoch = pageEpoch
        view.post {
            if (!ownsPage(view, epoch)) return@post
            view.requestFocus()
            view.evaluateJavascript("termFocus();") {
                if (!ownsPage(view, epoch)) return@evaluateJavascript
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
        val epoch = pageEpoch
        view.post {
            if (!ownsPage(view, epoch)) return@post
            val imm = view.context
                .getSystemService(android.content.Context.INPUT_METHOD_SERVICE)
                as? android.view.inputmethod.InputMethodManager
            imm?.hideSoftInputFromWindow(view.windowToken, 0)
            view.evaluateJavascript("termBlur();", null)
            keyboardUp = false
            onKeyboardChanged(false)
        }
    }

    fun noteKeyboardHidden() {
        if (!keyboardUp) return
        keyboardUp = false
        onKeyboardChanged(false)
    }

    fun startReadLoop(model: AppViewModel, peer: String, id: String, scope: CoroutineScope) {
        startReadLoop(id, scope, request = { method, params -> model.workspaceSection(peer, method, params) })
    }

    internal fun startReadLoop(
        id: String,
        scope: CoroutineScope,
        request: suspend (String, JsonObject) -> JsonElement,
        output: (String) -> Unit = ::writeBase64,
    ): kotlinx.coroutines.Job {
        readJob?.cancel()
        val reading = scope.launch {
            var offset = 0L
            var backoffMs = 50L
            var failures = 0
            var lastInfoAt: Long? = null
            while (true) {
                awaitForeground()
                val chunk = runCatching {
                    request("pty.read", ptyViewerParams(id) {
                        put("offset", offset); put("waitMs", 250)
                    })
                }.onFailure {
                    if (it is kotlinx.coroutines.CancellationException) throw it
                }.getOrNull()
                currentCoroutineContext().ensureActive()
                if (chunk == null) {
                    failures++
                    if (transportError == null) {
                        transportError = L10n.text("android.terminalscreen.connection_lost_retrying.7bb52793")
                        onProgress()
                    }
                    if (failures % 8 == 0) {
                        lastInfoAt = System.nanoTime()
                        val info = runCatching {
                            request("pty.info", ptyViewerParams(id))
                        }.onFailure {
                            if (it is kotlinx.coroutines.CancellationException) throw it
                        }.getOrNull() as? JsonObject
                        currentCoroutineContext().ensureActive()
                        if (info != null) {
                            readInfo(info)
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
                if (data.isNotEmpty()) output(data)
                val next = (obj["nextOffset"] as? kotlinx.serialization.json.JsonPrimitive)
                    ?.content?.toLongOrNull()
                if (next != null && next > offset) offset = next
                val readExit = obj["exitCode"]
                val reportsExit = readExit == JsonNull ||
                    (readExit as? kotlinx.serialization.json.JsonPrimitive)?.content?.toIntOrNull() != null
                if (reportsExit) readInfo(obj)
                val readEnd = obj["outputEndOffset"]
                val outputEnd = (readEnd as? kotlinx.serialization.json.JsonPrimitive)
                    ?.content?.toLongOrNull()?.takeIf { it >= 0 }
                val reportsEnd = readEnd == JsonNull || outputEnd != null
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
                    transportError = null
                    onProgress()
                }
                val now = System.nanoTime()
                if (data.isEmpty() && !reportsExit && alive && exitCode == null &&
                    (lastInfoAt == null || now - lastInfoAt >= 1_000_000_000L)
                ) {
                    lastInfoAt = now
                    val info = runCatching {
                        request("pty.info", ptyViewerParams(id))
                    }.onFailure {
                        if (it is kotlinx.coroutines.CancellationException) throw it
                    }.getOrNull() as? JsonObject
                    currentCoroutineContext().ensureActive()
                    if (info != null) readInfo(info)
                }
                val outputDrained = !reportsEnd || (outputEnd != null && offset >= outputEnd)
                if (data.isEmpty() && (exitCode != null || !alive) && outputDrained) break
            }
        }
        readJob = reading
        return reading
    }

    fun pumpInput(model: AppViewModel, peer: String, id: String, scope: CoroutineScope) {
        inputJob?.cancel()
        inputJob = scope.launch {
            for (message in inbound) {
                if (!alive) break
                if (message.startsWith("__resize__:")) {
                    val parts = message.removePrefix("__resize__:").split(":")
                    val rows = parts.getOrNull(0)?.toIntOrNull() ?: continue
                    val cols = parts.getOrNull(1)?.toIntOrNull() ?: continue
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

    inner class JsApi(private val epoch: Long) {
        @JavascriptInterface
        fun onReadingChanged(reading: Boolean) {
            main.post { if (pageEpoch == epoch) this@TerminalBridge.onReadingChanged(reading) }
        }

        @JavascriptInterface
        fun onInput(base64: String) {
            if (pageEpoch != epoch) return
            val bytes = runCatching { Base64.decode(base64, Base64.DEFAULT) }.getOrNull() ?: return
            synchronized(inputLock) { if (pageEpoch == epoch) enqueue(bytes) }
        }

        @JavascriptInterface
        fun onResize(rows: Int, cols: Int) {
            synchronized(inputLock) {
                if (pageEpoch == epoch) inbound.trySend("__resize__:$rows:$cols")
            }
        }

        @JavascriptInterface
        fun onCopy(text: String) {
            main.post { if (pageEpoch == epoch) this@TerminalBridge.onCopy(text) }
        }

        @JavascriptInterface
        fun onWantsKeyboard() {
            main.post { if (pageEpoch == epoch) showKeyboard() }
        }
    }

    @Volatile var ended = false

    fun startSshLoop(model: AppViewModel, id: String, scope: CoroutineScope) {
        readJob?.cancel()
        readJob = scope.launch {
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
                    if (transportError == null) {
                        transportError = L10n.text("android.terminalscreen.connection_lost_retrying.7bb52793")
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
                val data = obj["data"] as? kotlinx.serialization.json.JsonArray
                if (data != null && data.size > 0) {
                    writeBase64(ai.tokenstat.tokenstat.ui.ssh.bytesToBase64(data))
                }
                val next = (obj["nextOffset"] as? kotlinx.serialization.json.JsonPrimitive)?.content?.toLongOrNull()
                if (next != null && next > offset) offset = next
                if ((obj["closed"] as? kotlinx.serialization.json.JsonPrimitive)?.content == "true") {
                    ended = true
                    alive = false
                    onProgress()
                    break
                }
                if (data == null || data.size == 0) delay(40)
            }
        }
    }

    fun pumpSshInput(model: AppViewModel, id: String, scope: CoroutineScope) {
        inputJob?.cancel()
        inputJob = scope.launch {
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

@Composable
private fun ReconcileKeyboard(keyboardUp: Boolean, onHidden: () -> Unit) {
    val imeVisible = WindowInsets.ime.getBottom(androidx.compose.ui.platform.LocalDensity.current) > 0
    LaunchedEffect(imeVisible) {
        if (!imeVisible) {
            delay(600)
            if (keyboardUp) onHidden()
        }
    }
}

@Composable
fun TerminalKeys(
    onSend: (ByteArray) -> Unit,
    onToggleKeyboard: () -> Unit,
    onScrolls: (Boolean) -> Unit = {},
    scrolls: Boolean = false,
    readingOutput: Boolean = false,
    onFollowOutput: () -> Unit = {},
    control: Boolean = false,
    onControl: (Boolean) -> Unit = {},
    keyboardUp: Boolean = false,
    leading: (@Composable () -> Unit)? = null,
) {
    val colors = LocalTsColors.current
    var shift by remember { mutableStateOf(false) }
    fun fire(bytes: ByteArray) {
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
            label = if (keyboardUp) L10n.text("android.terminalscreen.hide_keyboard.f6b0718e") else L10n.text("android.terminalscreen.show_keyboard.585f7659"),
            colors = colors,
            onClick = onToggleKeyboard,
        )
        KeyCap("scroll", colors, armed = scrolls) {
            onScrolls(!scrolls)
        }
        if (readingOutput) {
            IconKeyCap(
                icon = ai.tokenstat.tokenstat.ui.components.ActionIcon.Latest.vector,
                label = L10n.text("android.transcriptfollow.jump_to_latest.86752458"),
                colors = colors,
                onClick = onFollowOutput,
            )
        }
        KeyCap("esc", colors) { fire(byteArrayOf(0x1B)) }
        KeyCap("ctrl", colors, armed = control) { onControl(!control) }
        KeyCap("shift", colors, armed = shift) { shift = !shift }
        KeyCap(if (shift) "⇧⇥" else "⇥", colors) {
            fire(if (shift) TerminalKeysLogic.backTab else byteArrayOf(0x09))
        }
        KeyCap("↑", colors) { fire(TerminalKeysLogic.arrow('A', shift, control)) }
        KeyCap("↓", colors) { fire(TerminalKeysLogic.arrow('B', shift, control)) }
        KeyCap("←", colors) { fire(TerminalKeysLogic.arrow('D', shift, control)) }
        KeyCap("→", colors) { fire(TerminalKeysLogic.arrow('C', shift, control)) }
        listOf("/", "-", "|", "~").forEach { glyph ->
            KeyCap(glyph, colors) { fire(glyph.toByteArray(Charsets.UTF_8)) }
        }
    }
}

@Composable
private fun IconKeyCap(
    icon: ImageVector,
    label: String,
    colors: TsColors,
    onClick: () -> Unit,
) {
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

