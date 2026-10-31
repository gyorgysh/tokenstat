// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
package ai.tokenstat.tokenstat.ui.workspace

import ai.tokenstat.tokenstat.AppViewModel
import ai.tokenstat.tokenstat.ui.NoComputerConnected
import ai.tokenstat.tokenstat.ui.chrome.HideTabBar
import ai.tokenstat.tokenstat.ui.chrome.HideTopBar
import ai.tokenstat.tokenstat.ui.components.*
import ai.tokenstat.tokenstat.ui.localization.L10n
import ai.tokenstat.tokenstat.ui.logic.ChatComposerSessions
import ai.tokenstat.tokenstat.ui.logic.LaunchDefaults
import ai.tokenstat.tokenstat.ui.logic.ProjectOwner
import ai.tokenstat.tokenstat.ui.logic.SharedPrefsLaunchChoice
import ai.tokenstat.tokenstat.ui.marks.LogoMark
import ai.tokenstat.tokenstat.ui.theme.LocalTsColors
import ai.tokenstat.tokenstat.ui.theme.Space
import androidx.activity.compose.BackHandler
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
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
    draft: String, staged: List<StagedAttachment>, onDraft: (String) -> Unit, hosts: List<JsonObject>, connectedPeer: String?, preferredPeer: String?, requestedPeer: String?, connecting: Boolean,
    folders: List<JsonObject>, selectedRepository: String?, onRepository: (String) -> Unit,
    onHost: (JsonObject) -> Unit, onAdd: () -> Unit, onSend: () -> Unit, onClose: () -> Unit, error: String? = null,
    onManageDevices: () -> Unit = {}, onSetupMachine: () -> Unit = onManageDevices,
) {
    BackHandler(onBack = onClose)
    HideTopBar()
    HideTabBar()
    val colors = LocalTsColors.current
    val context = LocalContext.current
    val scope = rememberCoroutineScope()
    var hostMenu by remember { mutableStateOf(false) }
    // The draft owner changes when a repository is chosen. Host selection
    // belongs to the account and must survive that change.
    var chosenPeer by rememberSaveable(accountScope) { mutableStateOf<String?>(null) }
    var requestedAttempted by remember(accountScope, requestedPeer) { mutableStateOf(false) }
    val effectivePeer = if (hosts.size > 1 && selectedRepository == null) {
        connectedPeer?.takeIf { it == chosenPeer }
    } else connectedPeer
    LaunchedEffect(hosts, selectedRepository, preferredPeer, requestedPeer, connectedPeer, connecting) {
        if (selectedRepository != null || requestedPeer == null && chosenPeer != null) return@LaunchedEffect
        val preferred = hosts.firstOrNull {
            it.newChatText("publicIdentity") == (requestedPeer ?: preferredPeer)
        }
        if (preferred != null) {
            if (chosenPeer != preferred.newChatText("publicIdentity")) chosenPeer = preferred.newChatText("publicIdentity")
            if (connectedPeer != chosenPeer && !connecting &&
                (requestedPeer == null || !requestedAttempted)) {
                if (requestedPeer != null) requestedAttempted = true
                onHost(preferred)
            }
        }
    }
    val savedChoice = remember(context, accountOwner) { SharedPrefsLaunchChoice(context).read() }
    val currentOwner by rememberUpdatedState(accountOwner)
    var backends by remember(accountOwner, effectivePeer) { mutableStateOf<List<JsonObject>>(emptyList()) }
    var setup by remember(accountOwner, effectivePeer) { mutableStateOf(initialSetup) }
    var setupError by remember(accountOwner) { mutableStateOf<String?>(null) }
    var attachError by remember(accountOwner) { mutableStateOf<String?>(null) }
    var catalogAttempt by remember(accountOwner) { mutableIntStateOf(0) }
    var catalogReady by remember(accountOwner) { mutableStateOf(false) }
    var agentMenu by remember(accountOwner) { mutableStateOf(false) }
    val inputLease = remember(accountOwner, effectivePeer) { ChatAttachmentInputLease(accountOwner) }
    val currentLease by rememberUpdatedState(inputLease)
    DisposableEffect(inputLease) { onDispose { inputLease.retire() } }
    var pickerLease by remember { mutableStateOf<ChatAttachmentInputLease?>(null) }
    var reading by remember(accountOwner) { mutableStateOf(false) }
    fun owns(owner: String?) = owner != null && owner == currentOwner &&
        ProjectOwner.from(model.state.value.account, "unselected", "new-chat")?.accountScope == accountScope
    fun importFiles(lease: ChatAttachmentInputLease, uris: List<android.net.Uri>, release: () -> Unit = {}) {
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
                    if (attachment == null) { attachError = (read as? AttachmentRead.Failed)?.reason; continue }
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
    val drops = chatAttachmentDrops(inputLease, selectedRepository != null && !connecting && !reading, ::importFiles)
    LaunchedEffect(accountOwner, effectivePeer, catalogAttempt) {
        catalogReady = false; setupError = null
        val peer = effectivePeer ?: return@LaunchedEffect
        try {
            val previous = setup
            backends = (model.workspaceSection(peer, "chat.backends", buildJsonObject {}) as? JsonArray).orEmpty().filterIsInstance<JsonObject>()
            currentCoroutineContext().ensureActive()
            val saved = savedChoice
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
    var repositoryMenu by remember { mutableStateOf(false) }
    val selected = folders.firstOrNull { it.newChatText("id") == selectedRepository }
    // Why Send cannot fire, in the same words and the same order as the Apple
    // page's `blockReason`. Without it the arrow is simply grey, and a written
    // message with a repository still unchosen looks like it was swallowed.
    val blockReason = when {
        connecting || reading -> null
        effectivePeer == null -> newChatCopy("choose_host")
        selected == null -> newChatCopy("needs_repository")
        !catalogReady -> newChatCopy("finding_agents")
        setup?.isAvailable(backends) != true -> newChatCopy("needs_agent")
        else -> null
    }
    val pageScroll = rememberScrollState()
    Box(Modifier.fillMaxSize().background(colors.background).then(drops)) {
        // The parent Scaffold already applies the system-bar insets. Adding
        // safeDrawingPadding here a second time pushed the form down and left
        // unused space above the header on a phone.
        Column(Modifier.fillMaxSize()) {
            // The way out holds its place at the top while the page under it
            // reflows. No keyboard button here: the app's own bar above this
            // page already grows one whenever the keyboard is up.
            Row(Modifier.fillMaxWidth().padding(horizontal = 20.dp, vertical = 8.dp),
                horizontalArrangement = Arrangement.SpaceBetween, verticalAlignment = Alignment.CenterVertically) {
                Text(L10n.text("android.tokenstatapp.new_chat.db18382a"), style = MaterialTheme.typography.titleMedium,
                    color = colors.textPrimary, fontWeight = FontWeight.SemiBold)
                IconButton(onClick = onClose, modifier = Modifier.size(48.dp)) {
                    Icon(ActionIcon.Dismiss.vector, L10n.text("common.close"), tint = colors.textPrimary)
                }
            }
            BoxWithConstraints(Modifier.weight(1f).fillMaxWidth()) {
                // What is left after the keyboard has taken its share, and
                // how much of the page's own name fits in it. Measured on a
                // phone: the mark, the question and the line under it come to
                // 136dp, and the two pickers and the composer under them to
                // 418dp. So the whole heading needs 560dp of room, and the
                // question on its own needs 480dp.
                val roomForHeading = maxHeight >= 560.dp
                val roomForTitle = maxHeight >= 480.dp
                Column(Modifier.fillMaxSize().verticalScroll(pageScroll).padding(horizontal = 20.dp, vertical = 8.dp),
                    horizontalAlignment = Alignment.CenterHorizontally,
                    // Centred in whatever room there is. Held against the
                    // keyboard instead, the short page left a third of the
                    // screen empty above it.
                    verticalArrangement = Arrangement.Center) {
                Column(Modifier.widthIn(max = 720.dp).fillMaxWidth(), horizontalAlignment = Alignment.CenterHorizontally,
                    verticalArrangement = Arrangement.spacedBy(16.dp)) {
                    // The page names itself with as much as the room allows,
                    // in steps rather than all or nothing: a keyboard that
                    // leaves most of the page still leaves room for the
                    // heading, and dropping it there was what left a third of
                    // the screen empty above the composer.
                    if (roomForHeading) LogoMark(size = 36)
                    if (roomForTitle) {
                        Text(newChatCopy("title"), style = MaterialTheme.typography.headlineSmall.copy(fontSize = 24.sp), fontWeight = FontWeight.Medium,
                            color = colors.textPrimary, textAlign = TextAlign.Center)
                    }
                    if (roomForHeading && hosts.isNotEmpty()) {
                        Text(newChatCopy("subtitle"), style = MaterialTheme.typography.bodyMedium, color = colors.textSecondary, textAlign = TextAlign.Center)
                    }
                    if (hosts.isEmpty() && draft.isBlank() && staged.isEmpty()) {
                        NoComputerConnected(onSetupMachine)
                    } else {
                        TsPickerField(
                            summary = hosts.firstOrNull { it.newChatText("publicIdentity") == (effectivePeer ?: chosenPeer) }
                                ?.newChatText("label")?.takeIf { it.isNotBlank() } ?: newChatCopy("choose_host"),
                            onOpen = { hostMenu = true }, enabled = !connecting,
                            maxLines = 1,
                            modifier = Modifier.fillMaxWidth(),
                        )
                        if (effectivePeer != null) {
                            val litRepository = !connecting && selected == null
                            Box(Modifier.fillMaxWidth()) {
                                TsPickerField(
                                    summary = selected?.newChatText("name") ?: newChatCopy("choose_repository"),
                                    onOpen = { repositoryMenu = true }, enabled = !connecting,
                                    maxLines = 1,
                                    modifier = Modifier.fillMaxWidth().testTag("newChat.repository"),
                                )
                                if (litRepository) Box(Modifier.matchParentSize().border(1.dp, colors.accent, RoundedCornerShape(Space.s)))
                            }
                            TextButton(onClick = onAdd, enabled = !connecting,
                                modifier = Modifier.align(Alignment.Start).heightIn(min = 48.dp)) {
                                Icon(ActionIcon.Create.vector, null, Modifier.size(18.dp))
                                Spacer(Modifier.width(6.dp))
                                Text(newChatCopy("add_repository"))
                            }
                        }
                        if (effectivePeer == null) {
                            Text(newChatCopy("connect_host_message"), style = MaterialTheme.typography.bodySmall, color = colors.textSecondary)
                        } else if (folders.isEmpty() && !connecting) {
                            Text(newChatCopy("empty"), style = MaterialTheme.typography.bodySmall, color = colors.textSecondary)
                        }
                        if (effectivePeer != null) ChatComposer(chat = setup?.chat(), draft = draft, onDraft = onDraft, hint = newChatCopy("prompt"), sending = false,
                            sendLabel = newChatCopy(if (draft.isBlank() && staged.isEmpty()) "open_chat" else "send"), staged = staged,
                            onPick = { pickerLease = inputLease; picker.launch(arrayOf("*/*")) },
                            onRemove = { attachment -> if (owns(accountOwner)) { val snapshot = model.chatComposers.snapshot(accountOwner); model.chatComposers.update(accountOwner, snapshot.copy(attachments = snapshot.attachments - attachment)) } },
                            onSend = onSend, onStop = {}, onChange = { field, value -> setup = setup?.changed(field, value, backends); onSetup(setup) },
                            backends = backends, onAgent = { agentMenu = true }, launchMode = setup?.mode ?: LaunchDefaults.MODE,
                            launchAutonomy = setup?.autonomy ?: LaunchDefaults.autonomy(savedChoice, bypassOnly = false),
                            allowEmpty = true, submitEnabled = effectivePeer != null && !connecting && selected != null && catalogReady && setup?.isAvailable(backends) == true && !reading,
                            attachmentEnabled = selected != null && !connecting && !reading, fieldModifier = Modifier.testTag("newChat.composer"), sendModifier = Modifier.testTag("newChat.send"))
                        if (reading || connecting) CircularProgressIndicator(Modifier.size(20.dp), strokeWidth = 2.dp)
                        (attachError ?: error)?.let { Text(it, style = MaterialTheme.typography.bodySmall, color = colors.danger) }
                        if (attachError == null && error == null && setupError == null) {
                            blockReason?.takeIf { effectivePeer != null }?.let {
                                Text(it, style = MaterialTheme.typography.bodySmall, color = colors.textSecondary,
                                    textAlign = TextAlign.Center, modifier = Modifier.testTag("newChat.blocked"))
                            }
                        }
                        setupError?.let {
                            Text(it, style = MaterialTheme.typography.bodySmall, color = colors.danger)
                            TextButton(onClick = { catalogAttempt++ }) { Text(L10n.text("common.retry")) }
                        }
                    }
                }
                }
            }
        }
    }
    if (hostMenu) TsPickerSheet(newChatCopy("choose_host"), { hostMenu = false }) {
        TsPickerOptionList(
            choices = hosts.map { PickerChoice(it, it.newChatText("label")) },
            isSelected = { it.newChatText("publicIdentity") == effectivePeer },
            prompt = newChatCopy("choose_host"),
            emptyMessage = newChatCopy("connect_host_message"),
            monospaced = false,
            pick = { host -> chosenPeer = host.newChatText("publicIdentity"); hostMenu = false; onHost(host) },
        )
        TextButton(onClick = { hostMenu = false; onManageDevices() },
            modifier = Modifier.fillMaxWidth().heightIn(min = 48.dp)) {
            Text(L10n.text("common.devices"))
        }
    }
    if (repositoryMenu) TsPickerSheet(newChatCopy("choose_repository"), { repositoryMenu = false }) {
        TsPickerOptionList(
            choices = folders.map { PickerChoice(it, it.newChatText("name"), it.newChatText("path")) },
            isSelected = { it.newChatText("id") == selectedRepository },
            prompt = newChatCopy("choose_repository"),
            emptyMessage = newChatCopy("empty"),
            monospaced = false,
            pick = { folder -> repositoryMenu = false; onRepository(folder.newChatText("id")) },
        )
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
