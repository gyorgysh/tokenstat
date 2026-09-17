// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
package ai.tokenstat.tokenstat.ui.workspace

import androidx.compose.material3.Surface
import androidx.compose.foundation.layout.fillMaxHeight

import ai.tokenstat.tokenstat.ui.marks.EmptyArt
import ai.tokenstat.tokenstat.ui.marks.EmptyArtKind
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.foundation.layout.height

import ai.tokenstat.tokenstat.ui.chrome.HideTabBar
import ai.tokenstat.tokenstat.ui.chrome.OwnSectionHeader
import androidx.compose.foundation.border
import ai.tokenstat.tokenstat.ui.chrome.TabBarChrome
import android.provider.OpenableColumns
import android.util.Base64
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.material.icons.automirrored.filled.ArrowBack
import androidx.compose.material3.IconButton
import androidx.compose.ui.platform.LocalContext
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import androidx.compose.foundation.Canvas
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.KeyboardArrowRight
import androidx.compose.material.icons.filled.Bolt
import androidx.compose.material.icons.filled.ChatBubbleOutline
import androidx.compose.material.icons.filled.Check
import androidx.compose.material.icons.filled.Delete
import androidx.compose.material.icons.filled.Person
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.Card
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.DropdownMenu
import androidx.compose.material3.DropdownMenuItem
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.Icon
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.SwipeToDismissBox
import androidx.compose.material3.SwipeToDismissBoxValue
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.material3.rememberSwipeToDismissBoxState
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.text.TextStyle
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.compose.ui.window.Dialog
import androidx.compose.ui.window.DialogProperties
import ai.tokenstat.tokenstat.AppViewModel
import ai.tokenstat.tokenstat.ui.marks.HarnessMark
import ai.tokenstat.tokenstat.ui.persona.PersonaSheet
import ai.tokenstat.tokenstat.ui.components.ActionIcon
import ai.tokenstat.tokenstat.ui.components.Banner
import ai.tokenstat.tokenstat.ui.components.BannerSeverity
import ai.tokenstat.tokenstat.ui.components.EmptyState
import ai.tokenstat.tokenstat.ui.components.RelativeTimeText
import ai.tokenstat.tokenstat.ui.components.SectionLabel
import ai.tokenstat.tokenstat.ui.components.TsAccentButton
import ai.tokenstat.tokenstat.ui.components.TsBrandSwitch
import ai.tokenstat.tokenstat.ui.components.TsCard
import ai.tokenstat.tokenstat.ui.components.TsSecondaryButton
import ai.tokenstat.tokenstat.ui.components.TsSearchField
import ai.tokenstat.tokenstat.ui.components.TsType
import ai.tokenstat.tokenstat.ui.components.cardRadiusDp
import ai.tokenstat.tokenstat.ui.logic.HostContracts
import ai.tokenstat.tokenstat.ui.logic.TunnelCopy
import ai.tokenstat.tokenstat.ui.logic.friendlyError
import ai.tokenstat.tokenstat.ui.logic.harnessName
import ai.tokenstat.tokenstat.ui.theme.LocalTsColors
import ai.tokenstat.tokenstat.ui.theme.Space
import kotlinx.coroutines.launch
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.contentOrNull
import kotlinx.serialization.json.jsonPrimitive
import kotlinx.serialization.json.longOrNull
import kotlinx.serialization.json.put

/// `str` comes from the shared workspace readers in `WorkspaceSections.kt`.

