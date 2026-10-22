// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
package ai.tokenstat.tokenstat.ui.team

import ai.tokenstat.tokenstat.core.CoreClient
import ai.tokenstat.tokenstat.ui.components.ActionIcon
import ai.tokenstat.tokenstat.ui.components.EmptyState
import ai.tokenstat.tokenstat.ui.components.TsAccentButton
import ai.tokenstat.tokenstat.ui.components.TsCard
import ai.tokenstat.tokenstat.ui.components.TsDangerButton
import ai.tokenstat.tokenstat.ui.components.TsSecondaryButton
import ai.tokenstat.tokenstat.ui.components.TsType
import ai.tokenstat.tokenstat.ui.localization.L10n
import ai.tokenstat.tokenstat.ui.logic.WatchingOwner
import ai.tokenstat.tokenstat.ui.theme.LocalTsColors
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.asImageBitmap
import androidx.compose.ui.platform.LocalUriHandler
import androidx.compose.ui.unit.dp
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.contentOrNull
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.put
import java.util.UUID

/// Every Team call carries the signed-in account's receipt. The host drops a
/// call when that login is no longer the one it was made for.
private class TeamCalls(account: JsonObject?) {
    private val owner = WatchingOwner.from(account)

    suspend fun call(method: String, fields: JsonObject = buildJsonObject {}): JsonObject {
        val owner = owner ?: throw IllegalStateException(L10n.text("common.teams.load_failed"))
        val params = buildJsonObject {
            for ((key, value) in fields) put(key, value)
            put("_accountScope", owner.scope)
            owner.receipt?.let { put("_accountSession", it) }
        }
        return CoreClient.call(method, params) as? JsonObject ?: JsonObject(emptyMap())
    }

    suspend fun directory(operation: String, extra: JsonObject.() -> JsonObject = { this }): JsonObject =
        call("teams.directory", buildJsonObject {
            put("operation", operation)
            put("page", buildJsonObject { put("limit", 100); put("offset", 0) })
        }.extra())
}

private fun JsonObject.str(key: String): String? = (this[key] as? JsonPrimitive)?.contentOrNull
private fun JsonObject.bool(key: String): Boolean = str(key) == "true"
private fun JsonObject.list(key: String): List<JsonObject> =
    (this[key] as? JsonArray)?.mapNotNull { it as? JsonObject } ?: emptyList()
private fun JsonObject.with(vararg pairs: Pair<String, JsonElement>): JsonObject =
    JsonObject(this + pairs)

private fun target(org: String, repo: String, checkout: String, share: String? = null): JsonObject = buildJsonObject {
    put("organization", org); put("repository", repo); put("checkout", checkout)
    share?.let { put("share", it) }
}

private sealed interface Phase {
    data object Loading : Phase
    data object Unavailable : Phase
    data object Authorize : Phase
    data class Failed(val message: String) : Phase
    data object Ready : Phase
}

