// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
package ai.tokenstat.tokenstat.ui.workspace

import ai.tokenstat.tokenstat.ui.components.ActionIcon
import ai.tokenstat.tokenstat.ui.localization.L10n
import ai.tokenstat.tokenstat.ui.logic.ChatComposerSessions
import ai.tokenstat.tokenstat.AppViewModel
import ai.tokenstat.tokenstat.ui.logic.LaunchDefaults
import ai.tokenstat.tokenstat.ui.logic.SharedPrefsLaunchChoice
import ai.tokenstat.tokenstat.ui.theme.LocalTsColors
import ai.tokenstat.tokenstat.ui.theme.rememberReduceMotion
import androidx.compose.animation.core.*
import androidx.compose.foundation.Canvas
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.dp
import java.util.UUID
import java.util.concurrent.atomic.AtomicBoolean
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.contentOrNull
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.currentCoroutineContext
import kotlinx.coroutines.ensureActive

data class NewChatSetup(val backend: String, val model: String?, val effort: String?) {
    fun isAvailable(backends: List<JsonObject>): Boolean {
        val descriptor = backends.firstOrNull { it.newChatText("id") == backend } ?: return false
        return chatBackendOptions(backends).any { it.first == backend && backend != "sh" } &&
            (model == null || model in stringList(descriptor, "models")) && (effort == null || effort in stringList(descriptor, "efforts"))
    }
}

/** A Send intent is claimed once, even if navigation recreates its composition. */
class NewChatRequest(val peer: String, val workspace: String, val accountScope: String,
    val source: ChatComposerSessions.Capture<StagedAttachment>, val id: String = UUID.randomUUID().toString(), val setup: NewChatSetup? = null) {
    private val claimed = AtomicBoolean(false)
    val shouldSend get() = source.snapshot.text.isNotBlank() || source.snapshot.attachments.isNotEmpty()
    fun claim(currentAccount: String?, currentPeer: String, currentWorkspace: String) =
        currentAccount == accountScope && source.owner == "$accountScope|new-chat" && currentPeer == peer && currentWorkspace == workspace && claimed.compareAndSet(false, true)
}

private fun JsonObject.newChatText(key: String) = (this[key] as? JsonPrimitive)?.contentOrNull.orEmpty()
private fun newChatCopy(key: String): String { val resource = "common.new_chat.$key"; return L10n.text(resource) }

