// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
package ai.tokenstat.tokenstat.ui.workspace

import androidx.compose.foundation.Canvas
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.shape.RoundedCornerShape
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
import androidx.compose.material3.ElevatedCard
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
) {
    val scope = rememberCoroutineScope()
    var chats by remember(workspace) { mutableStateOf<List<JsonObject>>(emptyList()) }
    var openId by remember(workspace) { mutableStateOf<String?>(null) }
    var creating by remember(workspace) { mutableStateOf(false) }
    var didOpenConversation by remember(workspace, openConversationOnAppear) { mutableStateOf(false) }
    var events by remember(workspace) { mutableStateOf<List<JsonObject>>(emptyList()) }
    var approvals by remember(workspace) { mutableStateOf<List<JsonObject>>(emptyList()) }
    var error by remember(workspace) { mutableStateOf<String?>(null) }
    var loading by remember(workspace) { mutableStateOf(true) }
    var draft by remember(workspace) { mutableStateOf("") }
    var sending by remember { mutableStateOf(false) }
    var search by remember { mutableStateOf("") }
    var agentFilter by remember { mutableStateOf("") }
    var runningOnly by remember { mutableStateOf(false) }
    var alphabetical by remember { mutableStateOf(false) }
    var filterOpen by remember { mutableStateOf(false) }
    var pendingDelete by remember { mutableStateOf<JsonObject?>(null) }
    var pendingSend by remember { mutableStateOf<String?>(null) }
    var showingSetup by remember { mutableStateOf(false) }

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
    LaunchedEffect(workspace) { loadChats() }
    // A navigation that named a conversation: open exactly it, even when
    // this folder's list is already on screen.
    LaunchedEffect(initialChatId, workspace) {
        if (initialChatId != null) openId = initialChatId
    }
    // The launcher's promise: arriving to start work opens the conversation
    // worth returning to, or starts one when there is none.
    LaunchedEffect(loading, openConversationOnAppear) {
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
        SectionLabel("Conversations")
        if (!HostContracts.supportsChat(protocol)) {
            Text("Update the host to use chat (needs protocol 4).", style = MaterialTheme.typography.bodySmall)
            return
        }
        if (error != null) Banner(error!!, BannerSeverity.DANGER)
        if (openId == null) {
            Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                TsAccentButton(
                    label = if (creating) "Starting…" else "New chat",
                    small = true,
                    enabled = !creating,
                    onClick = { scope.launch { createAndOpen() } },
                )
                TextButton(onClick = { scope.launch { loadChats() } }) { Text("Refresh") }
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
            LazyColumn(verticalArrangement = Arrangement.spacedBy(6.dp)) {
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
                        ElevatedCard(onClick = { openId = chat.str("id") }, modifier = Modifier.fillMaxWidth()) {
                            ChatRow(chat)
                        }
                    }
                }
            }
        } else {
            TextButton(onClick = { openId = null; scope.launch { loadChats() } }) { Text("← All conversations") }
            Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                TextButton(onClick = { showingSetup = true }) { Text("Setup") }
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
                            }
                            openId?.let { loadEvents(it) }
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
            LazyColumn(Modifier.weight(1f, false), verticalArrangement = Arrangement.spacedBy(6.dp)) {
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
            if (pendingSend != null) {
                Banner("A previous send needs confirmation. Return to the live conversation to check it.", BannerSeverity.WARNING)
                Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                    TsSecondaryButton(label = "Check", small = true, onClick = {
                        val id = openId ?: return@TsSecondaryButton
                        val messageId = pendingSend ?: return@TsSecondaryButton
                        scope.launch {
                            runCatching {
                                model.workspaceSection(peer, "chat.receipt", buildJsonObject {
                                    put("id", id); put("clientMessageId", messageId)
                                }) as? JsonObject
                            }.onSuccess { receipt ->
                                if ((receipt?.str("state") ?: "unknown") != "unknown") {
                                    pendingSend = null
                                    loadEvents(id)
                                }
                            }
                        }
                    })
                    TextButton(onClick = { pendingSend = null }) { Text("Dismiss") }
                }
            }
            Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                OutlinedTextField(draft, { draft = it }, Modifier.weight(1f), placeholder = { Text("Ask about this folder") })
                if (sending) {
                    TsSecondaryButton(label = "Stop", small = true, onClick = {
                        val id = openId ?: return@TsSecondaryButton
                        scope.launch {
                            runCatching {
                                model.workspaceSection(peer, "chat.stop", buildJsonObject { put("id", id) })
                            }
                            sending = false
                        }
                    })
                } else {
                    TsAccentButton(label = "Send", small = true, onClick = {
                        val id = openId ?: return@TsAccentButton
                        val text = draft.trim(); if (text.isEmpty()) return@TsAccentButton
                        sending = true
                        scope.launch {
                            val messageId = java.util.UUID.randomUUID().toString()
                            runCatching {
                                model.workspaceSection(peer, "chat.send", buildJsonObject {
                                    put("id", id); put("text", text)
                                    put("clientMessageId", messageId)
                                    put("clientMessageCreatedAtMs", System.currentTimeMillis())
                                })
                            }.onSuccess { draft = ""; loadEvents(id) }
                                .onFailure { pendingSend = messageId }
                            sending = false
                        }
                    })
                }
            }
            Text("Times shown relatively; full transcript pinning ships next.", style = MaterialTheme.typography.labelSmall)
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
    Row(horizontalArrangement = Arrangement.spacedBy(Space.s)) {
        panels.forEach { (label, value, mark) ->
            TsCard(Modifier.weight(1f)) {
                Row(verticalAlignment = Alignment.CenterVertically) {
                    Column(Modifier.weight(1f)) {
                        Text(value, style = TsType.numeric(20, FontWeight.Medium), color = colors.accent, maxLines = 1)
                        Text(label, style = TsType.caption2, color = colors.textSecondary, maxLines = 1)
                    }
                    Icon(mark, null, tint = colors.controlGlyph, modifier = Modifier.size(22.dp))
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
                RelativeTimeText(atMs, style = MaterialTheme.typography.bodySmall, color = colors.textSecondary)
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
    var instructions by remember { mutableStateOf<String?>(null) }
    var personas by remember { mutableStateOf<List<JsonObject>>(emptyList()) }
    var defaultId by remember { mutableStateOf<String?>(null) }
    var error by remember { mutableStateOf<String?>(null) }
    var loading by remember { mutableStateOf(true) }

    suspend fun load() {
        loading = true
        runCatching {
            model.workspaceSection(peer, "chat.instructions", buildJsonObject { put("id", chatId) })
        }.onSuccess { element ->
            instructions = (element as? JsonObject)?.str("instructions") ?: element.toString()
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

    Dialog(onDismissRequest = onDismiss, properties = DialogProperties(usePlatformDefaultWidth = false)) {
        Column(
            Modifier
                .fillMaxWidth()
                .padding(Space.m),
            verticalArrangement = Arrangement.spacedBy(Space.m),
        ) {
            Text("Chat setup", style = TextStyle(fontSize = 17.sp, fontWeight = FontWeight.SemiBold), color = LocalTsColors.current.textPrimary)
            if (error != null) Banner(error!!, BannerSeverity.DANGER)
            if (loading) {
                Text("Loading…", color = LocalTsColors.current.textSecondary)
            } else {
                instructions?.let {
                    Column(verticalArrangement = Arrangement.spacedBy(Space.xs)) {
                        SectionLabel("Instructions")
                        Text(it.ifBlank { "No instructions." }, style = TextStyle(fontSize = 14.sp), color = LocalTsColors.current.textSecondary)
                    }
                }
                Column(verticalArrangement = Arrangement.spacedBy(Space.xs)) {
                    SectionLabel("Personas", personas.size)
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
            TsSecondaryButton(label = "Done", small = true, onClick = onDismiss)
        }
    }
}

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
    Column(modifier, verticalArrangement = Arrangement.spacedBy(8.dp)) {
        SectionLabel("Pull requests")
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
        if (error != null) Banner(error!!, BannerSeverity.DANGER)
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
        LazyColumn(verticalArrangement = Arrangement.spacedBy(6.dp)) {
            items(pulls, key = { it.get("number")?.jsonPrimitive?.longOrNull?.toString() ?: it.hashCode().toString() }) { pr ->
                val number = pr.get("number")?.jsonPrimitive?.longOrNull ?: return@items
                ElevatedCard(onClick = { openNumber = number }) {
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
    val opened = openNumber
    if (opened != null) {
        PullDetailDialog(
            model = model,
            peer = peer,
            workspace = workspace,
            hostLabel = hostLabel,
            number = opened,
            onDismiss = { openNumber = null },
        )
    }
}

/// One pull request in full: what it says, who wrote it, the refs, the
/// counts, and the checks summary.
@Composable
private fun PullDetailDialog(
    model: AppViewModel,
    peer: String,
    workspace: String,
    hostLabel: String,
    number: Long,
    onDismiss: () -> Unit,
) {
    var detail by remember(number) { mutableStateOf<JsonObject?>(null) }
    var error by remember(number) { mutableStateOf<String?>(null) }
    var loading by remember(number) { mutableStateOf(true) }
    LaunchedEffect(number) {
        runCatching {
            model.workspaceSection(peer, "pulls.view", buildJsonObject {
                put("workspaceId", workspace); put("number", number)
            }) as? JsonObject
        }.onSuccess { detail = it; error = null }
            .onFailure { error = TunnelCopy.display(it.message ?: "The request failed.", hostLabel) }
        loading = false
    }
    Dialog(onDismissRequest = onDismiss, properties = DialogProperties(usePlatformDefaultWidth = false)) {
        Column(
            Modifier
                .fillMaxWidth()
                .padding(Space.m),
            verticalArrangement = Arrangement.spacedBy(Space.m),
        ) {
            Text("#$number", style = TsType.mono(13), color = LocalTsColors.current.textSecondary)
            if (error != null) Banner(error!!, BannerSeverity.DANGER)
            if (loading) {
                Text("Loading…", color = LocalTsColors.current.textSecondary)
            } else if (detail != null) {
                val view = (detail!!.get("pull") as? JsonObject) ?: detail!!
                Column(
                    Modifier
                        .fillMaxWidth()
                        .clip(RoundedCornerShape(cardRadiusDp))
                        .background(LocalTsColors.current.panel)
                        .padding(Space.m),
                    verticalArrangement = Arrangement.spacedBy(Space.s),
                ) {
                    Text(
                        view.str("title") ?: "",
                        style = TextStyle(fontSize = 16.sp, fontWeight = FontWeight.SemiBold),
                        color = LocalTsColors.current.textPrimary,
                    )
                    (view.str("body") ?: "").takeIf { it.isNotBlank() }?.let {
                        Text(it.take(800), style = TextStyle(fontSize = 14.sp), color = LocalTsColors.current.textSecondary)
                    }
                    Text(
                        "${view.str("headRef") ?: ""} → ${view.str("baseRef") ?: ""}",
                        style = TsType.mono(12),
                        color = LocalTsColors.current.textSecondary,
                    )
                    Row(horizontalArrangement = Arrangement.spacedBy(Space.s)) {
                        view.long("additions")?.let {
                            Text("+$it", style = TsType.numeric(12), color = LocalTsColors.current.diffAdded)
                        }
                        view.long("deletions")?.let {
                            Text("−$it", style = TsType.numeric(12), color = LocalTsColors.current.diffRemoved)
                        }
                        view.long("changedFiles")?.let {
                            Text("$it files", style = TextStyle(fontSize = 12.sp), color = LocalTsColors.current.textSecondary)
                        }
                    }
                    (view.str("checks") ?: (view.get("checks") as? JsonObject)?.str("state"))?.takeIf { it.isNotBlank() }?.let {
                        Text("Checks: $it", style = TextStyle(fontSize = 12.sp), color = LocalTsColors.current.textSecondary)
                    }
                }
            }
            TsSecondaryButton(label = "Close", small = true, onClick = onDismiss)
        }
    }
}