/// The Team tab on Android: the member's side of Teams. Publishing a project
/// and choosing how its work lands happen on the computer that owns it.
@Composable
fun TeamScreen(account: JsonObject?) {
    // The account object is refreshed often. Only a different login or
    // session starts the screen over.
    val owner = WatchingOwner.from(account)
    val identity = owner?.let { it.scope.toString() + "|" + it.receipt }
    val calls = remember(identity) { TeamCalls(account) }
    val scope = rememberCoroutineScope()
    var phase by remember(identity) { mutableStateOf<Phase>(Phase.Loading) }
    var organizations by remember(identity) { mutableStateOf<List<JsonObject>>(emptyList()) }
    var organization by remember(identity) { mutableStateOf<JsonObject?>(null) }
    var chat by remember(identity) { mutableStateOf<ChatTarget?>(null) }

    suspend fun load() {
        phase = Phase.Loading
        phase = try {
            val capabilities = calls.call("teams.capabilities")
            when {
                !capabilities.bool("enabled") -> Phase.Unavailable
                !capabilities.bool("ready") -> Phase.Authorize
                else -> {
                    organizations = calls.directory("organizations.list").list("organizations")
                    if (organization == null) organization = organizations.singleOrNull()
                    Phase.Ready
                }
            }
        } catch (cancelled: CancellationException) {
            throw cancelled
        } catch (error: Throwable) {
            Phase.Failed(error.message ?: L10n.text("common.teams.load_failed"))
        }
    }
    LaunchedEffect(identity) { load() }

    val current = chat
    if (current != null) {
        TeamChatReader(calls, current, onBack = { chat = null })
        return
    }
    Column(Modifier.fillMaxSize().padding(horizontal = 16.dp), verticalArrangement = Arrangement.spacedBy(12.dp)) {
        Text(L10n.text("common.teams.title"), style = TsType.cardTitle,
            color = LocalTsColors.current.textPrimary, modifier = Modifier.padding(top = 16.dp))
        when (val state = phase) {
            Phase.Loading -> CircularProgressIndicator()
            Phase.Unavailable -> EmptyState(title = L10n.text("common.teams.load_failed"), message = L10n.text("common.teams.retry_detail"))
            Phase.Authorize -> AuthorizeCard(calls) { scope.launch { load() } }
            is Phase.Failed -> EmptyState(title = L10n.text("common.teams.load_failed"), message = state.message, action = {
                TsAccentButton(L10n.text("common.retry"), onClick = { scope.launch { load() } }, icon = ActionIcon.Refresh.vector)
            })
            Phase.Ready -> {
                val org = organization
                if (org == null) {
                    if (organizations.isEmpty()) {
                        EmptyState(title = L10n.text("common.teams.no_organizations"), message = L10n.text("common.teams.no_organizations_detail"))
                    } else {
                        LazyColumn(verticalArrangement = Arrangement.spacedBy(8.dp)) {
                            items(organizations, key = { it.str("id") ?: "" }) { row ->
                                TsSecondaryButton(row.str("name") ?: "", onClick = { organization = row }, icon = ActionIcon.Next.vector)
                            }
                        }
                    }
                } else {
                    if (organizations.size > 1) {
                        TsSecondaryButton(L10n.text("common.teams.organizations"), onClick = { organization = null }, icon = ActionIcon.Back.vector)
                    }
                    Repositories(calls, org, onOpenChat = { chat = it })
                }
            }
        }
    }
}

@Composable
private fun AuthorizeCard(calls: TeamCalls, onDone: () -> Unit) {
    val scope = rememberCoroutineScope()
    val uri = LocalUriHandler.current
    var error by remember { mutableStateOf<String?>(null) }
    var busy by remember { mutableStateOf(false) }
    TsCard(title = L10n.text("common.teams.enable_title"), subtitle = L10n.text("common.teams.device_consent_detail")) {
        Text(L10n.text("common.teams.metadata_disclosure"), color = LocalTsColors.current.textSecondary)
        error?.let { Text(it, color = LocalTsColors.current.danger) }
        Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
            TsAccentButton(L10n.text("common.teams.continue_browser"), enabled = !busy, icon = ActionIcon.External.vector, onClick = {
                scope.launch {
                    busy = true
                    try {
                        val preview = calls.call("teams.authorizationPreview")
                        val prepared = calls.call("teams.prepareAuthorization", buildJsonObject {
                            put("confirmMetadata", true); put("expectedDeviceKey", preview.str("deviceKey") ?: "")
                        })
                        prepared.str("authorizationURL")?.let { uri.openUri(it) }
                    } catch (cancelled: CancellationException) {
                        throw cancelled
                    } catch (failure: Throwable) {
                        error = failure.message
                    } finally {
                        busy = false
                    }
                }
            })
            TsSecondaryButton(L10n.text("common.refresh"), onClick = onDone, icon = ActionIcon.Refresh.vector)
        }
    }
}