@Composable
fun ChatSection(
    model: AppViewModel,
    peer: String,
    workspace: String,
    protocol: Long?,
    modifier: Modifier = Modifier,
    folderName: String = "",
    hostLabel: String = "",
    onChatOpened: (String) -> Unit = {},
    initialChatId: String? = null,
    openConversationOnAppear: Boolean = false,
    conversationNonce: Int = 0,
) {
    val scope = rememberCoroutineScope()
    var chats by remember(workspace) { mutableStateOf<List<JsonObject>>(emptyList()) }
    var openId by remember(workspace) { mutableStateOf<String?>(null) }
    var creating by remember(workspace) { mutableStateOf(false) }
    var didOpenConversation by remember(workspace, openConversationOnAppear, conversationNonce) { mutableStateOf(false) }
    var events by remember(workspace) { mutableStateOf<List<JsonObject>>(emptyList()) }
    var approvals by remember(workspace) { mutableStateOf<List<JsonObject>>(emptyList()) }
    var error by remember(workspace) { mutableStateOf<String?>(null) }
    var loading by remember(workspace) { mutableStateOf(true) }
    var draft by remember(workspace) { mutableStateOf("") }
    var sending by remember { mutableStateOf(false) }
    var sendError by remember(workspace) { mutableStateOf<String?>(null) }
    var actionError by remember(workspace) { mutableStateOf<String?>(null) }
    var eventsError by remember(workspace) { mutableStateOf<String?>(null) }
    var search by remember { mutableStateOf("") }
    var agentFilter by remember { mutableStateOf("") }
    var runningOnly by remember { mutableStateOf(false) }
    var alphabetical by remember { mutableStateOf(false) }
    var filterOpen by remember { mutableStateOf(false) }
    var pendingDelete by remember { mutableStateOf<JsonObject?>(null) }
    var pendingSend by remember { mutableStateOf<String?>(null) }
    var showingSetup by remember { mutableStateOf(false) }
    // Files chosen but not sent yet. They go up with the message rather than
    // on pick, so removing one before sending costs the host nothing.
    var staged by remember(workspace) { mutableStateOf<List<StagedAttachment>>(emptyList()) }
    var attachError by remember(workspace) { mutableStateOf<String?>(null) }
    val context = LocalContext.current
    // The document picker, which needs no storage permission: the user hands
    // us one file at a time and nothing else on the device is readable.
    val picker = rememberLauncherForActivityResult(
        ActivityResultContracts.OpenMultipleDocuments(),
    ) { uris ->
        if (uris.isNullOrEmpty()) return@rememberLauncherForActivityResult
        scope.launch {
            val read = withContext(Dispatchers.IO) { uris.map { readAttachment(context, it) } }
            staged = staged + read.filterIsInstance<AttachmentRead.Ok>().map { it.attachment }
            attachError = read.filterIsInstance<AttachmentRead.Failed>().firstOrNull()?.reason
        }
    }

    suspend fun loadChats() {
        loading = true
        runCatching {
            model.workspaceSection(peer, "chat.list", buildJsonObject { put("workspaceId", workspace) })
        }.onSuccess {
            chats = (it as? JsonArray)?.filterIsInstance<JsonObject>() ?: emptyList()
            error = null
        }.onFailure { error = friendlyError(it.message).message }
        loading = false
    }
    suspend fun loadEvents(id: String) {
        runCatching {
            model.workspaceSection(peer, "chat.events", buildJsonObject {
                put("id", id); put("offset", 0L)
            })
        }.onSuccess {
            val arr = (it as? JsonObject)?.get("events") as? JsonArray
                ?: (it as? JsonArray)
            events = arr?.filterIsInstance<JsonObject>() ?: emptyList()
            eventsError = null
        }.onFailure {
            // The poll retries on its own; the card says so and stays until
            // a poll lands or the person puts it away.
            if (eventsError == null) {
                eventsError = TunnelCopy.display(it.message ?: "The request failed.", hostLabel.ifBlank { "the host" }) +
                    " Still trying."
            }
        }
        runCatching {
            model.workspaceSection(peer, "chat.approvals", buildJsonObject { put("id", id) })
        }.onSuccess {
            approvals = (it as? JsonArray)?.filterIsInstance<JsonObject>() ?: emptyList()
        }
    }
    // Create, then open what was created. A "New chat" button that lands
    // back on the list created the chat and hid it in the same motion.
    suspend fun createAndOpen() {
        if (creating) return
        creating = true
        runCatching {
            model.workspaceSection(peer, "chat.create", buildJsonObject {
                put("workspaceId", workspace); put("backend", "opencode")
            }) as? JsonObject
        }.onSuccess { created ->
            val id = created?.str("id")
            loadChats()
            openId = id ?: chats.maxByOrNull {
                (it["updatedAtMs"] as? JsonPrimitive)?.longOrNull ?: 0L
            }?.str("id")
        }.onFailure { error = friendlyError(it.message).message }
        creating = false
    }
    suspend fun send(text: String) {
        val id = openId ?: return
        val clean = text.trim()
        if (clean.isEmpty() || sending) return
        sending = true
        try {
            val messageId = java.util.UUID.randomUUID().toString()
            // Uploaded first, and only then sent: a message that names a file
            // the host does not have yet is worse than a slower send. A
            // refused attachment stops the send with the draft intact.
            for (attachment in staged) {
                val uploaded = runCatching {
                    model.workspaceSection(peer, "chat.attach", buildJsonObject {
                        put("id", id)
                        put("name", attachment.name)
                        put("data", attachment.data)
                        attachment.mediaType?.let { put("mediaType", it) }
                    })
                }
                if (uploaded.isFailure) {
                    attachError = TunnelCopy.display(
                        uploaded.exceptionOrNull()?.message ?: "The attachment could not be sent.",
                        hostLabel.ifBlank { "the host" },
                    )
                    return
                }
            }
            runCatching {
                model.workspaceSection(peer, "chat.send", buildJsonObject {
                    put("id", id); put("text", clean)
                    put("clientMessageId", messageId)
                    put("clientMessageCreatedAtMs", System.currentTimeMillis())
                })
            }.onSuccess {
                draft = ""
                staged = emptyList()
                attachError = null
                sendError = null
                pendingSend = null
                loadEvents(id)
            }.onFailure {
                // The draft stays. Recovery is Retry below, or Check delivery
                // first when the send may have landed unseen.
                pendingSend = messageId
                sendError = TunnelCopy.display(it.message ?: "The request failed.", hostLabel.ifBlank { "the host" })
            }
        } finally {
            sending = false
        }
    }
    suspend fun checkDelivery() {
        val id = openId ?: return
        val messageId = pendingSend ?: return
        runCatching {
            model.workspaceSection(peer, "chat.receipt", buildJsonObject {
                put("id", id); put("clientMessageId", messageId)
            }) as? JsonObject
        }.onSuccess { receipt ->
            if ((receipt?.str("state") ?: "unknown") != "unknown") {
                pendingSend = null
                sendError = null
                loadEvents(id)
            } else {
                sendError = "Delivery cannot be confirmed yet. The message may still arrive; check the conversation before sending it again."
            }
        }.onFailure {
            sendError = TunnelCopy.display(it.message ?: "The request failed.", hostLabel.ifBlank { "the host" })
        }
    }
    LaunchedEffect(workspace) { loadChats() }
    // A navigation that named a conversation: open exactly it, even when
    // this folder's list is already on screen.
    LaunchedEffect(initialChatId, workspace) {
        if (initialChatId != null) openId = initialChatId
    }
    // The launcher's promise: arriving to start work opens the conversation
    // worth returning to, or starts one when there is none.
    LaunchedEffect(loading, openConversationOnAppear, conversationNonce) {
        if (!openConversationOnAppear || didOpenConversation || loading || error != null) return@LaunchedEffect
        didOpenConversation = true
        if (chats.isEmpty()) {
            createAndOpen()
        } else {
            openId = chats.maxByOrNull {
                (it["updatedAtMs"] as? JsonPrimitive)?.longOrNull ?: 0L
            }?.str("id")
        }
    }
    LaunchedEffect(openId) {
        val id = openId ?: return@LaunchedEffect
        onChatOpened(id)
        while (true) {
            loadEvents(id)
            kotlinx.coroutines.delay(2000)
        }
    }

    val place = folderName.ifBlank { "this folder" }

    Column(modifier, verticalArrangement = Arrangement.spacedBy(8.dp)) {
        // Only the list wears the section label. A conversation is a screen
        // of its own and carries its own title.
        if (openId == null) SectionLabel("Conversations")
        if (!HostContracts.supportsChat(protocol)) {
            Text("Update the host to use chat (needs protocol 4).", style = MaterialTheme.typography.bodySmall)
            return
        }
        if (error != null) {
            StickyErrorCard(
                message = error!!,
                onRetry = { scope.launch { loadChats() } },
                onDismiss = { error = null },
            )
        }
        if (openId == null) {
            // Both as buttons on one baseline. A bordered chip beside a bare
            // text link, each sized by a different rule, sat at two
            // different heights and read as a mistake.
            Row(
                horizontalArrangement = Arrangement.spacedBy(Space.s),
                verticalAlignment = Alignment.CenterVertically,
            ) {
                TsAccentButton(
                    label = if (creating) "Starting…" else "New chat",
                    icon = ActionIcon.Create.vector,
                    small = true,
                    enabled = !creating,
                    onClick = { scope.launch { createAndOpen() } },
                )
                TsSecondaryButton(
                    label = "Refresh",
                    icon = ActionIcon.Refresh.vector,
                    small = true,
                    onClick = { scope.launch { loadChats() } },
                )
            }
            if (loading) { CircularProgressIndicator(Modifier, strokeWidth = 2.dp); return }
            if (chats.isEmpty()) {
                EmptyState(
                    Icons.Default.ChatBubbleOutline,
                    "Start a chat",
                    "Ask an agent to explore, plan, or work in $place.",
                    action = {
                        TsAccentButton(
                            label = if (creating) "Starting…" else "New chat",
                            small = true,
                            enabled = !creating,
                            onClick = { scope.launch { createAndOpen() } },
                        )
                    },
                )
                return
            }
            TsSearchField(prompt = "Titles, agents, or models", query = search, onQueryChange = { search = it }, modifier = Modifier.fillMaxWidth())
            ChatStatPanels(chats)
            val query = search.trim()
            val agentIds = chats.mapNotNull { it.str("backend") }.toSortedSet()
            val filtered = chats.filter {
                (query.isEmpty() ||
                    (it.str("title") ?: "").contains(query, ignoreCase = true) ||
                    (it.str("backend") ?: "").contains(query, ignoreCase = true) ||
                    (it.str("model") ?: "").contains(query, ignoreCase = true)) &&
                    (agentFilter.isEmpty() || it.str("backend") == agentFilter) &&
                    (!runningOnly || it.bol("running"))
            }
            val shown = if (alphabetical) filtered.sortedBy { (it.str("title") ?: "").lowercase() } else filtered
            Row(
                Modifier.fillMaxWidth(),
                horizontalArrangement = Arrangement.SpaceBetween,
                verticalAlignment = Alignment.CenterVertically,
            ) {
                Box {
                    TsSecondaryButton(
                        label = "Filter & sort",
                        icon = ActionIcon.Filter.vector,
                        small = true,
                        onClick = { filterOpen = true },
                    )
                    DropdownMenu(expanded = filterOpen, onDismissRequest = { filterOpen = false }) {
                        ChatAgentMenuItem("All agents", agentFilter.isEmpty()) { agentFilter = ""; filterOpen = false }
                        agentIds.forEach { backend ->
                            ChatAgentMenuItem(harnessName(backend), agentFilter == backend) {
                                agentFilter = backend; filterOpen = false
                            }
                        }
                        HorizontalDivider()
                        DropdownMenuItem(
                            text = { Text("Running only") },
                            trailingIcon = { TsBrandSwitch(runningOnly, { runningOnly = it }) },
                            onClick = { runningOnly = !runningOnly; filterOpen = false },
                        )
                        HorizontalDivider()
                        ChatAgentMenuItem("Recent first", !alphabetical) { alphabetical = false; filterOpen = false }
                        ChatAgentMenuItem("Title A–Z", alphabetical) { alphabetical = true; filterOpen = false }
                    }
                }
                Text(
                    "${shown.size} shown",
                    style = TextStyle(fontSize = 12.sp),
                    color = LocalTsColors.current.textSecondary,
                )
            }
            if (shown.isEmpty()) {
                Text("No matching conversations. Adjust your search or filters.", style = MaterialTheme.typography.bodySmall)
                return
            }
            LazyColumn(contentPadding = PaddingValues(bottom = TabBarChrome.contentBottomInset), verticalArrangement = Arrangement.spacedBy(6.dp)) {
                items(shown, key = { it.str("id") ?: it.hashCode().toString() }) { chat ->
                    val dismiss = rememberSwipeToDismissBoxState(
                        confirmValueChange = { value ->
                            if (value != SwipeToDismissBoxValue.Settled) pendingDelete = chat
                            false
                        },
                    )
                    SwipeToDismissBox(
                        state = dismiss,
                        enableDismissFromStartToEnd = false,
                        backgroundContent = {
                            Box(
                                Modifier
                                    .fillMaxSize()
                                    .clip(RoundedCornerShape(cardRadiusDp))
                                    .background(LocalTsColors.current.danger)
                                    .padding(16.dp),
                                contentAlignment = Alignment.CenterEnd,
                            ) {
                                Icon(Icons.Default.Delete, null, tint = Color.White)
                            }
                        },
                    ) {
                        TsCard(Modifier.fillMaxWidth().clickable { openId = chat.str("id") }) {
                            ChatRow(chat)
                        }
                    }
                }
            }
        } else {
            // A conversation is a push, not a tab: the bar goes away and Back
            // is the way out, which is what `clientTabBarHidden` does on iOS.
            // Claimed by the composition, so every exit restores it.
            HideTabBar()
            // And the header: the section above only knows it is "Chat",
            // while this knows which conversation. Two headers with two back
            // arrows is what stacking them looked like.
            OwnSectionHeader()
            Row(
                verticalAlignment = Alignment.CenterVertically,
                modifier = Modifier.fillMaxWidth(),
            ) {
                IconButton(onClick = { openId = null; scope.launch { loadChats() } }) {
                    Icon(
                        Icons.AutoMirrored.Filled.ArrowBack,
                        "All conversations",
                        tint = LocalTsColors.current.textPrimary,
                    )
                }
                Column(Modifier.weight(1f)) {
                    Text(
                        chats.firstOrNull { it.str("id") == openId }?.str("title")?.ifBlank { null }
                            ?: "New chat",
                        style = MaterialTheme.typography.headlineSmall,
                        color = LocalTsColors.current.textPrimary,
                        maxLines = 1,
                        overflow = TextOverflow.Ellipsis,
                    )
                    Text(
                        folderName.ifBlank { "Conversation" },
                        style = MaterialTheme.typography.bodySmall,
                        color = LocalTsColors.current.textSecondary,
                        maxLines = 1,
                        overflow = TextOverflow.Ellipsis,
                    )
                }
                IconButton(onClick = { showingSetup = true }) {
                    Icon(
                        ActionIcon.Settings.vector,
                        "Chat setup",
                        tint = LocalTsColors.current.accent,
                    )
                }
            }
            if (actionError != null) {
                StickyErrorCard(
                    message = actionError!!,
                    onDismiss = { actionError = null },
                )
            }
            if (eventsError != null) {
                StickyErrorCard(
                    message = eventsError!!,
                    onDismiss = { eventsError = null },
                )
            }
            val pending = approvals.filter { it.str("decision").isNullOrBlank() }
            pending.forEach { approval ->
                ApprovalCard(
                    approval = approval,
                    onResolve = { choice ->
                        scope.launch {
                            runCatching {
                                model.workspaceSection(peer, "chat.resolveApproval", buildJsonObject {
                                    put("id", approval.str("id") ?: "")
                                    put("choice", choice)
                                })
                            }.onSuccess {
                                actionError = null
                                openId?.let { loadEvents(it) }
                            }.onFailure {
                                actionError = TunnelCopy.display(it.message ?: "The request failed.", hostLabel.ifBlank { "the host" })
                            }
                        }
                    },
                )
            }
            val openChat = chats.firstOrNull { it.str("id") == openId }
            val transcript = remember(events, openChat) {
                coalesceTranscript(
                    events,
                    defaultBackend = openChat?.str("backend"),
                    running = openChat?.bol("running") ?: true,
                )
            }
            // Fills, rather than wrapping: the composer below is docked to
            // the bottom edge the way every chat app docks it, instead of
            // floating at whatever height the transcript happened to end.
            if (transcript.isEmpty()) {
                // The character, the way the Apple clients open an empty
                // conversation with one. A blank rectangle above a composer
                // says the screen failed to load; the persona says it is
                // waiting for you.
                Column(
                    Modifier.weight(1f).fillMaxWidth(),
                    horizontalAlignment = Alignment.CenterHorizontally,
                    verticalArrangement = Arrangement.Center,
                ) {
                    EmptyArt(EmptyArtKind.Chat)
                    Spacer(Modifier.height(Space.s))
                    Text(
                        "Ask about ${folderName.ifBlank { "this folder" }}",
                        style = MaterialTheme.typography.titleSmall,
                        color = LocalTsColors.current.textPrimary,
                    )
                    Text(
                        "Plan a change, explore the code, or set something running.",
                        style = MaterialTheme.typography.bodySmall,
                        color = LocalTsColors.current.textSecondary,
                        textAlign = TextAlign.Center,
                        modifier = Modifier.padding(horizontal = Space.l),
                    )
                }
            } else {
                LazyColumn(
                    Modifier.weight(1f),
                    contentPadding = PaddingValues(bottom = Space.s),
                    verticalArrangement = Arrangement.spacedBy(6.dp),
                ) {
                    items(transcript, key = { it.id }) { item ->
                        TranscriptItemRow(
                            item = item,
                            model = model,
                            peer = peer,
                            chatId = openId ?: "",
                            hostLabel = hostLabel,
                            defaultAgentName = openChat?.str("backend")?.let { harnessName(it) } ?: "Agent",
                        )
                    }
                }
            }
            if (sendError != null) {
                StickyErrorCard(
                    message = sendError!!,
                    onRetry = { scope.launch { send(draft) } },
                    onDismiss = { sendError = null; pendingSend = null },
                )
                if (pendingSend != null) {
                    TsSecondaryButton(
                        label = "Check delivery",
                        small = true,
                        onClick = { scope.launch { checkDelivery() } },
                    )
                }
            } else if (pendingSend != null) {
                Banner("A previous send needs confirmation. Return to the live conversation to check it.", BannerSeverity.WARNING)
                Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                    TsSecondaryButton(label = "Check", small = true, onClick = {
                        scope.launch { checkDelivery() }
                    })
                    TextButton(onClick = { pendingSend = null }) { Text("Dismiss") }
                }
            }
            attachError?.let { Banner(it, BannerSeverity.DANGER) }
            ChatComposer(
                chat = chats.firstOrNull { it.str("id") == openId },
                draft = draft,
                onDraft = { draft = it },
                hint = ai.tokenstat.tokenstat.ui.logic.ChatHint.hint(folderName, sending),
                sending = sending,
                staged = staged,
                onPick = { attachError = null; picker.launch(arrayOf("*/*")) },
                onRemove = { staged = staged - it },
                onSend = { scope.launch { send(draft) } },
                onStop = {
                    val id = openId ?: return@ChatComposer
                    scope.launch {
                        runCatching {
                            model.workspaceSection(peer, "chat.stop", buildJsonObject { put("id", id) })
                        }
                        sending = false
                    }
                },
                onSetup = { showingSetup = true },
                onChange = { field, value ->
                    val id = openId ?: return@ChatComposer
                    scope.launch {
                        runCatching {
                            model.workspaceSection(peer, "chat.update", buildJsonObject {
                                put("id", id); put(field, value)
                            })
                        }.onSuccess { loadChats() }
                    }
                },
            )
        }
    }
    val doomed = pendingDelete
    if (doomed != null) {
        val host = hostLabel.ifBlank { "the computer" }
        AlertDialog(
            onDismissRequest = { pendingDelete = null },
            title = { Text("Delete this chat?") },
            text = { Text("The transcript stays on $host until you delete it. This cannot be undone.") },
            confirmButton = {
                TextButton(onClick = {
                    pendingDelete = null
                    scope.launch {
                        runCatching {
                            model.workspaceSection(peer, "chat.remove", buildJsonObject {
                                put("id", doomed.str("id") ?: "")
                            })
                        }
                        loadChats()
                    }
                }) { Text("Delete chat") }
            },
            dismissButton = { TextButton(onClick = { pendingDelete = null }) { Text("Keep it") } },
        )
    }
    if (showingSetup) {
        val id = openId
        if (id != null) {
            ChatSetupDialog(
                model = model,
                peer = peer,
                workspace = workspace,
                chatId = id,
                hostLabel = hostLabel,
                onDismiss = { showingSetup = false },
            )
        }
    }
}

