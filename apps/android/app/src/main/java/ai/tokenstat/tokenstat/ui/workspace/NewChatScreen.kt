// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
package ai.tokenstat.tokenstat.ui.workspace

import ai.tokenstat.tokenstat.AppViewModel
import ai.tokenstat.tokenstat.ui.components.*
import ai.tokenstat.tokenstat.ui.localization.L10n
import ai.tokenstat.tokenstat.ui.logic.ChatComposerSessions
import ai.tokenstat.tokenstat.ui.logic.LaunchDefaults
import ai.tokenstat.tokenstat.ui.logic.ProjectOwner
import ai.tokenstat.tokenstat.ui.logic.SharedPrefsLaunchChoice
import ai.tokenstat.tokenstat.ui.theme.LocalTsColors
import ai.tokenstat.tokenstat.ui.theme.rememberReduceMotion
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.animation.core.*
import androidx.compose.foundation.Canvas
import androidx.compose.foundation.background
import androidx.compose.foundation.draganddrop.dragAndDropTarget
import androidx.compose.foundation.gestures.awaitEachGesture
import androidx.compose.foundation.gestures.awaitFirstDown
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.geometry.Rect
import androidx.compose.ui.draganddrop.DragAndDropEvent
import androidx.compose.ui.draganddrop.DragAndDropTarget
import androidx.compose.ui.draganddrop.toAndroidDragEvent
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.drawscope.Stroke
import androidx.compose.ui.input.pointer.PointerEventPass
import androidx.compose.ui.input.pointer.changedToUpIgnoreConsumed
import androidx.compose.ui.input.pointer.pointerInput
import androidx.compose.ui.layout.LayoutCoordinates
import androidx.compose.ui.layout.boundsInRoot
import androidx.compose.ui.layout.onGloballyPositioned
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.dp
import java.util.UUID
import java.util.concurrent.atomic.AtomicBoolean
import kotlinx.coroutines.*
import kotlinx.serialization.json.*

/** All next-turn choices stay local until the explicit Send/Open chat action. */
data class NewChatSetup(val backend: String, val model: String?, val effort: String?,
    val mode: String = LaunchDefaults.MODE, val autonomy: String = LaunchDefaults.AUTONOMY, val fastMode: Boolean = false) {
    fun isAvailable(backends: List<JsonObject>): Boolean {
        val descriptor = backends.firstOrNull { it.newChatText("id") == backend } ?: return false
        return chatBackendOptions(backends).any { it.first == backend && backend != "sh" } &&
            (model == null || model in stringList(descriptor, "models")) && (effort == null || effort in stringList(descriptor, "efforts")) &&
            mode in listOf("plan", "execute") && autonomy in listOf("standard", "bypass") &&
            (!chatAgentForcesBypass(backends, backend) || autonomy == "bypass") &&
            (!fastMode || chatFastModeAvailable(model, descriptor["fastModeModels"] as? JsonArray, backend))
    }
    fun chat(): JsonObject = buildJsonObject {
        put("backend", backend); model?.let { put("model", it) }; effort?.let { put("effort", it) }
        put("mode", mode); put("autonomy", autonomy); put("fastMode", fastMode)
    }
    fun createParameters(workspace: String): JsonObject = JsonObject(chat() + ("workspaceId" to JsonPrimitive(workspace)))
    fun changed(field: String, value: String, backends: List<JsonObject>): NewChatSetup = when (field) {
        "backend" -> copy(backend = value, model = null, effort = null, fastMode = false,
            autonomy = if (chatAgentForcesBypass(backends, value)) "bypass" else autonomy)
        "model" -> copy(model = value.ifBlank { null }, fastMode = false)
        "effort" -> copy(effort = value.ifBlank { null })
        "mode" -> copy(mode = value)
        "autonomy" -> copy(autonomy = value)
        "fastMode" -> copy(fastMode = value == "true")
        else -> this
    }
}