private data class CommentAttempt(val text: String, val id: String, val createdAtMs: Long)

data class ChatTarget(val target: JsonObject, val title: String, val computer: String)

@Composable
private fun Repositories(calls: TeamCalls, org: JsonObject, onOpenChat: (ChatTarget) -> Unit) {
    val orgId = org.str("id") ?: return
    var repositories by remember(orgId) { mutableStateOf<List<JsonObject>?>(null) }
    var error by remember(orgId) { mutableStateOf<String?>(null) }
    LaunchedEffect(orgId) {
        try {
            repositories = calls.directory("repositories.list") { with("organization" to JsonPrimitive(orgId)) }.list("repositories")
        } catch (cancelled: CancellationException) {
            throw cancelled
        } catch (failure: Throwable) {
            error = failure.message
        }
    }
    Text(org.str("name") ?: "", style = TsType.cardTitle, color = LocalTsColors.current.textPrimary)
    error?.let { Text(it, color = LocalTsColors.current.danger) }
    val rows = repositories
    when {
        rows == null && error == null -> CircularProgressIndicator()
        rows != null && rows.isEmpty() -> EmptyState(title = L10n.text("common.teams.no_repositories"), message = L10n.text("common.teams.no_repositories_member"))
        rows != null -> LazyColumn(verticalArrangement = Arrangement.spacedBy(12.dp)) {
            items(rows, key = { it.str("id") ?: "" }) { repo -> RepositoryCard(calls, orgId, repo, onOpenChat) }
        }
    }
}