@Composable
fun NewChatScreen(
    model: AppViewModel, accountOwner: String?, initialSetup: NewChatSetup? = null, onSetup: (NewChatSetup?) -> Unit,
    draft: String, onDraft: (String) -> Unit, hosts: List<JsonObject>, connectedPeer: String?, connecting: Boolean,
    folders: List<JsonObject>, selectedRepository: String?, onRepository: (String) -> Unit,
    onHost: (JsonObject) -> Unit, onAdd: () -> Unit, onSend: () -> Unit, onClose: () -> Unit, error: String? = null,
    onManageDevices: () -> Unit = {},
) {
    val colors = LocalTsColors.current
    val context = LocalContext.current
    var backends by remember(accountOwner, connectedPeer) { mutableStateOf<List<JsonObject>>(emptyList()) }
    var setup by remember(accountOwner, connectedPeer) { mutableStateOf(initialSetup) }
    var setupError by remember(accountOwner, connectedPeer) { mutableStateOf<String?>(null) }
    var catalogAttempt by remember(accountOwner, connectedPeer) { mutableIntStateOf(0) }
    var catalogReady by remember(accountOwner, connectedPeer) { mutableStateOf(false) }
    var agentMenu by remember { mutableStateOf(false) }
    var modelMenu by remember { mutableStateOf(false) }
    LaunchedEffect(accountOwner, connectedPeer, catalogAttempt) {
        catalogReady = false
        setupError = null
        val peer = connectedPeer ?: return@LaunchedEffect
        try {
            val previous = setup
            backends = (model.workspaceSection(peer, "chat.backends", buildJsonObject {}) as? JsonArray).orEmpty().filterIsInstance<JsonObject>()
            currentCoroutineContext().ensureActive()
            val saved = SharedPrefsLaunchChoice(context).read()
            val backendId = previous?.backend?.takeIf { id -> chatBackendOptions(backends).any { it.first == id && id != "sh" } } ?: LaunchDefaults.backend(saved, backends)
            val backend = backends.firstOrNull { it.newChatText("id") == backendId }
            if (backend != null && chatBackendOptions(backends).any { it.first == backendId && it.first != "sh" }) {
                setup = if (previous?.backend == backendId && (previous.model == null || previous.model in stringList(backend, "models")) && (previous.effort == null || previous.effort in stringList(backend, "efforts")))
                    previous else NewChatSetup(backendId, LaunchDefaults.model(saved, backend), LaunchDefaults.effort(saved, backend))
                catalogReady = true
                onSetup(setup)
            }
            else setupError = L10n.text("android.chatagentpanel.no_agents_installed_set_up_an_agent_to_sta.2f73b57f")
        } catch (cancelled: CancellationException) { throw cancelled }
        catch (failure: Exception) { setupError = failure.message }
    }
    LaunchedEffect(setup) { onSetup(setup) }
    var hostMenu by remember { mutableStateOf(false) }
    var repositoryMenu by remember { mutableStateOf(false) }
    val selected = folders.firstOrNull { it.newChatText("id") == selectedRepository }
    val reduced = rememberReduceMotion()
    val phase = if (reduced) 0f else {
        val animation = rememberInfiniteTransition(label = "new-chat-ambient")
        animation.animateFloat(0f, 1f, infiniteRepeatable(tween(12000, easing = LinearEasing), RepeatMode.Reverse), label = "ambient-phase").value
    }
    Box(Modifier.fillMaxSize()) {
        Canvas(Modifier.fillMaxSize()) {
            val center = Offset(size.width * (.45f + phase * .1f), size.height * .35f)
            drawCircle(Brush.radialGradient(listOf(colors.accent.copy(alpha = .11f), Color.Transparent), center, size.width * .75f), size.width * .75f, center)
        }
        Column(Modifier.fillMaxSize().safeDrawingPadding().padding(20.dp).verticalScroll(rememberScrollState()),
            horizontalAlignment = Alignment.CenterHorizontally, verticalArrangement = Arrangement.Center) {
            Row(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.End) {
                IconButton(onClick = onClose) { Icon(ActionIcon.Dismiss.vector, L10n.text("common.close")) }
            }
            Column(Modifier.widthIn(max = 720.dp).fillMaxWidth(), horizontalAlignment = Alignment.CenterHorizontally,
                verticalArrangement = Arrangement.spacedBy(16.dp)) {
                Row(Modifier.height(44.dp), horizontalArrangement = Arrangement.spacedBy(5.dp), verticalAlignment = Alignment.CenterVertically) {
                    listOf(22, 36, 28).forEach { height -> Box(Modifier.width(7.dp).height(height.dp).background(colors.accent, RoundedCornerShape(3.dp))) }
                }
                Text(newChatCopy("title"), style = MaterialTheme.typography.headlineMedium, fontWeight = FontWeight.SemiBold, textAlign = TextAlign.Center)
                Text(newChatCopy("subtitle"), style = MaterialTheme.typography.bodyMedium, color = colors.textSecondary, textAlign = TextAlign.Center)
                Box(Modifier.fillMaxWidth()) {
                    OutlinedButton(onClick = { hostMenu = true }, enabled = !connecting, modifier = Modifier.fillMaxWidth()) {
                        Text(hosts.firstOrNull { it.newChatText("publicIdentity") == connectedPeer }?.newChatText("label")?.takeIf { it.isNotBlank() } ?: newChatCopy("choose_host"))
                    }
                    DropdownMenu(expanded = hostMenu, onDismissRequest = { hostMenu = false }) {
                        hosts.forEach { host -> DropdownMenuItem(text = { Text(host.newChatText("label")) }, onClick = { hostMenu = false; onHost(host) }) }
                        DropdownMenuItem(text = { Text(L10n.text("common.devices")) }, onClick = { hostMenu = false; onManageDevices() })
                    }
                }
                if (hosts.isEmpty()) TextButton(onClick = onManageDevices) { Text(L10n.text("common.devices")) }
                Box(Modifier.fillMaxWidth()) {
                    OutlinedButton(onClick = { repositoryMenu = true }, enabled = connectedPeer != null && !connecting,
                        modifier = Modifier.fillMaxWidth().testTag("newChat.repository")) {
                        Text(selected?.newChatText("name") ?: newChatCopy("choose_repository"))
                    }
                    DropdownMenu(expanded = repositoryMenu, onDismissRequest = { repositoryMenu = false }) {
                        folders.forEach { folder -> DropdownMenuItem(text = { Column { Text(folder.newChatText("name")); Text(folder.newChatText("path"), style = MaterialTheme.typography.labelSmall, color = colors.textSecondary) } },
                            onClick = { repositoryMenu = false; onRepository(folder.newChatText("id")) }) }
                    }
                }
                TextButton(onClick = onAdd, enabled = connectedPeer != null && !connecting) { Icon(ActionIcon.Create.vector, null, Modifier.size(16.dp)); Spacer(Modifier.width(6.dp)); Text(newChatCopy("add_repository")) }
                if (folders.isEmpty()) Text(newChatCopy("empty"), style = MaterialTheme.typography.bodySmall, color = colors.textSecondary)
                if (setup != null) Row(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                    val backend = backends.firstOrNull { it.newChatText("id") == setup?.backend }
                    Box(Modifier.weight(1f)) {
                        OutlinedButton(onClick = { agentMenu = true }, modifier = Modifier.fillMaxWidth()) { Text(L10n.text("android.chatagentpanel.agent.11b39c93") + ": " + (backend?.newChatText("label")?.takeIf { it.isNotBlank() } ?: setup!!.backend)) }
                        DropdownMenu(agentMenu, { agentMenu = false }) {
                            chatBackendOptions(backends).filter { it.first != "sh" }.forEach { (id, label) -> DropdownMenuItem(text = { Text(label) }, onClick = { setup = NewChatSetup(id, null, null); onSetup(setup); agentMenu = false }) }
                        }
                    }
                    Box(Modifier.weight(1f)) {
                        OutlinedButton(onClick = { modelMenu = true }, modifier = Modifier.fillMaxWidth()) { Text(L10n.text("android.chatagentpanel.model.5e2c614c") + ": " + (setup?.model ?: L10n.text("android.chatagentpanel.default.21b111cb"))) }
                        DropdownMenu(modelMenu, { modelMenu = false }) {
                            (listOf<String?>(null) + stringList(backend, "models")).forEach { name -> DropdownMenuItem(text = { Text(name ?: L10n.text("android.chatagentpanel.default.21b111cb")) }, onClick = { setup = setup?.copy(model = name); onSetup(setup); modelMenu = false }) }
                        }
                    }
                }
                OutlinedTextField(value = draft, onValueChange = onDraft, placeholder = { Text(newChatCopy("prompt")) },
                    minLines = 5, maxLines = 12, modifier = Modifier.fillMaxWidth().testTag("newChat.composer"), shape = RoundedCornerShape(16.dp))
                Button(onClick = onSend, enabled = connectedPeer != null && !connecting && selected != null && catalogReady && setup != null, modifier = Modifier.align(Alignment.End).testTag("newChat.send")) {
                    Icon(ActionIcon.Send.vector, null, Modifier.size(18.dp)); Spacer(Modifier.width(8.dp)); Text(newChatCopy(if (draft.isBlank()) "open_chat" else "send"))
                }
                if (connecting) CircularProgressIndicator(Modifier.size(20.dp), strokeWidth = 2.dp)
                error?.let { Text(it, style = MaterialTheme.typography.bodySmall, color = colors.danger) }
                setupError?.let {
                    Text(it, style = MaterialTheme.typography.bodySmall, color = colors.danger)
                    TextButton(onClick = { catalogAttempt++ }) { Text(L10n.text("common.retry")) }
                }
            }
        }
    }
}