/** An unbound prompt can be written before connecting; bound drafts never cross repositories. */
internal fun newChatDraftOwner(account: String?, peer: String?, workspace: String?): String? {
    if (account == null) return null
    if (peer.isNullOrBlank() || workspace.isNullOrBlank()) return "$account|new-chat"
    return "$account|new-chat|" + listOf(peer.lowercase(), workspace).joinToString("|") { "${it.length}:$it" }
}

internal fun adoptUnboundNewChatDraft(drafts: ChatComposerSessions<StagedAttachment>, account: String?, peer: String?, workspace: String?) {
    val source = drafts.capture(newChatDraftOwner(account, null, null))
    val target = newChatDraftOwner(account, peer, workspace) ?: return
    if (target == source.owner || source.snapshot.attachments.isNotEmpty() || drafts.hasWriting(target)) return
    if (drafts.update(target, source.snapshot)) drafts.clearIfUnchanged(source.owner, source)
}

/** A returning picker must belong to this visit, including after an A → B → A switch. */
internal class NewChatInputLease(val owner: String?) {
    private var active = true
    fun retire() { active = false }
    fun accepts(current: NewChatInputLease) = active && this === current && owner != null
}

/** A Send intent is claimed once, even if navigation recreates its composition. */
class NewChatRequest(val peer: String, val workspace: String, val accountScope: String,
    val source: ChatComposerSessions.Capture<StagedAttachment>, val id: String = UUID.randomUUID().toString(), val setup: NewChatSetup? = null) {
    private val claimed = AtomicBoolean(false)
    val shouldSend get() = source.snapshot.text.isNotBlank() || source.snapshot.attachments.isNotEmpty()
    fun claim(currentAccount: String?, currentPeer: String, currentWorkspace: String) =
        currentAccount == accountScope && source.owner == newChatDraftOwner(accountScope, peer, workspace) &&
            currentPeer == peer && currentWorkspace == workspace && claimed.compareAndSet(false, true)
    fun installInto(drafts: ChatComposerSessions<StagedAttachment>, target: String): Boolean {
        if (!claimed.get() || drafts.hasWriting(target) || !drafts.update(target, source.snapshot)) return false
        drafts.clearIfUnchanged(source.owner, source)
        return true
    }
}

private fun JsonObject.newChatText(key: String) = (this[key] as? JsonPrimitive)?.contentOrNull.orEmpty()
private fun newChatCopy(key: String): String { val resource = "common.new_chat.$key"; return L10n.text(resource) }

