// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
package ai.tokenstat.tokenstat.ui.workspace

import ai.tokenstat.tokenstat.AppViewModel
import ai.tokenstat.tokenstat.ui.components.ActionIcon
import ai.tokenstat.tokenstat.ui.components.TsSecondaryButton
import ai.tokenstat.tokenstat.ui.localization.L10n
import ai.tokenstat.tokenstat.ui.terminal.TerminalScreen
import ai.tokenstat.tokenstat.ui.theme.Space
import androidx.compose.foundation.layout.*
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Modifier
import androidx.compose.ui.unit.dp
import androidx.compose.ui.window.Dialog
import androidx.compose.ui.window.DialogProperties
import androidx.lifecycle.viewModelScope
import kotlinx.coroutines.NonCancellable
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import kotlinx.serialization.json.*

@Composable
fun AgentSetupCard(model: AppViewModel, peer: String, hostLabel: String, backend: JsonObject,
                   running: Boolean, showWhenReady: Boolean = false,
                   /// The readiness, and whether the CLI itself gave it. Only a
                   /// confirmed answer may stop a send.
                   onReadiness: (String, Boolean) -> Unit) {
    val scope = rememberCoroutineScope()
    val id = backend["launcherId"]?.jsonPrimitive?.contentOrNull ?: return
    val backendId = backend["id"]?.jsonPrimitive?.contentOrNull
    val label = backend["label"]?.jsonPrimitive?.contentOrNull ?: id
    var readiness by remember(peer, id) { mutableStateOf(backend["readiness"]?.jsonPrimitive?.contentOrNull ?: "unknown") }
    var sessionId by remember(peer, id) { mutableStateOf<String?>(null) }
    var working by remember { mutableStateOf(false) }
    var error by remember { mutableStateOf<String?>(null) }
    var mounted by remember(peer, id) { mutableStateOf(true) }
    val signIn = backend["signIn"] as? JsonObject ?: when (id) {
        "claude_code", "codex" -> buildJsonObject { put("supported", true); put("kind", if (id == "codex") "deviceCode" else "browserCode") }
        else -> null
    }
    suspend fun close(session: String) {
        runCatching { model.workspaceSection(peer, "pty.close", buildJsonObject { put("id", session) }) }
    }
    DisposableEffect(peer, id) {
        onDispose {
            mounted = false
            sessionId?.let { session -> model.viewModelScope.launch { close(session) } }
        }
    }

    suspend fun check() {
        working = true
        runCatching {
            if (backend["canCheckSignIn"]?.jsonPrimitive?.booleanOrNull == true)
                model.workspaceSection(peer, "launcher.checkSignIn", buildJsonObject { put("id", id) }) as? JsonObject
            else (model.workspaceSection(peer, "chat.backends", buildJsonObject {}) as? JsonArray)
                ?.filterIsInstance<JsonObject>()?.firstOrNull { it["id"]?.jsonPrimitive?.contentOrNull == backendId }
        }
            .onSuccess {
                if (!mounted) return@onSuccess
                readiness = it?.get("readiness")?.jsonPrimitive?.contentOrNull ?: "unknown"
                onReadiness(readiness, it?.get("checked")?.jsonPrimitive?.booleanOrNull == true)
                error = null
            }.onFailure { error = it.message }
        working = false
    }
    LaunchedEffect(peer, id) {
        if (backend["canCheckSignIn"]?.jsonPrimitive?.booleanOrNull == true && backendId in listOf("claude", "claude_code", "codex")) check()
    }
    if (backend["installed"]?.jsonPrimitive?.booleanOrNull == false || backendId == "sh") return
    // Above the composer only a state with a next step shows. Agents whose
    // login nothing can read are always "unknown"; the setup panel still
    // shows every state.
    if (showWhenReady || readiness == "needsSignIn" || readiness == "expired") {
        Card(Modifier.fillMaxWidth()) {
            Column(Modifier.padding(Space.m), verticalArrangement = Arrangement.spacedBy(Space.s)) {
                Text(L10n.text("android.agentsetup.check_setup", label), style = MaterialTheme.typography.titleSmall)
                Text(L10n.text("android.agentsetup.remote"), style = MaterialTheme.typography.bodySmall)
                if (readiness == "unknown") Text(L10n.text("android.agentsetup.unknown"), style = MaterialTheme.typography.bodySmall)
                if (signIn?.get("supported")?.jsonPrimitive?.booleanOrNull == true) {
                    TsSecondaryButton(label = L10n.text("android.agentsetup.open_terminal"), icon = ActionIcon.SignIn.vector, small = true, enabled = !working && !running, onClick = {
                        scope.launch {
                            working = true
                            withContext(NonCancellable) {
                                runCatching { model.workspaceSection(peer, "launcher.signIn", buildJsonObject { put("id", id); put("rows", 24); put("cols", 80) }) as? JsonObject }
                                    .onSuccess { info ->
                                        info?.get("id")?.jsonPrimitive?.contentOrNull?.let { session ->
                                            if (mounted) sessionId = session else close(session)
                                        }
                                    }.onFailure { if (mounted) error = it.message }
                            }
                            working = false
                        }
                    })
                } else Text(L10n.text("android.agentsetup.legacy", label), style = MaterialTheme.typography.bodySmall)
                TsSecondaryButton(label = L10n.text("android.agentsetup.check_again"), icon = ActionIcon.Refresh.vector, small = true, enabled = !working && !running, onClick = { scope.launch { check() } })
                error?.let { Text(it, style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.error) }
            }
        }
    }
    sessionId?.let { session ->
        fun finish() {
            sessionId = null
            model.viewModelScope.launch {
                close(session)
                if (mounted) scope.launch { check() }
            }
        }
        Dialog(onDismissRequest = { finish() }, properties = DialogProperties(usePlatformDefaultWidth = false)) {
            Surface(Modifier.fillMaxSize()) {
                Column {
                    Column(Modifier.padding(16.dp), verticalArrangement = Arrangement.spacedBy(8.dp)) {
                        Text(L10n.text("android.agentsetup.setup_title", label), style = MaterialTheme.typography.titleMedium)
                        Text(L10n.text("android.agentsetup.step_open"), style = MaterialTheme.typography.bodySmall)
                        Text(if (signIn?.get("kind")?.jsonPrimitive?.contentOrNull == "deviceCode") L10n.text("android.agentsetup.step_device")
                             else if (signIn?.get("kind")?.jsonPrimitive?.contentOrNull == "browserCode") L10n.text("android.agentsetup.step_browser")
                             else L10n.text("android.agentsetup.step_cli"), style = MaterialTheme.typography.bodySmall)
                        Text(L10n.text("android.agentsetup.step_return"), style = MaterialTheme.typography.bodySmall)
                        TextButton(onClick = { finish() }) { Text(L10n.text("android.agentsetup.finished")) }
                    }
                    Box(Modifier.weight(1f)) {
                        TerminalScreen(model, peer, hostLabel, "", session, onClose = { finish() })
                    }
                }
            }
        }
    }
}