/// The three fact cards the iOS list leads with: Conversations, Running,
/// Agents. Figure first in accent, caption below, mark trailing.
@Composable
private fun ChatStatPanels(chats: List<JsonObject>) {
    val colors = LocalTsColors.current
    val panels = listOf(
        Triple("Conversations", chats.size.toString(), Icons.Default.ChatBubbleOutline),
        Triple("Running", chats.count { it.bol("running") }.toString(), Icons.Default.Bolt),
        Triple("Agents", chats.mapNotNull { it.str("backend") }.toSet().size.toString(), Icons.Default.Person),
    )
    // Figure and glyph share the top row, label spans the width underneath,
    // the way the Apple tiles are built. Sitting the glyph beside the label
    // instead left "Conversations" competing with it for room in a third of
    // the screen, and it lost: the tile read "Conversation".
    Row(horizontalArrangement = Arrangement.spacedBy(Space.s)) {
        panels.forEach { (label, value, mark) ->
            TsCard(Modifier.weight(1f)) {
                Column(verticalArrangement = Arrangement.spacedBy(2.dp)) {
                    Row(verticalAlignment = Alignment.CenterVertically) {
                        Text(
                            value,
                            style = TsType.numeric(20, FontWeight.Medium),
                            color = colors.accent,
                            maxLines = 1,
                            modifier = Modifier.weight(1f),
                        )
                        Box(
                            Modifier
                                .size(26.dp)
                                .clip(RoundedCornerShape(8.dp))
                                .background(colors.accentSoft),
                            contentAlignment = Alignment.Center,
                        ) {
                            Icon(mark, null, tint = colors.accent, modifier = Modifier.size(15.dp))
                        }
                    }
                    Text(
                        label,
                        style = TsType.caption2,
                        color = colors.textSecondary,
                        maxLines = 1,
                        overflow = TextOverflow.Ellipsis,
                    )
                }
            }
        }
    }
}

@Composable
private fun ChatAgentMenuItem(label: String, checked: Boolean, onClick: () -> Unit) {
    DropdownMenuItem(
        text = { Text(label) },
        leadingIcon = if (checked) ({ Icon(Icons.Default.Check, null) }) else null,
        onClick = onClick,
    )
}

/// One conversation row like the iOS list: harness mark, running dot,
/// two-line title, agent and Plan/Execute in accent, relative time, chevron.
@Composable
private fun ChatRow(chat: JsonObject) {
    val colors = LocalTsColors.current
    val mode = if (chat.str("mode") == "plan") "Plan" else "Execute"
    val atMs = chat["lastMessageAtMs"]?.jsonPrimitive?.longOrNull
        ?: chat["updatedAtMs"]?.jsonPrimitive?.longOrNull
    Row(
        Modifier.padding(12.dp),
        horizontalArrangement = Arrangement.spacedBy(Space.s),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        HarnessMark(chat.str("backend") ?: "?", size = 28.dp)
        Column(Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(3.dp)) {
            Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(6.dp)) {
                if (chat.bol("running")) {
                    Canvas(Modifier.size(7.dp)) { drawCircle(colors.accent) }
                }
                Text(
                    chat.str("title") ?: "Untitled",
                    style = MaterialTheme.typography.titleSmall,
                    maxLines = 2,
                    overflow = TextOverflow.Ellipsis,
                )
            }
            Text(
                "${harnessName(chat.str("backend") ?: "?")} · $mode",
                style = MaterialTheme.typography.bodySmall,
                color = colors.accent,
                maxLines = 1,
            )
            if (atMs != null) {
                RelativeTimeText(atMs, style = MaterialTheme.typography.bodySmall, color = colors.textSecondary, compact = true)
            }
        }
        Icon(Icons.AutoMirrored.Filled.KeyboardArrowRight, null, tint = colors.controlGlyph)
    }
}