@Composable
fun NewChatScreen(
    model: AppViewModel, accountOwner: String?, accountScope: String?, initialSetup: NewChatSetup? = null, onSetup: (NewChatSetup?) -> Unit,
    draft: String, staged: List<StagedAttachment>, onDraft: (String) -> Unit, hosts: List<JsonObject>, connectedPeer: String?, connecting: Boolean,
    folders: List<JsonObject>, selectedRepository: String?, onRepository: (String) -> Unit,
    onHost: (JsonObject) -> Unit, onAdd: () -> Unit, onSend: () -> Unit, onClose: () -> Unit, error: String? = null,
    onManageDevices: () -> Unit = {},
) {
    val colors = LocalTsColors.current
    val context = LocalContext.current
    val scope = rememberCoroutineScope()
    val currentOwner by rememberUpdatedState(accountOwner)
    var backends by remember(accountOwner, connectedPeer) { mutableStateOf<List<JsonObject>>(emptyList()) }
    var setup by remember(accountOwner, connectedPeer) { mutableStateOf(initialSetup) }
    var setupError by remember(accountOwner) { mutableStateOf<String?>(null) }
    var attachError by remember(accountOwner) { mutableStateOf<String?>(null) }
    var catalogAttempt by remember(accountOwner) { mutableIntStateOf(0) }
    var catalogReady by remember(accountOwner) { mutableStateOf(false) }
    var agentMenu by remember(accountOwner) { mutableStateOf(false) }
    val inputLease = remember(accountOwner, connectedPeer) { NewChatInputLease(accountOwner) }
    val currentLease by rememberUpdatedState(inputLease)
    DisposableEffect(inputLease) { onDispose { inputLease.retire() } }
    var pickerLease by remember { mutableStateOf<NewChatInputLease?>(null) }
    var reading by remember(accountOwner) { mutableStateOf(false) }
    fun owns(owner: String?) = owner != null && owner == currentOwner &&
        ProjectOwner.from(model.state.value.account, "unselected", "new-chat")?.accountScope == accountScope
    fun importFiles(lease: NewChatInputLease, uris: List<android.net.Uri>, release: () -> Unit = {}) {
        if (uris.isEmpty() || !lease.accepts(currentLease) || !owns(lease.owner) || reading) { release(); return }
        // Enter the finally block before the first suspension so even immediate
        // navigation cancellation releases a cross-app drop's permission.
        scope.launch(start = CoroutineStart.UNDISPATCHED) {
            val owner = lease.owner
            reading = true; attachError = null
            try {
                for (uri in uris) {
                    if (!lease.accepts(currentLease) || !owns(owner)) return@launch
                    val before = model.chatComposers.snapshot(owner)
                    val remaining = FILE_MAX.toLong() - before.attachments.sumOf { it.bytes.toLong() }
                    if (before.attachments.size >= 20 || remaining <= 0) {
                        attachError = L10n.text("android.chatpullssections.send_or_remove_the_staged_files_before_add.40e8ba5e"); break
                    }
                    var read: AttachmentRead? = null
                    try {
                        withContext(Dispatchers.IO) { read = readAttachment(context, uri, minOf(FILE_MAX.toLong(), remaining).toInt()) }
                    } catch (cancelled: CancellationException) {
                        (read as? AttachmentRead.Ok)?.attachment?.filePath?.let { java.io.File(it).delete() }; throw cancelled
                    }
                    val attachment = (read as? AttachmentRead.Ok)?.attachment
                    if (!lease.accepts(currentLease) || !owns(owner)) { attachment?.filePath?.let { java.io.File(it).delete() }; return@launch }
                    if (attachment == null) { attachError = (read as? AttachmentRead.Failed)?.reason; break }
                    val now = model.chatComposers.snapshot(owner)
                    if (now.attachments.size >= 20 || now.attachments.sumOf { it.bytes.toLong() } + attachment.bytes > FILE_MAX ||
                        !model.chatComposers.update(owner, now.copy(attachments = now.attachments + attachment))) {
                        attachment.filePath?.let { java.io.File(it).delete() }
                        attachError = model.chatComposers.failure.value?.takeIf { it.owner == owner }?.message
                            ?: L10n.text("android.chatpullssections.send_or_remove_the_staged_files_before_add.40e8ba5e")
                        break
                    }
                }
            } finally { release(); if (lease.accepts(currentLease) && owns(owner)) reading = false }
        }
    }
    val picker = rememberLauncherForActivityResult(ActivityResultContracts.OpenMultipleDocuments()) { uris ->
        val lease = pickerLease
        pickerLease = null
        if (lease != null) importFiles(lease, uris.orEmpty())
    }
    val receiveFiles by rememberUpdatedState(::importFiles)
    val dropEnabled by rememberUpdatedState(selectedRepository != null && !connecting && !reading)
    val dropTarget = remember(context, inputLease) {
        object : DragAndDropTarget {
            override fun onDrop(event: DragAndDropEvent): Boolean {
                if (!dropEnabled || !inputLease.accepts(currentLease) || !owns(inputLease.owner)) return false
                val native = event.toAndroidDragEvent()
                val clip = native.clipData ?: return false
                val uris = (0 until clip.itemCount).mapNotNull { clip.getItemAt(it).uri }
                    .filter { it.scheme == "content" || it.scheme == "file" }
                if (uris.isEmpty()) return false
                val activity = generateSequence(context) { (it as? android.content.ContextWrapper)?.baseContext }
                    .filterIsInstance<android.app.Activity>().firstOrNull()
                val permission = activity?.requestDragAndDropPermissions(native)
                receiveFiles(inputLease, uris) { permission?.release() }
                return true
            }
        }
    }
    LaunchedEffect(accountOwner, connectedPeer, catalogAttempt) {
        catalogReady = false; setupError = null
        val peer = connectedPeer ?: return@LaunchedEffect
        try {
            val previous = setup
            backends = (model.workspaceSection(peer, "chat.backends", buildJsonObject {}) as? JsonArray).orEmpty().filterIsInstance<JsonObject>()
            currentCoroutineContext().ensureActive()
            val saved = SharedPrefsLaunchChoice(context).read()
            val backendId = previous?.backend?.takeIf { id -> chatBackendOptions(backends).any { it.first == id && id != "sh" } } ?: LaunchDefaults.backend(saved, backends)
            val backend = backends.firstOrNull { it.newChatText("id") == backendId }
            if (backend != null && chatBackendOptions(backends).any { it.first == backendId && it.first != "sh" }) {
                setup = previous?.takeIf { it.isAvailable(backends) } ?: NewChatSetup(backendId, LaunchDefaults.model(saved, backend), LaunchDefaults.effort(saved, backend),
                    LaunchDefaults.mode(saved), LaunchDefaults.autonomy(saved, chatAgentForcesBypass(backends, backendId)))
                catalogReady = true; onSetup(setup)
            } else setupError = L10n.text("android.chatagentpanel.no_agents_installed_set_up_an_agent_to_sta.2f73b57f")
        } catch (cancelled: CancellationException) { throw cancelled }
        catch (failure: Exception) { setupError = failure.message }
    }
    LaunchedEffect(setup) { onSetup(setup) }
    var hostMenu by remember { mutableStateOf(false) }
    var repositoryMenu by remember { mutableStateOf(false) }
    val selected = folders.firstOrNull { it.newChatText("id") == selectedRepository }
    val reduced = rememberReduceMotion()
    val wave = remember(accountOwner) { Animatable(1f) }
    var waveCenter by remember(accountOwner) { mutableStateOf(Offset.Zero) }
    var waveJob by remember(accountOwner) { mutableStateOf<Job?>(null) }
    var rootCoordinates by remember { mutableStateOf<LayoutCoordinates?>(null) }
    var contentBounds by remember { mutableStateOf<Rect?>(null) }
    val phase = if (reduced) 0f else {
        val animation = rememberInfiniteTransition(label = "new-chat-ambient")
        animation.animateFloat(0f, 1f, infiniteRepeatable(tween(12000, easing = LinearEasing), RepeatMode.Reverse), label = "ambient-phase").value
    }
    // Observe the final pass without consuming anything. Text fields, buttons,
    // pickers and scrolling keep their own input; only unused background taps ripple.
    Box(Modifier.fillMaxSize().onGloballyPositioned { rootCoordinates = it }.dragAndDropTarget(
        shouldStartDragAndDrop = { dropEnabled && inputLease.accepts(currentLease) }, target = dropTarget,
    ).pointerInput(reduced, accountOwner) {
        if (!reduced) awaitEachGesture {
            val down = awaitFirstDown(requireUnconsumed = false, pass = PointerEventPass.Final)
            val rootPoint = rootCoordinates?.takeIf { it.isAttached }?.localToRoot(down.position)
            var background = !down.isConsumed && rootPoint != null && contentBounds?.contains(rootPoint) == false
            do {
                val event = awaitPointerEvent(PointerEventPass.Final)
                if (event.changes.any { it.isConsumed || (it.position - down.position).getDistance() > viewConfiguration.touchSlop }) background = false
                if (background && event.changes.any { it.changedToUpIgnoreConsumed() }) {
                    waveCenter = down.position; waveJob?.cancel()
                    waveJob = scope.launch { wave.snapTo(0f); wave.animateTo(1f, tween(1300, easing = FastOutSlowInEasing)) }
                }
            } while (event.changes.any { it.pressed })
        }
    }) {
        Canvas(Modifier.fillMaxSize()) {
            val center = Offset(size.width * (.45f + phase * .1f), size.height * .35f)
            drawCircle(Brush.radialGradient(listOf(colors.accent.copy(alpha = .11f), Color.Transparent), center, size.width * .75f), size.width * .75f, center)
            if (!reduced && wave.value < 1f) drawCircle(colors.accent.copy(alpha = .12f * (1f - wave.value)),
                radius = 12.dp.toPx() + wave.value * size.maxDimension * .8f, center = waveCenter, style = Stroke(1.5.dp.toPx()))
        }
        Column(Modifier.fillMaxSize().safeDrawingPadding().padding(20.dp).verticalScroll(rememberScrollState()),
            horizontalAlignment = Alignment.CenterHorizontally, verticalArrangement = Arrangement.Center) {
            Row(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.End) {
                IconButton(onClick = onClose) { Icon(ActionIcon.Dismiss.vector, L10n.text("common.close")) }
            }
            Column(Modifier.widthIn(max = 720.dp).fillMaxWidth().onGloballyPositioned { contentBounds = it.boundsInRoot() }, horizontalAlignment = Alignment.CenterHorizontally,
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
                ChatComposer(chat = setup?.chat(), draft = draft, onDraft = onDraft, hint = newChatCopy("prompt"), sending = false,
                    sendLabel = newChatCopy(if (draft.isBlank() && staged.isEmpty()) "open_chat" else "send"), staged = staged,
                    onPick = { pickerLease = inputLease; picker.launch(arrayOf("*/*")) },
                    onRemove = { attachment -> if (owns(accountOwner)) { val snapshot = model.chatComposers.snapshot(accountOwner); model.chatComposers.update(accountOwner, snapshot.copy(attachments = snapshot.attachments - attachment)) } },
                    onSend = onSend, onStop = {}, onChange = { field, value -> setup = setup?.changed(field, value, backends); onSetup(setup) },
                    backends = backends, onAgent = { agentMenu = true }, launchMode = setup?.mode ?: LaunchDefaults.MODE,
                    allowEmpty = true, submitEnabled = connectedPeer != null && !connecting && selected != null && catalogReady && setup?.isAvailable(backends) == true && !reading,
                    attachmentEnabled = selected != null && !connecting && !reading, fieldModifier = Modifier.testTag("newChat.composer"), sendModifier = Modifier.testTag("newChat.send"))
                if (reading || connecting) CircularProgressIndicator(Modifier.size(20.dp), strokeWidth = 2.dp)
                (attachError ?: error)?.let { Text(it, style = MaterialTheme.typography.bodySmall, color = colors.danger) }
                setupError?.let {
                    Text(it, style = MaterialTheme.typography.bodySmall, color = colors.danger)
                    TextButton(onClick = { catalogAttempt++ }) { Text(L10n.text("common.retry")) }
                }
            }
        }
    }
    if (agentMenu) {
        val chat = setup?.chat()
        val choices = chatAgentChoices(backends.filter { it.newChatText("id") != "sh" }, chat)
        TsPickerSheet(L10n.text("android.chatagentpanel.agent_model_and_effort.217ff8ae"), { agentMenu = false }) {
            TsPickerOptionList(choices, { chatAgentIsSelected(it, chat) },
                L10n.text("android.chatagentpanel.filter_agents_models_and_efforts.315032da"),
                L10n.text("android.chatagentpanel.no_agents_installed_set_up_an_agent_to_sta.2f73b57f"),
                pick = { choice -> val (field, value) = chatAgentField(choice); setup = setup?.changed(field, value, backends); onSetup(setup) },
                sectionValue = { chatAgentSectionValue(it, backends, chat) }, sectionTabs = chatAgentSections(choices), selectionSummary = chatAgentSummary(backends, chat),
                onRefresh = { catalogAttempt++ })
        }
    }
}