@Composable
private fun RepositoryCard(calls: TeamCalls, orgId: String, repo: JsonObject, onOpenChat: (ChatTarget) -> Unit) {
    val repoId = repo.str("id") ?: return
    val scope = rememberCoroutineScope()
    var checkouts by remember(repoId) { mutableStateOf<List<JsonObject>>(emptyList()) }
    var lanes by remember(repoId) { mutableStateOf<Map<String, List<JsonObject>>>(emptyMap()) }
    var shares by remember(repoId) { mutableStateOf<Map<String, List<JsonObject>>>(emptyMap()) }
    var message by remember(repoId) { mutableStateOf<String?>(null) }
    var busy by remember(repoId) { mutableStateOf(false) }
    var newTitles by remember(repoId) { mutableStateOf<Map<String, String>>(emptyMap()) }
    // Kept per title so a retry after a lost reply settles to the same chat.
    var newRequest by remember(repoId) { mutableStateOf<Pair<String, String>?>(null) }

    suspend fun load() {
        if (repo.str("role") == null) return
        checkouts = try {
            calls.directory("checkouts.list") {
                with("organization" to JsonPrimitive(orgId), "repository" to JsonPrimitive(repoId))
            }.list("checkouts").take(3)
        } catch (cancelled: CancellationException) {
            throw cancelled
        } catch (_: Throwable) {
            emptyList()
        }
        // Each computer answers for its own lanes and chats. One that is
        // offline shows nothing rather than an error here.
        val nextLanes = mutableMapOf<String, List<JsonObject>>()
        val nextShares = mutableMapOf<String, List<JsonObject>>()
        for (checkout in checkouts) {
            val id = checkout.str("id") ?: continue
            val where = target(orgId, repoId, id)
            runCatching {
                calls.call("teams.connection.call", buildJsonObject {
                    put("target", where); put("method", "team.lanes"); put("params", buildJsonObject {})
                }).list("lanes")
            }.getOrNull()?.let { nextLanes[id] = it }
            runCatching {
                calls.call("teams.connection.call", buildJsonObject {
                    put("target", where); put("method", "team.chat.catalog"); put("params", buildJsonObject { put("limit", 50) })
                }).list("shares")
            }.getOrNull()?.let { nextShares[id] = it }
        }
        lanes = nextLanes; shares = nextShares
    }
    LaunchedEffect(repoId) { load() }

    fun act(method: String, checkout: String, lane: JsonObject) {
        val share = lane.str("share") ?: return
        val branch = lane.str("branch") ?: return
        scope.launch {
            busy = true
            message = try {
                val result = calls.call("teams.ask", buildJsonObject {
                    put("target", target(orgId, repoId, checkout, share)); put("method", method)
                    put("params", buildJsonObject { put("branch", branch) })
                })
                result.str("message") ?: if (result.bool("discarded")) L10n.text("common.teams.lane_discarded") else null
            } catch (cancelled: CancellationException) {
                throw cancelled
            } catch (failure: Throwable) {
                failure.message
            }
            busy = false
            load()
        }
    }

    fun startChat(checkout: String, computer: String) {
        val title = newTitles[checkout].orEmpty().trim()
        if (title.isEmpty()) return
        val request = newRequest?.takeIf { it.first == title } ?: (title to "new-" + UUID.randomUUID()).also { newRequest = it }
        scope.launch {
            busy = true
            try {
                val made = calls.call("teams.ask", buildJsonObject {
                    put("target", target(orgId, repoId, checkout)); put("method", "team.chat.new")
                    put("params", buildJsonObject { put("title", title); put("requestId", request.second) })
                })
                newTitles = newTitles - checkout; newRequest = null
                made.str("share")?.let { onOpenChat(ChatTarget(target(orgId, repoId, checkout, it), title, computer)) }
            } catch (cancelled: CancellationException) {
                throw cancelled
            } catch (failure: Throwable) {
                message = failure.message
            } finally {
                busy = false
            }
        }
    }

    TsCard(title = repo.str("name") ?: "", subtitle = if (repo.str("role") == null) L10n.text("common.teams.no_access") else null) {
        message?.let { Text(it, color = LocalTsColors.current.textSecondary) }
        if (repo.str("role") != null && checkouts.isEmpty()) {
            Text(L10n.text("common.teams.repository_not_shared"), color = LocalTsColors.current.textSecondary)
        }
        val allLanes = checkouts.flatMap { lanes[it.str("id")] ?: emptyList() }
        for (checkout in checkouts) {
            val id = checkout.str("id") ?: continue
            val computer = checkout.str("deviceName") ?: L10n.text("common.teams.computer")
            Text(computer, color = LocalTsColors.current.textPrimary, modifier = Modifier.padding(top = 4.dp))
            for (lane in lanes[id].orEmpty()) {
                LaneRow(lane, allLanes, busy, onLand = { act("team.lanes.land", id, lane) }, onDiscard = { act("team.lanes.discard", id, lane) })
            }
            for (share in shares[id].orEmpty()) {
                val shareId = share.str("id") ?: continue
                val title = share.str("title")?.takeIf { it.isNotBlank() } ?: L10n.text("common.teams.shared_chat")
                TsSecondaryButton(title, icon = ActionIcon.Comment.vector, onClick = {
                    onOpenChat(ChatTarget(target(orgId, repoId, id, shareId), title, computer))
                })
            }
            if (repo.str("role") in setOf("contributor", "maintainer")) {
                OutlinedTextField(newTitles[id].orEmpty(), { newTitles = newTitles + (id to it) }, Modifier.fillMaxWidth(),
                    label = { Text(L10n.text("common.teams.new_chat_title")) },
                    placeholder = { Text(L10n.text("common.teams.new_chat_placeholder")) })
                TsAccentButton(L10n.text("common.teams.new_chat"), enabled = newTitles[id].orEmpty().isNotBlank() && !busy,
                    icon = ActionIcon.Create.vector, onClick = { startChat(id, computer) })
                Text(L10n.text("common.teams.new_chat_detail", computer), color = LocalTsColors.current.textSecondary)
            }
        }
    }
}