/// A tool approval awaiting an answer: verb, preview, and Allow, Always
/// allow, Deny. Decided approvals read back their outcome instead.
@Composable
internal fun ApprovalCard(approval: JsonObject, onResolve: (String) -> Unit) {
    val verb = approval.str("verb") ?: "Approval"
    val preview = approval.str("preview") ?: ""
    val pending = approval.str("decision").isNullOrBlank()
    val colors = LocalTsColors.current
    Column(
        Modifier
            .fillMaxWidth()
            .clip(RoundedCornerShape(cardRadiusDp))
            .background(colors.panel)
            .padding(Space.m),
        verticalArrangement = Arrangement.spacedBy(Space.s),
    ) {
        Row(verticalAlignment = androidx.compose.ui.Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(Space.s)) {
            Text(
                if (pending) "Needs an answer" else "Decided",
                style = TextStyle(fontSize = 14.sp, fontWeight = FontWeight.SemiBold),
                color = if (pending) colors.warning else colors.textSecondary,
                modifier = Modifier.weight(1f),
            )
            Text(
                verb,
                style = TextStyle(fontSize = 12.sp, fontWeight = FontWeight.Medium),
                color = colors.accent,
            )
        }
        if (preview.isNotBlank()) {
            Text(preview, style = TsType.mono(12), color = colors.textPrimary, maxLines = 5)
        }
        if (pending) {
            Row(horizontalArrangement = Arrangement.spacedBy(Space.s)) {
                TsAccentButton(label = "Allow", small = true, onClick = { onResolve("allow") })
                TsSecondaryButton(label = "Always allow", small = true, onClick = { onResolve("allowAlways") })
                TsSecondaryButton(label = "Deny", small = true, onClick = { onResolve("deny") })
            }
        } else {
            Text(
                approval.str("decision") ?: "",
                style = TextStyle(fontSize = 12.sp),
                color = colors.textSecondary,
            )
        }
    }
}

/// Chat setup: the instructions behind Edit setup, and the personas that
/// shape this chat. Read paths first: instructions display, persona list
/// with the default marked and selectable.
@Composable
private fun ChatSetupDialog(
    model: AppViewModel,
    peer: String,
    workspace: String,
    chatId: String,
    hostLabel: String,
    onDismiss: () -> Unit,
) {
    val scope = rememberCoroutineScope()
    var brief by remember { mutableStateOf<String?>(null) }
    var added by remember { mutableStateOf<String?>(null) }
    var channel by remember { mutableStateOf<String?>(null) }
    var personas by remember { mutableStateOf<List<JsonObject>>(emptyList()) }
    var defaultId by remember { mutableStateOf<String?>(null) }
    var error by remember { mutableStateOf<String?>(null) }
    var loading by remember { mutableStateOf(true) }
    var showingPersonas by remember { mutableStateOf(false) }

    suspend fun load() {
        loading = true
        runCatching {
            model.workspaceSection(peer, "chat.instructions", buildJsonObject { put("id", chatId) })
        }.onSuccess { element ->
            // `chat.instructions` answers {brief, added, channel}. Reading it
            // for an "instructions" key that was never there fell through to
            // `toString`, which put the raw JSON on screen, escapes and all.
            val obj = element as? JsonObject
            brief = obj?.str("brief")
            added = obj?.str("added")
            channel = obj?.str("channel")
        }.onFailure { error = TunnelCopy.display(it.message ?: "The request failed.", hostLabel) }
        runCatching {
            model.workspaceSection(peer, "chat.personas", buildJsonObject { put("workspaceId", workspace) })
        }.onSuccess { element ->
            val obj = element as? JsonObject
            personas = (obj?.get("personas") as? JsonArray)?.filterIsInstance<JsonObject>()
                ?: (element as? JsonArray)?.filterIsInstance<JsonObject>()
                ?: emptyList()
            defaultId = obj?.str("defaultId") ?: obj?.str("default_id")
        }
        loading = false
    }
    LaunchedEffect(chatId) { load() }

    val colors = LocalTsColors.current
    Dialog(onDismissRequest = onDismiss, properties = DialogProperties(usePlatformDefaultWidth = false)) {
        // A sheet with a surface under it. Without one the dialog drew its
        // text straight over the conversation: two paragraphs of instructions
        // interleaved with the persona and the composer, unreadable, and
        // nothing on screen said which taps belonged to which layer.
        Surface(
            shape = RoundedCornerShape(20.dp),
            color = colors.background,
            tonalElevation = 0.dp,
            shadowElevation = 12.dp,
            modifier = Modifier
                .fillMaxWidth(0.94f)
                .fillMaxHeight(0.86f),
        ) {
        Column(
            Modifier
                .fillMaxWidth()
                .padding(Space.m)
                .verticalScroll(rememberScrollState()),
            verticalArrangement = Arrangement.spacedBy(Space.m),
        ) {
            Text("Chat setup", style = TextStyle(fontSize = 17.sp, fontWeight = FontWeight.SemiBold), color = colors.textPrimary)
            if (error != null) Banner(error!!, BannerSeverity.DANGER)
            if (loading) {
                Text("Loading…", color = colors.textSecondary)
            } else {
                // What the person wrote, and what tokenstat adds, kept apart:
                // only one of the two is theirs to change.
                Column(verticalArrangement = Arrangement.spacedBy(Space.xs)) {
                    SectionLabel("Brief")
                    Text(
                        brief?.ifBlank { null } ?: "No brief. The agent gets the folder and your messages.",
                        style = TextStyle(fontSize = 14.sp),
                        color = colors.textSecondary,
                    )
                }
                added?.ifBlank { null }?.let {
                    Column(verticalArrangement = Arrangement.spacedBy(Space.xs)) {
                        SectionLabel("What tokenstat adds")
                        Text(it, style = TextStyle(fontSize = 13.sp), color = colors.textSecondary)
                        Text(
                            when (channel) {
                                "systemPrompt" -> "Sent as the system prompt."
                                "turnPrefix" -> "This agent takes no system prompt, so it goes in front of each turn."
                                else -> ""
                            },
                            style = TextStyle(fontSize = 12.sp),
                            color = colors.textTertiary,
                        )
                    }
                }
                Column(verticalArrangement = Arrangement.spacedBy(Space.xs)) {
                    Row(verticalAlignment = Alignment.CenterVertically) {
                        SectionLabel("Personas", personas.size, Modifier.weight(1f))
                        TsSecondaryButton(label = "Personas", small = true, onClick = { showingPersonas = true })
                    }
                    if (personas.isEmpty()) {
                        Text("No personas yet.", style = TextStyle(fontSize = 14.sp), color = LocalTsColors.current.textSecondary)
                    }
                    personas.forEach { persona ->
                        val id = persona.str("id") ?: return@forEach
                        val name = persona.str("name") ?: persona.str("title") ?: id
                        Row(
                            Modifier
                                .fillMaxWidth()
                                .clip(RoundedCornerShape(cardRadiusDp))
                                .background(LocalTsColors.current.panel)
                                .clickable {
                                    scope.launch {
                                        runCatching {
                                            model.workspaceSection(peer, "chat.personaDefault", buildJsonObject {
                                                put("workspaceId", workspace); put("personaId", id)
                                            })
                                        }.onSuccess { defaultId = id }
                                    }
                                }
                                .padding(Space.m),
                            verticalAlignment = androidx.compose.ui.Alignment.CenterVertically,
                        ) {
                            Text(
                                name,
                                style = TextStyle(fontSize = 14.sp),
                                color = LocalTsColors.current.textPrimary,
                                modifier = Modifier.weight(1f),
                            )
                            if (id == defaultId) {
                                Text("Default", style = TextStyle(fontSize = 11.sp, fontWeight = FontWeight.Medium), color = LocalTsColors.current.accent)
                            }
                        }
                    }
                }
            }
            TsSecondaryButton(label = "Done", icon = ActionIcon.Done.vector, small = true, onClick = onDismiss)
        }
        }
    }
    if (showingPersonas) {
        PersonaSheet(
            model = model,
            peer = peer,
            workspaceId = workspace,
            onDismiss = { showingPersonas = false; scope.launch { load() } },
        )
    }
}

/// Pull bodies mix markdown with raw HTML (Dependabot release notes are
/// mostly `<details>` and `<a>` tags). Links keep their URL in
/// parentheses; every other tag goes, so the markdown renderer below sees
/// prose instead of markup.
internal fun stripPullHtml(body: String): String = body
    .replace(Regex("""<a\s+href="([^"]*)">([^<]*)</a>""", RegexOption.IGNORE_CASE), "$2 ($1)")
    .replace(Regex("""<!--.*?-->"""), "")
    .replace(Regex("""<[^>]*>"""), "")
    .replace("&amp;", "&")
    .replace("&lt;", "<")
    .replace("&gt;", ">")
    .replace("&quot;", "\"")
    .replace("&#39;", "'")
    .lines()
    .map { it.trimEnd() }
    .joinToString("\n")
    .replace(Regex("\n{3,}"), "\n\n")
    .trim()

private val pullScopes = listOf(
    "All" to "all",
    "Mine" to "mine",
    "Assigned" to "assigned",
    "Review requested" to "reviewRequested",
)

private val pullStates = listOf("Open" to "open", "Merged" to "merged", "Closed" to "closed")

