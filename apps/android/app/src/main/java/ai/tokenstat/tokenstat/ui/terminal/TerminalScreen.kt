// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
package ai.tokenstat.tokenstat.ui.terminal

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
import androidx.compose.foundation.layout.fillMaxWidth
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
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.material3.TopAppBar
import androidx.compose.runtime.Composable
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
    val scope = rememberCoroutineScope()
    val context = LocalContext.current
    val dark = isSystemInDarkTheme()
    val bridge = remember {
        TerminalBridge().also {
            it.onCopy = { text -> copyToClipboard(context, text) }
        }
    }
    var sessionId by remember { mutableStateOf(existingSessionId) }
    var confirmClose by remember { mutableStateOf(false) }
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
                model.workspaceSection(peer, "pty.info", buildJsonObject { put("id", id) })
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

    Column(Modifier.fillMaxSize()) {
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
                    settings.javaScriptEnabled = true
                    settings.domStorageEnabled = false
                    addJavascriptInterface(bridge.jsApi, "TermBridge")
                    webChromeClient = TermChromeClient
                    webViewClient = object : WebViewClient() {
                        override fun onPageFinished(view: WebView, url: String?) {
                            bridge.webView = view
                            bridge.pushTheme(dark)
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
                    scope.launch {
                        runCatching {
                            model.workspaceSection(peer, "pty.detach", buildJsonObject { put("id", id) })
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
    val scope = rememberCoroutineScope()
    val context = LocalContext.current
    val dark = isSystemInDarkTheme()
    val bridge = remember {
        TerminalBridge().also {
            it.onCopy = { text -> copyToClipboard(context, text) }
        }
    }
    var tick by remember { mutableIntStateOf(0) }
    bridge.onProgress = { tick++ }
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

    Column(Modifier.fillMaxSize()) {
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
                    settings.javaScriptEnabled = true
                    settings.domStorageEnabled = false
                    addJavascriptInterface(bridge.jsApi, "TermBridge")
                    webChromeClient = TermChromeClient
                    webViewClient = object : WebViewClient() {
                        override fun onPageFinished(view: WebView, url: String?) {
                            bridge.webView = view
                            bridge.pushTheme(dark)
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
                if (bridge.killed) {
                    scope.launch {
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
            webView?.evaluateJavascript("termWriteB64(\"$base64\");", null)
        }
    }

    fun pushTheme(dark: Boolean) {
        webView?.post {
            webView?.evaluateJavascript("termSetTheme(${if (dark) "true" else "false"});", null)
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

    fun sendBytes(bytes: ByteArray) {
        inbound.trySend(Base64.encodeToString(bytes, Base64.NO_WRAP))
    }

    fun toggleKeyboard() {
        val view = webView ?: return
        val imm = view.context.getSystemService(android.content.Context.INPUT_METHOD_SERVICE)
            as android.view.inputmethod.InputMethodManager
        view.post {
            if (view.hasFocus()) {
                imm.hideSoftInputFromWindow(view.windowToken, 0)
                view.clearFocus()
            } else {
                view.requestFocus()
                imm.showSoftInput(view, android.view.inputmethod.InputMethodManager.SHOW_IMPLICIT)
            }
        }
    }

    fun startReadLoop(model: AppViewModel, peer: String, id: String, scope: CoroutineScope) {
        scope.launch {
            var offset = 0L
            var backoffMs = 50L
            var failures = 0
            while (alive) {
                val chunk = runCatching {
                    model.workspaceSection(peer, "pty.read", buildJsonObject {
                        put("id", id); put("offset", offset); put("waitMs", 250)
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
                            model.workspaceSection(peer, "pty.info", buildJsonObject { put("id", id) })
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
                    // narrow after the phone closes.
                    runCatching {
                        model.workspaceSection(peer, "pty.resize", buildJsonObject {
                            put("id", id); put("rows", rows); put("cols", cols)
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
            inbound.trySend(base64)
        }

        @JavascriptInterface
        fun onResize(rows: Int, cols: Int) {
            inbound.trySend("__resize__:$rows:$cols")
        }

        @JavascriptInterface
        fun onCopy(text: String) {
            onCopy(text)
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
    leading: (@Composable () -> Unit)? = null,
) {
    val colors = LocalTsColors.current
    var shift by remember { mutableStateOf(false) }
    var control by remember { mutableStateOf(false) }
    var scrolls by remember { mutableStateOf(false) }
    fun fire(bytes: ByteArray) {
        var out = bytes
        if (control && out.size == 1) {
            val folded = TerminalKeysLogic.controlCode(out[0].toInt() and 0xFF)
            if (folded != null) out = byteArrayOf(folded.toByte())
        }
        onSend(out)
        shift = false
        control = false
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
        KeyCap("kb", colors) { onToggleKeyboard() }
        KeyCap("scroll", colors, armed = scrolls) {
            scrolls = !scrolls
            onScrolls(scrolls)
        }
        KeyCap("esc", colors) { fire(byteArrayOf(0x1B)) }
        KeyCap("ctrl", colors, armed = control) { control = !control }
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