@Composable
private fun LaneRow(lane: JsonObject, all: List<JsonObject>, busy: Boolean, onLand: () -> Unit, onDiscard: () -> Unit) {
    val colors = LocalTsColors.current
    val state = lane.str("state")
    val asker = (lane["askedBy"] as? JsonObject)?.str("name") ?: ""
    val files = (lane["files"] as? JsonArray)?.mapNotNull { (it as? JsonPrimitive)?.contentOrNull }.orEmpty()
    Column(Modifier.fillMaxWidth().padding(vertical = 4.dp), verticalArrangement = Arrangement.spacedBy(4.dp)) {
        Text(lane.str("ask")?.takeIf { it.isNotBlank() } ?: lane.str("branch").orEmpty(), color = colors.textPrimary)
        val detail = when (state) {
            "running" -> L10n.text("common.teams.lane_running", asker, files.size.toString())
            "ready" -> L10n.text("common.teams.lane_ready", asker, files.size.toString())
            else -> L10n.text("common.teams.lane_kept", asker, files.size.toString())
        }
        Text(detail, color = colors.textSecondary)
        // Compared across every computer's lanes, as on the Mac.
        val overlapping = all.filter { other ->
            other.str("branch") != lane.str("branch") &&
                (other["files"] as? JsonArray)?.any { (it as? JsonPrimitive)?.contentOrNull in files } == true
        }.map { it.str("ask") ?: it.str("branch").orEmpty() }
        if (overlapping.isNotEmpty()) {
            Text(L10n.text("common.teams.lane_overlap", overlapping.joinToString(", ")), color = colors.warning)
        }
        if (state != "running" && lane.str("share") != null) {
            Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                if (state == "ready") TsAccentButton(L10n.text("common.teams.land"), onClick = onLand, enabled = !busy, icon = ActionIcon.Merge.vector, small = true)
                TsDangerButton(L10n.text("common.teams.discard"), onClick = onDiscard, enabled = !busy, icon = ActionIcon.Delete.vector)
            }
        }
    }
}

/// A file the shared history shows. Images open inline on request. Nothing
/// is handed to another app, because the file comes from someone else's
/// computer and its name comes from an agent's output.
@Composable
private fun SharedFile(file: JsonObject, fetch: suspend (String) -> JsonObject) {
    val colors = LocalTsColors.current
    val scope = rememberCoroutineScope()
    val id = file.str("id") ?: return
    val name = file.str("name").orEmpty().filter { Character.getType(it) != Character.FORMAT.toInt() && !it.isISOControl() }
        .ifBlank { L10n.text("common.teams.shared_file") }
    var image by remember(id) { mutableStateOf<androidx.compose.ui.graphics.ImageBitmap?>(null) }
    var note by remember(id) { mutableStateOf<String?>(null) }
    var busy by remember(id) { mutableStateOf(false) }
    Column(verticalArrangement = Arrangement.spacedBy(4.dp)) {
        Text(name, color = colors.textPrimary, maxLines = 1)
        val shown = image
        if (shown != null) {
            androidx.compose.foundation.Image(shown, contentDescription = name, modifier = Modifier.fillMaxWidth())
        } else {
            TsSecondaryButton(L10n.text("common.teams.open_file_action"), enabled = !busy, icon = ActionIcon.Download.vector, onClick = {
                scope.launch {
                    busy = true
                    try {
                        val reply = fetch(id)
                        val media = (reply["attachment"] as? JsonObject)?.str("mediaType").orEmpty()
                        if (media.startsWith("image/") && media != "image/svg+xml") {
                            val data = reply.str("data").orEmpty()
                            if (data.length > 8 * 1024 * 1024) throw IllegalStateException(L10n.text("common.teams.file_unavailable"))
                            val bytes = android.util.Base64.decode(data, android.util.Base64.DEFAULT)
                            // A small file can still describe a huge bitmap.
                            val bounds = android.graphics.BitmapFactory.Options().apply { inJustDecodeBounds = true }
                            android.graphics.BitmapFactory.decodeByteArray(bytes, 0, bytes.size, bounds)
                            val (w, h) = bounds.outWidth.toLong() to bounds.outHeight.toLong()
                            if (w <= 0 || h <= 0 || w * h > 100_000_000L || maxOf(w, h) / minOf(w, h) > 50)
                                throw IllegalStateException(L10n.text("common.teams.file_unavailable"))
                            var sample = 1
                            while (bounds.outWidth / sample > 2048 || bounds.outHeight / sample > 2048) sample *= 2
                            val options = android.graphics.BitmapFactory.Options().apply { inSampleSize = sample }
                            image = android.graphics.BitmapFactory.decodeByteArray(bytes, 0, bytes.size, options)?.asImageBitmap()
                            if (image == null) note = L10n.text("common.teams.file_unavailable")
                        } else {
                            note = L10n.text("common.teams.file_on_computer")
                        }
                    } catch (cancelled: CancellationException) {
                        throw cancelled
                    } catch (failure: Throwable) {
                        note = failure.message
                    } finally {
                        busy = false
                    }
                }
            })
        }
        note?.let { Text(it, color = colors.textSecondary) }
    }
}