/// Pull requests for this folder: availability first (a paired client can
/// inspect, never connect), then scope and state filters, then rows with
/// the same counts the Apple list shows. Detail opens over the list.
@Composable
fun PullsSection(
    model: AppViewModel,
    peer: String,
    workspace: String,
    protocol: Long?,
    modifier: Modifier = Modifier,
    folderName: String = "",
    hostLabel: String = "",
) {
    val scope = rememberCoroutineScope()
    var availability by remember(workspace) { mutableStateOf<JsonObject?>(null) }
    var pulls by remember(workspace) { mutableStateOf<List<JsonObject>>(emptyList()) }
    var error by remember(workspace) { mutableStateOf<String?>(null) }
    var loading by remember(workspace) { mutableStateOf(true) }
    var scopeName by remember { mutableStateOf("all") }
    var stateName by remember { mutableStateOf("open") }
    var openNumber by remember { mutableStateOf<Long?>(null) }

    suspend fun load() {
        loading = true
        runCatching {
            model.workspaceSection(peer, "pulls.availability", buildJsonObject { put("workspaceId", workspace) }) as? JsonObject
        }.onSuccess { availability = it }
        runCatching {
            model.workspaceSection(peer, "pulls.list", buildJsonObject {
                put("workspaceId", workspace); put("scope", scopeName); put("state", stateName); put("limit", 30)
            })
        }.onSuccess {
            val arr = (it as? JsonObject)?.get("pulls") as? JsonArray ?: (it as? JsonArray)
            pulls = arr?.filterIsInstance<JsonObject>() ?: emptyList()
            error = null
        }.onFailure { error = friendlyError(it.message).message }
        loading = false
    }
    LaunchedEffect(workspace, scopeName, stateName) { load() }
    val opened = openNumber
    if (opened != null) {
        PullDetailPage(
            model = model,
            peer = peer,
            workspace = workspace,
            hostLabel = hostLabel,
            number = opened,
            modifier = modifier,
            onBack = { openNumber = null; scope.launch { load() } },
        )
        return
    }
    Column(modifier, verticalArrangement = Arrangement.spacedBy(8.dp)) {
        // The pushed header says "Pull requests" already.
        if (!HostContracts.supportsPulls(protocol)) {
            Text("Update the host to read pull requests (needs protocol 3).", style = MaterialTheme.typography.bodySmall)
            return
        }
        val available = availability
        if (available != null && (available.str("state") ?: "") != "ready") {
            Column(
                Modifier
                    .fillMaxWidth()
                    .clip(RoundedCornerShape(cardRadiusDp))
                    .background(LocalTsColors.current.panel)
                    .padding(Space.m),
                verticalArrangement = Arrangement.spacedBy(Space.s),
            ) {
                Text(
                    "Bring the review into tokenstat",
                    style = TextStyle(fontSize = 14.sp, fontWeight = FontWeight.SemiBold),
                    color = LocalTsColors.current.textPrimary,
                )
                Text(
                    "Read the conversation, inspect the same diff as Changes, follow checks, and review without losing the workspace around it.",
                    style = TextStyle(fontSize = 12.sp),
                    color = LocalTsColors.current.textSecondary,
                )
                Text(
                    "tokenstat only sees repositories selected for its GitHub App installation.",
                    style = TextStyle(fontSize = 12.sp),
                    color = LocalTsColors.current.textSecondary,
                )
            }
            return
        }
        if (error != null) {
            StickyErrorCard(
                message = error!!,
                onRetry = { scope.launch { load() } },
                onDismiss = { error = null },
            )
        }
        Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
            pullScopes.forEach { (label, value) ->
                if (value == scopeName) {
                    TsAccentButton(label = label, small = true, onClick = {})
                } else {
                    TsSecondaryButton(label = label, small = true, onClick = { scopeName = value })
                }
            }
        }
        Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
            pullStates.forEach { (label, value) ->
                if (value == stateName) {
                    TsAccentButton(label = label, small = true, onClick = {})
                } else {
                    TsSecondaryButton(label = label, small = true, onClick = { stateName = value })
                }
            }
        }
        Text(
            "${pulls.size} shown",
            style = TextStyle(fontSize = 12.sp),
            color = LocalTsColors.current.textSecondary,
        )
        if (loading) { CircularProgressIndicator(Modifier, strokeWidth = 2.dp); return }
        if (pulls.isEmpty() && error == null) {
            EmptyState(Icons.Default.ChatBubbleOutline, "No open pulls", "Connect GitHub on the host to review here.")
            return
        }
        LazyColumn(contentPadding = PaddingValues(bottom = TabBarChrome.contentBottomInset), verticalArrangement = Arrangement.spacedBy(6.dp)) {
            items(pulls, key = { it.get("number")?.jsonPrimitive?.longOrNull?.toString() ?: it.hashCode().toString() }) { pr ->
                val number = pr.get("number")?.jsonPrimitive?.longOrNull ?: return@items
                TsCard(Modifier.clickable { openNumber = number }) {
                    Column(Modifier.padding(12.dp), verticalArrangement = Arrangement.spacedBy(2.dp)) {
                        Text(
                            "#$number ${pr.str("title") ?: ""}",
                            style = TextStyle(fontSize = 14.sp, fontWeight = FontWeight.Medium),
                            color = LocalTsColors.current.textPrimary,
                        )
                        Text(
                            "${pr.str("headRef") ?: pr.str("head") ?: ""} → ${pr.str("baseRef") ?: pr.str("base") ?: ""}",
                            style = TsType.mono(12),
                            color = LocalTsColors.current.textSecondary,
                        )
                        Row(horizontalArrangement = Arrangement.spacedBy(Space.s)) {
                            pr.get("additions")?.jsonPrimitive?.longOrNull?.let {
                                Text("+$it", style = TsType.numeric(12), color = LocalTsColors.current.diffAdded)
                            }
                            pr.get("deletions")?.jsonPrimitive?.longOrNull?.let {
                                Text("−$it", style = TsType.numeric(12), color = LocalTsColors.current.diffRemoved)
                            }
                            pr.get("changedFiles")?.jsonPrimitive?.longOrNull?.let {
                                Text("$it files", style = TextStyle(fontSize = 12.sp), color = LocalTsColors.current.textSecondary)
                            }
                            pr.str("state")?.takeIf { it.isNotBlank() }?.let {
                                Text(it, style = TextStyle(fontSize = 12.sp), color = LocalTsColors.current.textSecondary)
                            }
                            if (pr.bol("draft")) {
                                Text("Draft", style = TextStyle(fontSize = 12.sp), color = LocalTsColors.current.textSecondary)
                            }
                        }
                    }
                }
            }
        }
    }
}

