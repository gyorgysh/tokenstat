// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
package ai.tokenstat.tokenstat.ui.workspace

import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.ChatBubbleOutline
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.Card
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.ElevatedCard
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.text.TextStyle
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.compose.ui.window.Dialog
import androidx.compose.ui.window.DialogProperties
import ai.tokenstat.tokenstat.AppViewModel
import ai.tokenstat.tokenstat.ui.components.Banner
import ai.tokenstat.tokenstat.ui.components.BannerSeverity
import ai.tokenstat.tokenstat.ui.components.EmptyState
import ai.tokenstat.tokenstat.ui.components.RelativeTimeText
import ai.tokenstat.tokenstat.ui.components.SectionLabel
import ai.tokenstat.tokenstat.ui.components.TsAccentButton
import ai.tokenstat.tokenstat.ui.components.TsSecondaryButton
import ai.tokenstat.tokenstat.ui.components.TsSearchField
import ai.tokenstat.tokenstat.ui.components.TsType
import ai.tokenstat.tokenstat.ui.components.cardRadiusDp
import ai.tokenstat.tokenstat.ui.logic.HostContracts
import ai.tokenstat.tokenstat.ui.logic.TunnelCopy
import ai.tokenstat.tokenstat.ui.logic.friendlyError
import ai.tokenstat.tokenstat.ui.theme.LocalTsColors
import ai.tokenstat.tokenstat.ui.theme.Space
import kotlinx.coroutines.launch
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonObject
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
) {
    val scope = rememberCoroutineScope()
    var chats by remember(workspace) { mutableStateOf<List<JsonObject>>(emptyList()) }
    var openId by remember(workspace) { mutableStateOf<String?>(null) }
    var events by remember(workspace) { mutableStateOf<List<JsonObject>>(emptyList()) }
    var approvals by remember(workspace) { mutableStateOf<List<JsonObject>>(emptyList()) }
    var error by remember(workspace) { mutableStateOf<String?>(null) }
    var loading by remember(workspace) { mutableStateOf(true) }
    var draft by remember(workspace) { mutableStateOf("") }
    var sending by remember { mutableStateOf(false) }
    var search by remember { mutableStateOf("") }
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
    LaunchedEffect(workspace) { loadChats() }
    LaunchedEffect(openId) {
        val id = openId ?: return@LaunchedEffect
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
                TsAccentButton(label = "New chat", small = true, onClick = {
                    scope.launch {
                        runCatching {
                            model.workspaceSection(peer, "chat.create", buildJsonObject {
                                put("workspaceId", workspace); put("backend", "opencode")
                            })
                        }.onSuccess { loadChats() }
                    }
                })
                TextButton(onClick = { scope.launch { loadChats() } }) { Text("Refresh") }
            }
            if (loading) { CircularProgressIndicator(Modifier, strokeWidth = 2.dp); return }
            if (chats.isEmpty()) {
                EmptyState(
                    Icons.Default.ChatBubbleOutline,
                    "Start a chat",
                    "Ask an agent to explore, plan, or work in $place.",
                    action = {
                        TsAccentButton(label = "New chat", small = true, onClick = {
                            scope.launch {
                                runCatching {
                                    model.workspaceSection(peer, "chat.create", buildJsonObject {
                                        put("workspaceId", workspace); put("backend", "opencode")
                                    })
                                }.onSuccess { loadChats() }
                            }
                        })
                    },
                )
                return
            }
            TsSearchField(prompt = "Titles, agents, or models", query = search, onQueryChange = { search = it }, modifier = Modifier.fillMaxWidth())
            val query = search.trim()
            val shown = chats.filter {
                query.isEmpty() ||
                    (it.str("title") ?: "").contains(query, ignoreCase = true) ||
                    (it.str("backend") ?: "").contains(query, ignoreCase = true) ||
                    (it.str("model") ?: "").contains(query, ignoreCase = true)
            }
            val running = chats.count { it.bol("running") }
            Text(
                "${shown.size} shown" + if (running > 0) " · $running running" else "",
                style = TextStyle(fontSize = 12.sp),
                color = LocalTsColors.current.textSecondary,
            )
            if (shown.isEmpty()) {
                Text("No matching conversations. Adjust your search or filters.", style = MaterialTheme.typography.bodySmall)
                return
            }
            LazyColumn(verticalArrangement = Arrangement.spacedBy(6.dp)) {
                items(shown, key = { it.str("id") ?: it.hashCode().toString() }) { chat ->
                    ElevatedCard(onClick = { openId = chat.str("id") }) {
                        Column(Modifier.padding(12.dp)) {
                            Text(chat.str("title") ?: "Untitled", style = MaterialTheme.typography.titleSmall)
                            Text(
                                listOfNotNull(chat.str("backend"), chat.str("model")).joinToString(" · "),
                                style = MaterialTheme.typography.bodySmall,
                            )
                            Row {
                                TextButton(onClick = { pendingDelete = chat }) { Text("Delete") }
                            }
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
            LazyColumn(Modifier.weight(1f, false), verticalArrangement = Arrangement.spacedBy(6.dp)) {
                items(events, key = { it.str("seq") ?: it.hashCode().toString() }) { ev ->
                    ChatEventRow(
                        ev = ev,
                        model = model,
                        peer = peer,
                        chatId = openId ?: "",
                        hostLabel = hostLabel,
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

/// One transcript event, drawn by kind like `ClientChatEventRow`: user and
/// assistant prose, thinking as an aside, tool calls with their target,
/// attachments with Download/Open, handoffs with the brief, approvals with
/// Allow/Deny, usage as counts, failures in danger.
@Composable
private fun ChatEventRow(
    ev: JsonObject,
    model: AppViewModel,
    peer: String,
    chatId: String,
    hostLabel: String,
) {
    val scope = rememberCoroutineScope()
    val kind = (ev.str("kind") ?: ev.str("role") ?: "event").lowercase()
    val inner = ev["event"] as? JsonObject
    val timeMs = ev["atMs"]?.jsonPrimitive?.longOrNull
        ?: ev["at_ms"]?.jsonPrimitive?.longOrNull
        ?: inner?.get("atMs")?.jsonPrimitive?.longOrNull
    val colors = LocalTsColors.current

    @Composable
    fun frame(label: String, content: @Composable () -> Unit) {
        Card {
            Column(Modifier.padding(10.dp)) {
                Row(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.SpaceBetween) {
                    Text(label, style = MaterialTheme.typography.labelSmall)
                    if (timeMs != null && timeMs > 0) {
                        RelativeTimeText(
                            timeMs,
                            style = MaterialTheme.typography.labelSmall,
                            color = MaterialTheme.colorScheme.outline,
                        )
                    }
                }
                content()
            }
        }
    }

    when (kind) {
        "user" -> {
            val text = ev.str("text") ?: ev.str("body") ?: ""
            Row(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.End) {
                Text(
                    text,
                    style = TextStyle(fontSize = 14.sp),
                    color = colors.textPrimary,
                    modifier = Modifier
                        .clip(RoundedCornerShape(16.dp))
                        .background(colors.accentSoft)
                        .padding(Space.m),
                )
            }
        }
        "thinking" -> {
            val text = ev.str("text") ?: inner?.str("text") ?: ""
            Text(text, style = TextStyle(fontSize = 12.sp), color = colors.textSecondary)
        }
        "tool" -> {
            val verb = inner?.str("verb") ?: ev.str("verb") ?: "Tool"
            val target = inner?.str("target") ?: ev.str("target") ?: ""
            val snippet = inner?.str("snippet") ?: ""
            val failed = inner?.bol("failed") ?: ev.bol("failed") ?: false
            val running = inner?.bol("running") ?: ev.bol("running") ?: false
            frame("$verb${if (running) " · running" else ""}") {
                if (target.isNotBlank()) {
                    Text(target, style = TsType.mono(12), color = colors.textPrimary)
                }
                if (snippet.isNotBlank()) {
                    Text(snippet, style = TextStyle(fontSize = 12.sp), color = colors.textSecondary, maxLines = 4)
                }
                if (failed) Text("Failed", style = TextStyle(fontSize = 12.sp), color = colors.danger)
            }
        }
        "edit" -> {
            val target = inner?.str("target") ?: ev.str("target") ?: "Edit"
            frame("Edit") {
                Text(target, style = TsType.mono(12), color = colors.textPrimary, maxLines = 6)
            }
        }
        "attachment" -> {
            val name = inner?.str("name") ?: ev.str("name") ?: "Attachment"
            val attachmentId = inner?.str("id") ?: inner?.str("attachmentId") ?: ev.str("attachmentId") ?: ""
            var downloaded by remember(attachmentId) { mutableStateOf(false) }
            var busy by remember(attachmentId) { mutableStateOf(false) }
            var failure by remember(attachmentId) { mutableStateOf<String?>(null) }
            frame("Attachment") {
                Text(name, style = TextStyle(fontSize = 14.sp, fontWeight = FontWeight.Medium), color = colors.textPrimary, maxLines = 1)
                val detail = listOfNotNull(
                    inner?.str("mediaType") ?: inner?.str("media_type"),
                    inner?.get("size")?.jsonPrimitive?.longOrNull?.let { "$it bytes" },
                ).joinToString(" · ")
                if (detail.isNotBlank()) {
                    Text(detail, style = TextStyle(fontSize = 12.sp), color = colors.textSecondary)
                }
                if (failure != null) {
                    Text(failure!!, style = TextStyle(fontSize = 12.sp), color = colors.danger)
                }
                if (downloaded) {
                    Text("Downloaded", style = TextStyle(fontSize = 12.sp), color = colors.accent)
                } else {
                    TsSecondaryButton(
                        label = if (busy) "…" else if (failure == null) "Download" else "Retry",
                        small = true,
                        enabled = !busy && attachmentId.isNotBlank(),
                        onClick = {
                            busy = true
                            scope.launch {
                                runCatching {
                                    model.workspaceSection(peer, "chat.attachment", buildJsonObject {
                                        put("id", chatId); put("attachmentId", attachmentId)
                                    }) as? JsonObject
                                }.onSuccess {
                                    downloaded = (it?.get("data")?.jsonPrimitive?.contentOrNull?.length ?: 0) > 0
                                    failure = null
                                }.onFailure {
                                    failure = TunnelCopy.display(it.message ?: "The request failed.", hostLabel)
                                }
                                busy = false
                            }
                        },
                    )
                }
            }
        }
        "handoff" -> {
            val to = inner?.str("to") ?: ev.str("to") ?: ""
            val brief = inner?.str("brief") ?: ev.str("brief") ?: ""
            var expanded by remember { mutableStateOf(false) }
            Column(
                Modifier
                    .fillMaxWidth()
                    .padding(vertical = Space.xs),
                verticalArrangement = Arrangement.spacedBy(Space.xs),
            ) {
                Row(horizontalArrangement = Arrangement.spacedBy(Space.s)) {
                    Text(
                        "Handed to ${to.ifBlank { "another agent" }}",
                        style = TextStyle(fontSize = 12.sp, fontWeight = FontWeight.Medium),
                        color = colors.accent,
                        modifier = Modifier.weight(1f),
                    )
                    if (brief.isNotBlank()) {
                        Text(
                            if (expanded) "Hide" else "What it was told",
                            style = TextStyle(fontSize = 12.sp),
                            color = colors.textSecondary,
                            modifier = Modifier.clickable { expanded = !expanded },
                        )
                    }
                }
                if (expanded && brief.isNotBlank()) {
                    Text(brief, style = TsType.mono(11), color = colors.textSecondary)
                }
            }
        }
        "approval" -> {
            val approval = inner ?: ev
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
                    }
                },
            )
        }
        "usage" -> {
            val input = inner?.get("input")?.jsonPrimitive?.longOrNull ?: ev["input"]?.jsonPrimitive?.longOrNull
            val output = inner?.get("output")?.jsonPrimitive?.longOrNull ?: ev["output"]?.jsonPrimitive?.longOrNull
            val cost = inner?.str("cost") ?: ev.str("cost")
            if (input != null || output != null) {
                Text(
                    "${input ?: 0} in · ${output ?: 0} out" + (cost?.let { " · $it" } ?: ""),
                    style = TextStyle(fontSize = 12.sp),
                    color = colors.textSecondary,
                )
            }
        }
        "failed", "error" -> {
            val text = ev.str("text") ?: inner?.str("text") ?: ev.str("body") ?: "Something failed."
            Text(text, style = TextStyle(fontSize = 14.sp), color = colors.danger)
        }
        "turn", "separator" -> {
            val backend = ev.str("backend") ?: inner?.str("backend") ?: ""
            Text(
                if (backend.isNotBlank()) "$backend · new turn" else "New turn",
                style = TextStyle(fontSize = 12.sp, fontWeight = FontWeight.Medium),
                color = colors.accent,
            )
        }
        else -> {
            val text = ev.str("text")
                ?: inner?.str("delta")
                ?: inner?.str("text")
                ?: inner?.str("target")?.let { target -> "${inner.str("verb") ?: "Tool"}: $target" }
                ?: inner?.str("name")?.let { name -> "Attachment: $name" }
                ?: ev.str("body")
                ?: ""
            if (text.isNotEmpty()) {
                frame(kind) {
                    Text(text, style = MaterialTheme.typography.bodySmall)
                }
            }
        }
    }
}

/// A tool approval awaiting an answer: verb, preview, and Allow, Always
/// allow, Deny. Decided approvals read back their outcome instead.
@Composable
private fun ApprovalCard(approval: JsonObject, onResolve: (String) -> Unit) {
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
                        view.get("additions")?.jsonPrimitive?.longOrNull?.let {
                            Text("+$it", style = TsType.numeric(12), color = LocalTsColors.current.diffAdded)
                        }
                        view.get("deletions")?.jsonPrimitive?.longOrNull?.let {
                            Text("−$it", style = TsType.numeric(12), color = LocalTsColors.current.diffRemoved)
                        }
                        view.get("changedFiles")?.jsonPrimitive?.longOrNull?.let {
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