/// One shared chat: its history as text, a comment box, and Ask with Stop.
@Composable
private fun TeamChatReader(calls: TeamCalls, chat: ChatTarget, onBack: () -> Unit) {
    val colors = LocalTsColors.current
    val scope = rememberCoroutineScope()
    var events by remember(chat) { mutableStateOf<List<JsonObject>>(emptyList()) }
    var allowsComments by remember(chat) { mutableStateOf(false) }
    var allowsAgentRuns by remember(chat) { mutableStateOf(false) }
    var comment by remember(chat) { mutableStateOf("") }
    // One id per comment text: a retry after an unknown result is the same
    // message, so the host keeps one copy.
    var commentAttempt by remember(chat) { mutableStateOf<CommentAttempt?>(null) }
    var ask by remember(chat) { mutableStateOf("") }
    var fence by remember(chat) { mutableStateOf<JsonElement?>(null) }
    var error by remember(chat) { mutableStateOf<String?>(null) }
    var busy by remember(chat) { mutableStateOf(false) }

    suspend fun read(method: String, params: JsonObject = buildJsonObject {}): JsonObject =
        calls.call("teams.connection.call", buildJsonObject {
            put("target", chat.target); put("method", method); put("params", params)
        })
    suspend fun load() {
        try {
            val details = read("team.chat.details")["chat"]?.jsonObject
            allowsComments = details?.bool("allowsComments") == true
            allowsAgentRuns = details?.bool("allowsAgentRuns") == true
            events = read("team.chat.events", buildJsonObject { put("direction", "older"); put("limit", 100) }).list("events")
            error = null
        } catch (cancelled: CancellationException) {
            throw cancelled
        } catch (failure: Throwable) {
            error = failure.message
        }
    }
    suspend fun askCall(method: String, params: JsonObject): JsonObject =
        calls.call("teams.ask", buildJsonObject { put("target", chat.target); put("method", method); put("params", params) })

    LaunchedEffect(chat) {
        load()
        // New comments and agent output appear while the chat is open.
        // Paused while someone is typing, and while an Ask is watched below.
        while (true) {
            delay(10_000)
            if (!busy && fence == null && comment.isBlank() && ask.isBlank()) load()
        }
    }
    LaunchedEffect(fence) {
        val running = fence ?: return@LaunchedEffect
        while (true) {
            delay(3000)
            load()
            val status = runCatching { askCall("team.chat.ask.status", buildJsonObject { put("fence", running) }) }.getOrNull()
            if (status?.bool("running") == false) break
        }
        fence = null
        load()
    }

    Column(Modifier.fillMaxSize().padding(16.dp), verticalArrangement = Arrangement.spacedBy(8.dp)) {
        TsSecondaryButton(L10n.text("common.back"), onClick = onBack, icon = ActionIcon.Back.vector)
        Text(chat.title, style = TsType.cardTitle, color = colors.textPrimary)
        error?.let { Text(it, color = colors.danger) }
        LazyColumn(Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(6.dp)) {
            items(events) { event ->
                val shared = (event["event"] as? JsonObject)?.takeIf { it.str("kind") == "attachment" }
                if (shared != null) {
                    SharedFile(shared) { id -> read("team.chat.attachment", buildJsonObject { put("attachment", id) }) }
                    return@items
                }
                val by = event["author"] as? JsonObject
                val author = if (by?.str("kind") == "formerMember") L10n.text("common.teams.former_member")
                    else by?.str("name") ?: event.str("kind").orEmpty()
                val text = event.str("text") ?: (event["event"] as? JsonObject)?.str("delta") ?: return@items
                Column {
                    Text(author, color = colors.textSecondary)
                    Text(text, color = colors.textPrimary)
                }
            }
        }
        if (allowsComments) {
            OutlinedTextField(comment, { comment = it }, Modifier.fillMaxWidth(), placeholder = { Text(L10n.text("common.teams.comment_placeholder")) })
            TsSecondaryButton(L10n.text("common.teams.comment"), enabled = comment.isNotBlank() && !busy, icon = ActionIcon.Comment.vector, onClick = {
                scope.launch {
                    busy = true
                    try {
                        val text = comment.trim()
                        val attempt = commentAttempt?.takeIf { it.text == text }
                            ?: CommentAttempt(text, UUID.randomUUID().toString(), System.currentTimeMillis()).also { commentAttempt = it }
                        calls.call("teams.comment.send", buildJsonObject {
                            put("target", chat.target)
                            put("input", buildJsonObject {
                                put("text", text); put("clientMessageId", attempt.id)
                                put("clientMessageCreatedAtMs", attempt.createdAtMs)
                            })
                        })
                        comment = ""; commentAttempt = null
                        load()
                    } catch (cancelled: CancellationException) {
                        throw cancelled
                    } catch (failure: Throwable) {
                        error = failure.message
                    } finally {
                        busy = false
                    }
                }
            })
        }
        if (allowsAgentRuns) {
            val running = fence
            if (running != null) {
                Text(L10n.text("common.teams.agent_working", chat.computer), color = colors.textSecondary)
                TsSecondaryButton(L10n.text("common.teams.stop_agent"), icon = ActionIcon.Stop.vector, onClick = {
                    scope.launch { runCatching { askCall("team.chat.ask.stop", buildJsonObject { put("fence", running) }) } }
                })
            } else {
                OutlinedTextField(ask, { ask = it }, Modifier.fillMaxWidth(), placeholder = { Text(L10n.text("common.teams.ask_placeholder")) })
                TsAccentButton(L10n.text("common.teams.ask"), enabled = ask.isNotBlank() && !busy, icon = ActionIcon.Run.vector, onClick = {
                    scope.launch {
                        busy = true
                        try {
                            val review = askCall("team.chat.ask.review", buildJsonObject {})
                            if (!review.bool("agentRuns")) {
                                error = L10n.text("common.teams.agent_runs_off", chat.computer)
                            } else {
                                val sent = askCall("team.chat.ask", buildJsonObject {
                                    put("text", ask.trim()); put("review", review.str("review") ?: "")
                                    put("clientMessageId", UUID.randomUUID().toString())
                                    put("clientMessageCreatedAtMs", System.currentTimeMillis())
                                })
                                ask = ""
                                if (sent.str("state") == "running") fence = sent["fence"]
                                load()
                            }
                        } catch (cancelled: CancellationException) {
                            throw cancelled
                        } catch (failure: Throwable) {
                            error = failure.message
                        } finally {
                            busy = false
                        }
                    }
                })
                Text(L10n.text("common.teams.ask_detail", chat.computer), color = colors.textSecondary)
            }
        }
    }
}