/// One pull request as a full management page, port of `PullDetailView`: the
/// hero, the conversation with its timeline and composer, the files with the
/// same diff rows as Changes, the checks, and the actions panel (review,
/// ready, merge, close or reopen, local checkout). Every call site is one
/// labelled button press, using the same `pulls.*` host methods iOS uses.
@Composable
private fun PullDetailPage(
    model: AppViewModel,
    peer: String,
    workspace: String,
    hostLabel: String,
    number: Long,
    modifier: Modifier = Modifier,
    onBack: () -> Unit,
) {
    val scope = rememberCoroutineScope()
    var detail by remember(number) { mutableStateOf<JsonObject?>(null) }
    var timeline by remember(number) { mutableStateOf<List<JsonObject>>(emptyList()) }
    var nextCursor by remember(number) { mutableStateOf<String?>(null) }
    var diffs by remember(number) { mutableStateOf<List<JsonObject>>(emptyList()) }
    var error by remember(number) { mutableStateOf<String?>(null) }
    var actionError by remember(number) { mutableStateOf<String?>(null) }
    var actionNotice by remember(number) { mutableStateOf<String?>(null) }
    var loading by remember(number) { mutableStateOf(true) }
    var actionBusy by remember(number) { mutableStateOf(false) }
    var commentDraft by remember(number) { mutableStateOf("") }
    var reviewMode by remember(number) { mutableStateOf<String?>(null) }
    var reviewDraft by remember(number) { mutableStateOf("") }
    var mergeMethod by remember(number) { mutableStateOf("merge") }
    var checkoutBranch by remember(number) { mutableStateOf("") }
    var confirmingClose by remember(number) { mutableStateOf(false) }
    var confirmingMerge by remember(number) { mutableStateOf(false) }

    suspend fun loadTimeline(cursor: String? = null, append: Boolean = false) {
        runCatching {
            model.workspaceSection(peer, "pulls.timeline", buildJsonObject {
                put("workspaceId", workspace); put("number", number); put("refresh", false)
                if (cursor != null) put("cursor", cursor)
            })
        }.onSuccess { element ->
            val page = element as? JsonObject
            val fresh = asObjects(page?.get("events")).ifEmpty { asObjects(element) }
            timeline = if (append) timeline + fresh else fresh
            nextCursor = page?.str("nextCursor")
        }
    }
    suspend fun loadDiff() {
        runCatching {
            model.workspaceSection(peer, "pulls.diff", buildJsonObject {
                put("workspaceId", workspace); put("number", number); put("refresh", false)
            })
        }.onSuccess { element ->
            val obj = element as? JsonObject
            diffs = asObjects(element).ifEmpty { asObjects(obj?.get("diffs")) }.ifEmpty { asObjects(obj?.get("files")) }
        }
    }
    suspend fun load() {
        loading = true
        runCatching {
            model.workspaceSection(peer, "pulls.view", buildJsonObject {
                put("workspaceId", workspace); put("number", number); put("refresh", false)
            }) as? JsonObject
        }.onSuccess {
            detail = (it?.get("pull") as? JsonObject) ?: it
            error = null
            loadTimeline()
            loadDiff()
        }.onFailure { error = TunnelCopy.display(it.message ?: "The request failed.", hostLabel) }
        loading = false
    }
    LaunchedEffect(number) { load() }

    suspend fun act(label: String, method: String, params: JsonObjectBuilderScope.() -> Unit) {
        if (actionBusy) return
        actionBusy = true
        actionNotice = null
        try {
            runCatching {
                model.workspaceSection(peer, method, buildJsonObject {
                    put("workspaceId", workspace); put("number", number)
                    JsonObjectBuilderScope(this).params()
                })
            }.onSuccess {
                actionError = null
                actionNotice = label
                load()
            }.onFailure {
                actionError = TunnelCopy.display(it.message ?: "The request failed.", hostLabel)
            }
        } finally {
            actionBusy = false
        }
    }

    val view = detail
    Column(modifier.verticalScroll(rememberScrollState()).padding(bottom = TabBarChrome.contentBottomInset), verticalArrangement = Arrangement.spacedBy(Space.m)) {
        Row(verticalAlignment = Alignment.CenterVertically) {
            TextButton(onClick = onBack, modifier = Modifier.weight(1f)) {
                Text("← Pull requests", modifier = Modifier.fillMaxWidth())
            }
            TextButton(onClick = { scope.launch { load() } }) { Text("Refresh") }
        }
        Text("#$number", style = TsType.mono(13), color = LocalTsColors.current.textSecondary)
        if (error != null) {
            StickyErrorCard(
                message = error!!,
                onRetry = { scope.launch { load() } },
                onDismiss = { error = null },
            )
        }
        if (actionError != null) {
            StickyErrorCard(
                message = actionError!!,
                onDismiss = { actionError = null },
            )
        }
        actionNotice?.let { Banner(it, BannerSeverity.SUCCESS) }
        if (loading && view == null) {
            Text("Loading…", color = LocalTsColors.current.textSecondary)
            return
        }
        if (view == null) return
        PullHeroCard(view)
        PullConversationCard(
            timeline = timeline,
            nextCursor = nextCursor,
            commentDraft = commentDraft,
            onCommentDraft = { commentDraft = it },
            busy = actionBusy,
            onMore = { scope.launch { loadTimeline(nextCursor, append = true) } },
            onComment = {
                val body = commentDraft.trim()
                if (body.isEmpty()) return@PullConversationCard
                commentDraft = ""
                scope.launch { act("Comment posted.", "pulls.comment") { put("body", body) } }
            },
        )
        PullFilesCard(diffs)
        PullChecksCard(view)
        PullActionsPanel(
            view = view,
            busy = actionBusy,
            reviewMode = reviewMode,
            reviewDraft = reviewDraft,
            onReviewDraft = { reviewDraft = it },
            onBeginReview = { reviewMode = it; reviewDraft = "" },
            onCancelReview = { reviewMode = null; reviewDraft = "" },
            onApprove = { scope.launch { act("Approved.", "pulls.review") { put("verdict", "approve"); put("body", "") } } },
            onSendReview = { mode ->
                val body = reviewDraft.trim()
                if (body.isEmpty()) return@PullActionsPanel
                reviewMode = null
                reviewDraft = ""
                scope.launch { act("Review sent.", "pulls.review") { put("verdict", mode); put("body", body) } }
            },
            onReady = { scope.launch { act("Marked ready for review.", "pulls.ready") {} } },
            onClose = { confirmingClose = true },
            onReopen = { scope.launch { act("Reopened.", "pulls.reopen") {} } },
            mergeMethod = mergeMethod,
            onMergeMethod = { mergeMethod = it },
            onMerge = { confirmingMerge = true },
            checkoutBranch = checkoutBranch,
            onCheckoutBranch = { checkoutBranch = it },
            onCheckout = {
                val branch = checkoutBranch.trim()
                if (branch.isEmpty()) return@PullActionsPanel
                scope.launch { act("Checked out $branch.", "pulls.checkout") { put("branch", branch) } }
            },
        )
    }
    if (confirmingClose) {
        AlertDialog(
            onDismissRequest = { confirmingClose = false },
            title = { Text("Close pull request #$number?") },
            text = { Text("The branch stays. You can reopen it later.") },
            confirmButton = {
                TextButton(onClick = {
                    confirmingClose = false
                    scope.launch { act("Closed.", "pulls.close") {} }
                }) { Text("Close pull request") }
            },
            dismissButton = { TextButton(onClick = { confirmingClose = false }) { Text("Cancel") } },
        )
    }
    if (confirmingMerge) {
        AlertDialog(
            onDismissRequest = { confirmingMerge = false },
            title = { Text("Merge pull request #$number?") },
            text = { Text("Merge with ${ai.tokenstat.tokenstat.ui.logic.PullReview.mergeTitle(mergeMethod).lowercase()}.") },
            confirmButton = {
                TextButton(onClick = {
                    confirmingMerge = false
                    scope.launch { act("Merged.", "pulls.merge") { put("mergeMethod", mergeMethod) } }
                }) { Text("Merge pull request") }
            },
            dismissButton = { TextButton(onClick = { confirmingMerge = false }) { Text("Cancel") } },
        )
    }
}

private class JsonObjectBuilderScope(val builder: kotlinx.serialization.json.JsonObjectBuilder) {
    fun put(key: String, value: String) = builder.put(key, value)
}

@Composable
private fun PullHeroCard(view: JsonObject) {
    val colors = LocalTsColors.current
    Column(
        Modifier
            .fillMaxWidth()
            .clip(RoundedCornerShape(cardRadiusDp))
            .background(colors.panel)
            .padding(Space.m),
        verticalArrangement = Arrangement.spacedBy(Space.s),
    ) {
        Text(
            view.str("title") ?: "",
            style = TextStyle(fontSize = 16.sp, fontWeight = FontWeight.SemiBold),
            color = colors.textPrimary,
        )
        (view.str("body") ?: "").takeIf { it.isNotBlank() }?.let {
            MarkdownText(stripPullHtml(it), TextStyle(fontSize = 14.sp), colors.textSecondary)
        }
        val author = (view["author"] as? JsonObject)?.str("login") ?: view.str("author").orEmpty()
        Row(horizontalArrangement = Arrangement.spacedBy(Space.s), verticalAlignment = Alignment.CenterVertically) {
            if (author.isNotBlank()) {
                Text(author, style = TextStyle(fontSize = 12.sp, fontWeight = FontWeight.Medium), color = colors.textPrimary)
            }
            view.str("createdAt")?.takeIf { it.isNotBlank() }?.let {
                Text(it.take(10), style = TextStyle(fontSize = 12.sp), color = colors.textTertiary)
            }
            view.str("state")?.takeIf { it.isNotBlank() }?.let {
                Text(it.replaceFirstChar(Char::uppercase), style = TextStyle(fontSize = 12.sp, fontWeight = FontWeight.Medium), color = colors.accent)
            }
            if (view.bol("draft")) {
                Text("Draft", style = TextStyle(fontSize = 12.sp), color = colors.textSecondary)
            }
        }
        Text(
            "${view.str("headRef") ?: ""} → ${view.str("baseRef") ?: ""}",
            style = TsType.mono(12),
            color = colors.textSecondary,
        )
        Row(horizontalArrangement = Arrangement.spacedBy(Space.s)) {
            view.long("additions")?.let {
                Text("+$it", style = TsType.numeric(12), color = colors.diffAdded)
            }
            view.long("deletions")?.let {
                Text("−$it", style = TsType.numeric(12), color = colors.diffRemoved)
            }
            view.long("changedFiles")?.let {
                Text("$it files", style = TextStyle(fontSize = 12.sp), color = colors.textSecondary)
            }
        }
        view.str("reviewDecision")?.takeIf { it.isNotBlank() }?.let {
            Text("Review: $it", style = TextStyle(fontSize = 12.sp), color = colors.textSecondary)
        }
        (view["labels"] as? JsonArray)?.mapNotNull { (it as? JsonPrimitive)?.contentOrNull }
            ?.takeIf { it.isNotEmpty() }?.let { labels ->
                Text(labels.joinToString(" · "), style = TextStyle(fontSize = 12.sp), color = colors.textSecondary)
            }
    }
}

@Composable
private fun PullConversationCard(
    timeline: List<JsonObject>,
    nextCursor: String?,
    commentDraft: String,
    onCommentDraft: (String) -> Unit,
    busy: Boolean,
    onMore: () -> Unit,
    onComment: () -> Unit,
) {
    val colors = LocalTsColors.current
    Column(
        Modifier
            .fillMaxWidth()
            .clip(RoundedCornerShape(cardRadiusDp))
            .background(colors.panel)
            .padding(Space.m),
        verticalArrangement = Arrangement.spacedBy(Space.m),
    ) {
        Text("Conversation", style = TextStyle(fontSize = 14.sp, fontWeight = FontWeight.SemiBold), color = colors.textPrimary)
        if (timeline.isEmpty()) {
            Text("No comments yet.", style = TextStyle(fontSize = 12.sp), color = colors.textSecondary)
        }
        timeline.forEach { event ->
            val actor = (event["actor"] as? JsonObject)?.str("login") ?: event.str("actor").orEmpty()
            Column(verticalArrangement = Arrangement.spacedBy(2.dp)) {
                Row(horizontalArrangement = Arrangement.spacedBy(Space.s), verticalAlignment = Alignment.CenterVertically) {
                    Text(
                        (event.str("kind") ?: "event").replaceFirstChar(Char::uppercase),
                        style = TextStyle(fontSize = 11.sp, fontWeight = FontWeight.SemiBold),
                        color = colors.accent,
                    )
                    if (actor.isNotBlank()) {
                        Text(actor, style = TextStyle(fontSize = 12.sp, fontWeight = FontWeight.Medium), color = colors.textPrimary)
                    }
                    event.str("createdAt")?.takeIf { it.isNotBlank() }?.let {
                        Text(it.take(10), style = TextStyle(fontSize = 11.sp), color = colors.textTertiary)
                    }
                }
                (event.str("subject") ?: event.str("state"))?.takeIf { it.isNotBlank() }?.let {
                    Text(it, style = TextStyle(fontSize = 12.sp, fontWeight = FontWeight.Medium), color = colors.textPrimary)
                }
                (event.str("body") ?: "").takeIf { it.isNotBlank() }?.let {
                    MarkdownText(stripPullHtml(it), TextStyle(fontSize = 13.sp), colors.textSecondary)
                }
            }
        }
        if (nextCursor != null) {
            TsSecondaryButton(label = "More", small = true, onClick = onMore)
        }
        Text("Join the conversation", style = TextStyle(fontSize = 14.sp, fontWeight = FontWeight.SemiBold), color = colors.textPrimary)
        OutlinedTextField(
            commentDraft,
            onCommentDraft,
            modifier = Modifier.fillMaxWidth(),
            placeholder = { Text("Write a comment…") },
            minLines = 3,
        )
        Row(verticalAlignment = Alignment.CenterVertically) {
            Text("Markdown is supported", style = TextStyle(fontSize = 11.sp), color = colors.textTertiary, modifier = Modifier.weight(1f))
            TsAccentButton(label = "Comment", small = true, enabled = commentDraft.trim().isNotEmpty() && !busy, onClick = onComment)
        }
    }
}

@Composable
private fun PullFilesCard(diffs: List<JsonObject>) {
    val colors = LocalTsColors.current
    Column(
        Modifier
            .fillMaxWidth()
            .clip(RoundedCornerShape(cardRadiusDp))
            .background(colors.panel)
            .padding(Space.m),
        verticalArrangement = Arrangement.spacedBy(Space.m),
    ) {
        Text("Files", style = TextStyle(fontSize = 14.sp, fontWeight = FontWeight.SemiBold), color = colors.textPrimary)
        if (diffs.isEmpty()) {
            Text("No file changes reported.", style = TextStyle(fontSize = 12.sp), color = colors.textSecondary)
            return
        }
        diffs.forEach { diff ->
            val path = diff.str("path") ?: ""
            Column(verticalArrangement = Arrangement.spacedBy(Space.xs)) {
                Text(
                    path.substringAfterLast('/').ifBlank { path },
                    style = TextStyle(fontSize = 14.sp, fontWeight = FontWeight.Medium),
                    color = colors.textPrimary,
                    maxLines = 1,
                )
                if (path.contains('/')) {
                    Text(path, style = TextStyle(fontSize = 11.sp), color = colors.textSecondary, maxLines = 1)
                }
                Row(horizontalArrangement = Arrangement.spacedBy(Space.s)) {
                    diff.long("additions")?.let {
                        Text("+$it", style = TsType.numeric(12), color = colors.diffAdded)
                    }
                    diff.long("deletions")?.let {
                        Text("−$it", style = TsType.numeric(12), color = colors.diffRemoved)
                    }
                    diff.str("changeType")?.takeIf { it.isNotBlank() }?.let {
                        Text(it.replaceFirstChar(Char::uppercase), style = TextStyle(fontSize = 12.sp), color = colors.textSecondary)
                    }
                }
                if (asObjects(diff["hunks"]).isEmpty()) {
                    Text("No line changes in this file.", style = TextStyle(fontSize = 12.sp), color = colors.textSecondary)
                } else {
                    HunkDiffView(diff)
                }
            }
        }
    }
}

@Composable
private fun PullChecksCard(view: JsonObject) {
    val colors = LocalTsColors.current
    val checks = asObjects(view["checks"])
    val flat = view.str("checks")
    if (checks.isEmpty() && flat.isNullOrBlank()) return
    Column(
        Modifier
            .fillMaxWidth()
            .clip(RoundedCornerShape(cardRadiusDp))
            .background(colors.panel)
            .padding(Space.m),
        verticalArrangement = Arrangement.spacedBy(Space.s),
    ) {
        Text("Checks", style = TextStyle(fontSize = 14.sp, fontWeight = FontWeight.SemiBold), color = colors.textPrimary)
        if (!flat.isNullOrBlank() && checks.isEmpty()) {
            Text(flat, style = TextStyle(fontSize = 12.sp), color = colors.textSecondary)
        }
        checks.forEach { check ->
            Row(horizontalArrangement = Arrangement.spacedBy(Space.s), verticalAlignment = Alignment.CenterVertically) {
                Text(
                    check.str("name") ?: "Check",
                    style = TextStyle(fontSize = 13.sp, fontWeight = FontWeight.Medium),
                    color = colors.textPrimary,
                    modifier = Modifier.weight(1f),
                    maxLines = 1,
                )
                check.str("state")?.takeIf { it.isNotBlank() }?.let {
                    Text(it, style = TextStyle(fontSize = 12.sp), color = colors.textSecondary, maxLines = 1)
                }
            }
            check.str("workflow")?.takeIf { it.isNotBlank() }?.let {
                Text(it, style = TextStyle(fontSize = 11.sp), color = colors.textTertiary, maxLines = 1)
            }
        }
    }
}

@Composable
private fun PullActionsPanel(
    view: JsonObject,
    busy: Boolean,
    reviewMode: String?,
    reviewDraft: String,
    onReviewDraft: (String) -> Unit,
    onBeginReview: (String) -> Unit,
    onCancelReview: () -> Unit,
    onApprove: () -> Unit,
    onSendReview: (String) -> Unit,
    onReady: () -> Unit,
    onClose: () -> Unit,
    onReopen: () -> Unit,
    mergeMethod: String,
    onMergeMethod: (String) -> Unit,
    onMerge: () -> Unit,
    checkoutBranch: String,
    onCheckoutBranch: (String) -> Unit,
    onCheckout: () -> Unit,
) {
    val colors = LocalTsColors.current
    Column(
        Modifier
            .fillMaxWidth()
            .clip(RoundedCornerShape(cardRadiusDp))
            .background(colors.panel)
            .padding(Space.m),
        verticalArrangement = Arrangement.spacedBy(Space.m),
    ) {
        Text("Actions", style = TextStyle(fontSize = 14.sp, fontWeight = FontWeight.SemiBold), color = colors.textPrimary)
        if (view.str("state") == "open") {
            Column(verticalArrangement = Arrangement.spacedBy(Space.s)) {
                Text("Review", style = TextStyle(fontSize = 12.sp, fontWeight = FontWeight.SemiBold), color = colors.textSecondary)
                TsSecondaryButton(label = "Approve", small = true, enabled = !busy, onClick = onApprove)
                TsSecondaryButton(label = "Request changes", small = true, enabled = !busy, onClick = { onBeginReview("requestChanges") })
                TsSecondaryButton(label = "Comment review", small = true, enabled = !busy, onClick = { onBeginReview("comment") })
                val mode = reviewMode
                if (mode != null) {
                    OutlinedTextField(
                        reviewDraft,
                        onReviewDraft,
                        modifier = Modifier.fillMaxWidth(),
                        placeholder = { Text(ai.tokenstat.tokenstat.ui.logic.PullReview.reviewPlaceholder(mode)) },
                        minLines = 3,
                    )
                    Row(horizontalArrangement = Arrangement.spacedBy(Space.s)) {
                        TsSecondaryButton(label = "Cancel", small = true, onClick = onCancelReview)
                        Spacer(Modifier.weight(1f))
                        TsAccentButton(
                            label = "Send review",
                            small = true,
                            enabled = reviewDraft.trim().isNotEmpty() && !busy,
                            onClick = { onSendReview(mode) },
                        )
                    }
                }
            }
            if (view.bol("draft")) {
                TsAccentButton(label = "Ready for review", small = true, enabled = !busy, onClick = onReady)
            }
            Column(verticalArrangement = Arrangement.spacedBy(Space.s)) {
                Text("Merge method", style = TextStyle(fontSize = 12.sp, fontWeight = FontWeight.SemiBold), color = colors.textSecondary)
                Row(horizontalArrangement = Arrangement.spacedBy(Space.s)) {
                    ai.tokenstat.tokenstat.ui.logic.PullReview.MERGE_METHODS.forEach { method ->
                        if (method == mergeMethod) {
                            TsAccentButton(label = ai.tokenstat.tokenstat.ui.logic.PullReview.mergeTitle(method), small = true, onClick = {})
                        } else {
                            TsSecondaryButton(label = ai.tokenstat.tokenstat.ui.logic.PullReview.mergeTitle(method), small = true, onClick = { onMergeMethod(method) })
                        }
                    }
                }
                TsAccentButton(label = "Merge pull request", small = true, enabled = !view.bol("draft") && !busy, onClick = onMerge)
            }
            TsSecondaryButton(label = "Close pull request", small = true, enabled = !busy, onClick = onClose)
        } else if (view.str("state") == "closed") {
            TsAccentButton(label = "Reopen pull request", small = true, enabled = !busy, onClick = onReopen)
        }
        Column(verticalArrangement = Arrangement.spacedBy(Space.s)) {
            Text("Local checkout", style = TextStyle(fontSize = 12.sp, fontWeight = FontWeight.SemiBold), color = colors.textSecondary)
            OutlinedTextField(
                checkoutBranch,
                onCheckoutBranch,
                modifier = Modifier.fillMaxWidth(),
                placeholder = { Text("Local branch name") },
                singleLine = true,
                textStyle = TsType.mono(12),
            )
            TsSecondaryButton(
                label = "Check out locally",
                small = true,
                enabled = checkoutBranch.trim().isNotEmpty() && !busy,
                onClick = onCheckout,
            )
        }
    }
}

/// A file chosen in the composer and not yet sent. The bytes are carried as
/// base64 because that is what `chat.attach` takes, and they are held only
/// until the message goes.
data class StagedAttachment(
    val name: String,
    val data: String,
    val mediaType: String?,
    val bytes: Int,
)

/// What reading a picked file produced. A failure carries a sentence rather
/// than an exception: the composer shows it and the person picks again.
sealed interface AttachmentRead {
    data class Ok(val attachment: StagedAttachment) : AttachmentRead

    data class Failed(val reason: String) : AttachmentRead
}

/// The host refuses anything larger, so refuse it here instead of spending a
/// person's connection on a transfer that cannot land. Matches
/// `ATTACHMENT_CAP` in `tokenstat-host::chat`.
private const val ATTACHMENT_CAP = 12 * 1024 * 1024

/// Read one picked document into a staged attachment.
///
/// Off the main thread: a picked file can be megabytes, and both the read and
/// the base64 pass are long enough to drop frames.
internal fun readAttachment(context: android.content.Context, uri: android.net.Uri): AttachmentRead {
    val resolver = context.contentResolver
    val name = resolver.query(uri, arrayOf(OpenableColumns.DISPLAY_NAME), null, null, null)?.use { cursor ->
        if (cursor.moveToFirst()) cursor.getString(0) else null
    } ?: uri.lastPathSegment ?: "Attachment"
    val bytes = runCatching {
        resolver.openInputStream(uri)?.use { it.readBytes() }
    }.getOrNull() ?: return AttachmentRead.Failed("$name could not be read.")
    if (bytes.isEmpty()) return AttachmentRead.Failed("$name is empty.")
    if (bytes.size > ATTACHMENT_CAP) {
        return AttachmentRead.Failed("$name is larger than 12 MB, which is the most a chat can carry.")
    }
    return AttachmentRead.Ok(
        StagedAttachment(
            name = name,
            data = Base64.encodeToString(bytes, Base64.NO_WRAP),
            mediaType = resolver.getType(uri),
            bytes = bytes.size,
        ),
    )
}

/// The docked composer, built like the one on iPhone: what the message will
/// be answered by on top, then how much rope the agent has, then the field
/// itself with the paperclip beside it.
///
/// The controls are above the field rather than behind a menu because they
/// change what the next message does. Plan against Execute is the difference
/// between being told and being acted on, and that is not a preference to go
/// hunting for.
@Composable
private fun ChatComposer(
    chat: JsonObject?,
    draft: String,
    onDraft: (String) -> Unit,
    hint: String,
    sending: Boolean,
    staged: List<StagedAttachment>,
    onPick: () -> Unit,
    onRemove: (StagedAttachment) -> Unit,
    onSend: () -> Unit,
    onStop: () -> Unit,
    onSetup: () -> Unit,
    onChange: (String, String) -> Unit,
) {
    val colors = LocalTsColors.current
    val mode = chat?.str("mode") ?: "execute"
    val autonomy = chat?.str("autonomy") ?: "ask"
    TsCard(Modifier.fillMaxWidth()) {
        Column(verticalArrangement = Arrangement.spacedBy(Space.s)) {
            // Agent, model and effort in one line, tappable into setup. The
            // same summary the iPhone puts at the top of its composer.
            Row(
                verticalAlignment = Alignment.CenterVertically,
                modifier = Modifier
                    .fillMaxWidth()
                    .clip(RoundedCornerShape(cardRadiusDp))
                    .clickable { onSetup() }
                    .padding(vertical = 2.dp),
            ) {
                Text(
                    chatSummary(chat),
                    style = TsType.caption,
                    color = colors.textSecondary,
                    maxLines = 1,
                    overflow = TextOverflow.Ellipsis,
                    modifier = Modifier.weight(1f),
                )
                Icon(
                    Icons.AutoMirrored.Filled.KeyboardArrowRight,
                    null,
                    tint = colors.textTertiary,
                    modifier = Modifier.size(16.dp),
                )
            }
            Row(horizontalArrangement = Arrangement.spacedBy(Space.s)) {
                ChatSegmented(
                    options = listOf("plan" to "Plan", "execute" to "Execute"),
                    selected = mode,
                    enabled = !sending,
                    onSelect = { onChange("mode", it) },
                    modifier = Modifier.weight(1f),
                )
                ChatSegmented(
                    options = listOf("ask" to "Ask", "bypass" to "Bypass"),
                    selected = autonomy,
                    enabled = !sending,
                    onSelect = { onChange("autonomy", it) },
                    modifier = Modifier.weight(1f),
                )
            }
            // Staged files sit above the field, each with its own way out, so
            // a wrong pick is one tap to undo rather than a sent message.
            staged.forEach { attachment ->
                Row(
                    verticalAlignment = Alignment.CenterVertically,
                    horizontalArrangement = Arrangement.spacedBy(Space.xs),
                    modifier = Modifier
                        .fillMaxWidth()
                        .clip(RoundedCornerShape(cardRadiusDp))
                        .background(colors.accentSoft)
                        .padding(horizontal = Space.s, vertical = 6.dp),
                ) {
                    Icon(ActionIcon.Attach.vector, null, tint = colors.accent, modifier = Modifier.size(15.dp))
                    Text(
                        attachment.name,
                        style = TsType.caption,
                        color = colors.textPrimary,
                        maxLines = 1,
                        overflow = TextOverflow.Ellipsis,
                        modifier = Modifier.weight(1f),
                    )
                    Text(attachmentSize(attachment.bytes), style = TsType.caption2, color = colors.textSecondary)
                    IconButton(onClick = { onRemove(attachment) }, modifier = Modifier.size(24.dp)) {
                        Icon(
                            ActionIcon.Dismiss.vector,
                            "Remove ${attachment.name}",
                            tint = colors.textSecondary,
                            modifier = Modifier.size(15.dp),
                        )
                    }
                }
            }
            Row(
                verticalAlignment = Alignment.CenterVertically,
                horizontalArrangement = Arrangement.spacedBy(Space.xs),
            ) {
                IconButton(onClick = onPick, enabled = !sending) {
                    Icon(
                        ActionIcon.Attach.vector,
                        "Attach a file",
                        tint = if (sending) colors.textTertiary else colors.accent,
                    )
                }
                OutlinedTextField(
                    draft,
                    onDraft,
                    Modifier.weight(1f),
                    placeholder = { Text(hint) },
                    maxLines = 5,
                )
                if (sending) {
                    IconButton(onClick = onStop) {
                        Icon(ActionIcon.Stop.vector, "Stop", tint = colors.danger)
                    }
                } else {
                    IconButton(
                        onClick = onSend,
                        enabled = draft.isNotBlank() || staged.isNotEmpty(),
                    ) {
                        Icon(
                            ActionIcon.Send.vector,
                            "Send",
                            tint = if (draft.isNotBlank() || staged.isNotEmpty()) colors.accent else colors.textTertiary,
                        )
                    }
                }
            }
        }
    }
}

/// What this conversation is answered by, in one line.
private fun chatSummary(chat: JsonObject?): String {
    val agent = chat?.str("backend")?.let { harnessName(it) } ?: "Agent"
    // Named rather than left blank, the way the iPhone composer reads
    // "OpenCode · Default · Effort: Default". A gap where the model should
    // be looks like something failed to load.
    val model = chat?.str("model")?.ifBlank { null } ?: "Default"
    val effort = chat?.str("effort")?.ifBlank { null } ?: "Default"
    return "$agent · $model · Effort: $effort"
}

private fun attachmentSize(bytes: Int): String = when {
    bytes >= 1024 * 1024 -> "%.1f MB".format(bytes / (1024.0 * 1024.0))
    bytes >= 1024 -> "${bytes / 1024} KB"
    else -> "$bytes B"
}

/// Two choices, one of them on. The iOS composer's paired controls: a
/// bordered capsule with the live half filled, rather than a switch, because
/// neither side is the "off" one.
@Composable
private fun ChatSegmented(
    options: List<Pair<String, String>>,
    selected: String,
    enabled: Boolean,
    onSelect: (String) -> Unit,
    modifier: Modifier = Modifier,
) {
    val colors = LocalTsColors.current
    // Its own outline. Two borderless pairs side by side on the same card
    // read as one four-way control, and "Execute Ask" is not a thing anyone
    // should have to work out is two answers.
    Row(
        modifier
            .clip(RoundedCornerShape(10.dp))
            .border(1.dp, colors.border, RoundedCornerShape(10.dp))
            .padding(2.dp),
    ) {
        options.forEach { (value, label) ->
            val on = value == selected
            Box(
                Modifier
                    .weight(1f)
                    .clip(RoundedCornerShape(8.dp))
                    .background(if (on) colors.accentSoft else Color.Transparent)
                    .clickable(enabled = enabled && !on) { onSelect(value) }
                    .padding(vertical = 7.dp),
                contentAlignment = Alignment.Center,
            ) {
                Text(
                    label,
                    style = TsType.caption.copy(
                        fontWeight = if (on) FontWeight.SemiBold else FontWeight.Normal,
                    ),
                    color = when {
                        on -> colors.accent
                        enabled -> colors.textSecondary
                        else -> colors.textTertiary
                    },
                    maxLines = 1,
                )
            }
        }
    }
}
