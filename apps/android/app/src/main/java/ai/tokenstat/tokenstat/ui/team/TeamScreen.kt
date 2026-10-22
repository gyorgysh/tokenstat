// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
package ai.tokenstat.tokenstat.ui.team

import ai.tokenstat.tokenstat.core.CoreClient
import ai.tokenstat.tokenstat.core.CoreFailure
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
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.unit.dp
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.contentOrNull
import kotlinx.serialization.json.put
import java.util.UUID

/// Every Team call carries the signed-in account's receipt. The host drops a
/// call when that login is no longer the one it was made for.
internal class TeamCalls(account: JsonObject?, private val bridge: suspend (String, JsonObject) -> JsonElement = { method, params -> CoreClient.call(method, params) }) {
    private val owner = WatchingOwner.from(account)
    val origin = owner?.scope?.str("origin")
    private val accountPerson = account?.str("accountId")?.takeIf { it.isNotBlank() }
    var person: String? = accountPerson; private set
    fun verify(capabilities: JsonObject) {
        val actor = capabilities.str("actorId")?.takeIf { it.isNotBlank() } ?: throw IllegalStateException(L10n.text("common.teams.account_changed"))
        if (accountPerson != null && accountPerson != actor) throw IllegalStateException(L10n.text("common.teams.account_changed"))
        person = actor
    }
    fun commentTarget(chat: ChatTarget): TeamCommentTarget? {
        val fields = chat.target
        return TeamCommentTarget(origin ?: return null, person ?: return null, fields.str("organization") ?: return null,
            fields.str("repository") ?: return null, fields.str("checkout") ?: return null, fields.str("share") ?: return null,
            chat.host.takeIf { it.isNotBlank() } ?: return null)
    }

    suspend fun call(method: String, fields: JsonObject = buildJsonObject {}): JsonObject {
        val owner = owner ?: throw IllegalStateException(L10n.text("common.teams.load_failed"))
        val params = buildJsonObject {
            for ((key, value) in fields) put(key, value)
            put("_accountScope", owner.scope)
            owner.receipt?.let { put("_accountSession", it) }
        }
        return bridge(method, params) as? JsonObject ?: JsonObject(emptyMap())
    }

    suspend fun directory(operation: String, limit: Int = 100, offset: Int = 0, extra: JsonObject.() -> JsonObject = { this }): JsonObject =
        call("teams.directory", buildJsonObject {
            put("operation", operation)
            put("page", buildJsonObject { put("limit", limit); put("offset", offset) })
        }.extra())
}

private fun teamFailure(failure: Exception): String = if (failure is IllegalArgumentException || failure is IllegalStateException)
    L10n.text("common.teams.load_failed") else failure.message ?: L10n.text("common.teams.load_failed")
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
    var drafts by remember(identity) { mutableStateOf(false) }
    val context = LocalContext.current.applicationContext
    val draftStorage = remember(context) { TeamCommentDraftStore.shared(java.io.File(context.filesDir, "team-comment-drafts")) }

    suspend fun load() {
        phase = Phase.Loading
        phase = try {
            val capabilities = calls.call("teams.capabilities")
            when {
                !capabilities.bool("enabled") -> Phase.Unavailable
                !capabilities.bool("ready") -> Phase.Authorize
                else -> {
                    calls.verify(capabilities)
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

    if (drafts) {
        TeamCommentRecoveryList(draftStorage, calls.origin, calls.person, onBack = { drafts = false })
        return
    }
    val current = chat
    if (current != null) {
        TeamChatReader(calls, current, draftStorage, onBack = { chat = null })
        return
    }
    Column(Modifier.fillMaxSize().padding(horizontal = 16.dp), verticalArrangement = Arrangement.spacedBy(12.dp)) {
        Text(L10n.text("common.teams.title"), style = TsType.cardTitle,
            color = LocalTsColors.current.textPrimary, modifier = Modifier.padding(top = 16.dp))
        if (calls.origin != null && calls.person != null) TsSecondaryButton(L10n.text("common.teams.comment_drafts"),
            icon = ActionIcon.History.vector, onClick = { drafts = true })
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

data class ChatTarget(val target: JsonObject, val title: String, val computer: String, val host: String)

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
internal fun RepositoryCard(calls: TeamCalls, orgId: String, repo: JsonObject, onOpenChat: (ChatTarget) -> Unit) {
    val repoId = repo.str("id") ?: return
    val scope = rememberCoroutineScope()
    var checkouts by remember(repoId) { mutableStateOf<List<JsonObject>>(emptyList()) }
    var lanes by remember(repoId) { mutableStateOf<Map<String, List<JsonObject>>>(emptyMap()) }
    var shares by remember(repoId) { mutableStateOf<Map<String, List<JsonObject>>>(emptyMap()) }
    var checkoutNext by remember(repoId) { mutableStateOf<Int?>(null) }
    var catalogNext by remember(repoId) { mutableStateOf<Map<String, String>>(emptyMap()) }
    var hostErrors by remember(repoId) { mutableStateOf<Map<String, String>>(emptyMap()) }
    var loading by remember(repoId) { mutableStateOf(false) }
    var loaded by remember(repoId) { mutableStateOf(false) }
    var message by remember(repoId) { mutableStateOf<String?>(null) }
    var busy by remember(repoId) { mutableStateOf(false) }
    var newTitles by remember(repoId) { mutableStateOf<Map<String, String>>(emptyMap()) }
    // Kept per title so a retry after a lost reply settles to the same chat.
    var newRequests by remember(repoId) { mutableStateOf<Map<String, Pair<String, String>>>(emptyMap()) }

    suspend fun loadCatalog(checkout: String, more: Boolean = false) {
        val cursor = if (more) catalogNext[checkout] else null
        val answer = calls.call("teams.connection.call", buildJsonObject {
            put("target", target(orgId, repoId, checkout)); put("method", "team.chat.catalog")
            put("params", buildJsonObject { put("limit", 50); cursor?.let { put("cursor", it) } })
        })
        val page = TeamCatalogPage.read(answer, checkout, cursor)
        shares = shares + (checkout to TeamCatalogPage.append(if (more) shares[checkout].orEmpty() else emptyList(), page.rows))
        catalogNext = catalogNext - checkout
        page.next?.let { catalogNext = catalogNext + (checkout to it) }
        hostErrors = hostErrors - checkout
    }
    suspend fun loadWork(rows: List<JsonObject>) {
        for (checkout in rows) {
            val id = checkout.str("id") ?: continue
            try {
                lanes = lanes + (id to calls.call("teams.connection.call", buildJsonObject {
                    put("target", target(orgId, repoId, id)); put("method", "team.lanes"); put("params", buildJsonObject {})
                }).list("lanes"))
                loadCatalog(id)
            } catch (cancelled: CancellationException) { throw cancelled }
            catch (failure: Exception) { hostErrors = hostErrors + (id to teamFailure(failure)) }
        }
    }
    suspend fun load(more: Boolean = false) {
        if (repo.str("role") == null || loading) return
        loading = true
        try {
            val offset = if (more) checkoutNext ?: return else 0
            val answer = calls.directory("checkouts.list", limit = 3, offset = offset) {
                with("organization" to JsonPrimitive(orgId), "repository" to JsonPrimitive(repoId))
            }
            val page = TeamDirectoryPage.read(answer, "checkouts", offset)
            checkouts = TeamCatalogPage.append(if (more) checkouts else emptyList(), page.rows)
            checkoutNext = page.next; loaded = true; message = null
            loadWork(page.rows)
        } catch (cancelled: CancellationException) { throw cancelled }
        catch (failure: Exception) { message = teamFailure(failure) }
        finally { loading = false }
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
            loading = true
            try { loadWork(checkouts) } finally { loading = false }
        }
    }

    fun startChat(checkout: String, computer: String) {
        val title = newTitles[checkout].orEmpty().trim()
        if (title.isEmpty()) return
        val request = newRequests[checkout]?.takeIf { it.first == title } ?: (title to "new-" + UUID.randomUUID()).also { newRequests = newRequests + (checkout to it) }
        scope.launch {
            busy = true
            try {
                val made = calls.call("teams.ask", buildJsonObject {
                    put("target", target(orgId, repoId, checkout)); put("method", "team.chat.new")
                    put("params", buildJsonObject { put("title", title); put("requestId", request.second) })
                })
                if (newTitles[checkout]?.trim() == title) newTitles = newTitles - checkout
                if (newRequests[checkout] == request) newRequests = newRequests - checkout
                made.str("share")?.let { onOpenChat(ChatTarget(target(orgId, repoId, checkout, it), title, computer, checkouts.firstOrNull { row -> row.str("id") == checkout }?.str("hostKey").orEmpty())) }
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
        if (repo.str("role") != null && loaded && checkouts.isEmpty()) {
            Text(L10n.text("common.teams.repository_not_shared"), color = LocalTsColors.current.textSecondary)
        }
        if (loading) CircularProgressIndicator()
        if (checkoutNext != null || hostErrors.isNotEmpty()) Text(L10n.text("common.teams.partial_lanes"), color = LocalTsColors.current.textSecondary)
        val allLanes = checkouts.flatMap { lanes[it.str("id")] ?: emptyList() }
        for (checkout in checkouts) {
            val id = checkout.str("id") ?: continue
            val computer = checkout.str("deviceName") ?: L10n.text("common.teams.computer")
            Text(computer, color = LocalTsColors.current.textPrimary, modifier = Modifier.padding(top = 4.dp))
            hostErrors[id]?.let { failure ->
                Text(failure, color = LocalTsColors.current.warning)
                TsSecondaryButton(L10n.text("common.retry"), enabled = !loading && !busy, icon = ActionIcon.Refresh.vector,
                    onClick = { scope.launch { loading = true; try { loadWork(listOf(checkout)) } finally { loading = false } } })
            }
            for (lane in lanes[id].orEmpty()) {
                LaneRow(lane, allLanes, busy || loading, onLand = { act("team.lanes.land", id, lane) }, onDiscard = { act("team.lanes.discard", id, lane) })
            }
            for (share in shares[id].orEmpty()) {
                val shareId = share.str("id") ?: continue
                val title = share.str("title")?.takeIf { it.isNotBlank() } ?: L10n.text("common.teams.shared_chat")
                TsSecondaryButton(title, icon = ActionIcon.Comment.vector, onClick = {
                    onOpenChat(ChatTarget(target(orgId, repoId, id, shareId), title, computer, checkout.str("hostKey").orEmpty()))
                })
            }
            if (catalogNext[id] != null) TsSecondaryButton(L10n.text("common.teams.load_more"), enabled = !loading && !busy,
                icon = ActionIcon.More.vector, onClick = { scope.launch {
                    loading = true
                    try { loadCatalog(id, more = true) }
                    catch (cancelled: CancellationException) { throw cancelled }
                    catch (failure: Exception) { hostErrors = hostErrors + (id to teamFailure(failure)) }
                    finally { loading = false }
                } })
            if (repo.str("role") in setOf("contributor", "maintainer")) {
                OutlinedTextField(newTitles[id].orEmpty(), { newTitles = newTitles + (id to it) }, Modifier.fillMaxWidth(),
                    label = { Text(L10n.text("common.teams.new_chat_title")) },
                    placeholder = { Text(L10n.text("common.teams.new_chat_placeholder")) })
                TsAccentButton(L10n.text("common.teams.new_chat"), enabled = newTitles[id].orEmpty().isNotBlank() && !busy && !loading,
                    icon = ActionIcon.Create.vector, onClick = { startChat(id, computer) })
                Text(L10n.text("common.teams.new_chat_detail", computer), color = LocalTsColors.current.textSecondary)
            }
        }
        if (checkoutNext != null) TsSecondaryButton(L10n.text("common.teams.load_more_computers"), enabled = !loading && !busy,
            icon = ActionIcon.More.vector, onClick = { scope.launch { load(more = true) } })
        if (!loaded && !loading && message != null) TsSecondaryButton(L10n.text("common.retry"), icon = ActionIcon.Refresh.vector,
            onClick = { scope.launch { load() } })

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
internal fun SharedFile(file: JsonObject, fetch: suspend (String) -> JsonObject) {
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
                            // Decoding is off the main thread: a 5 MB file is
                            // enough to stall the Team tab.
                            image = withContext(Dispatchers.Default) { decodeBounded(data) }
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

/// A small file can still describe a huge bitmap. Refuse extremes and
/// decode the larger side at no more than 2048 pixels.
private fun decodeBounded(data: String): androidx.compose.ui.graphics.ImageBitmap? {
    val bytes = android.util.Base64.decode(data, android.util.Base64.DEFAULT)
    val bounds = android.graphics.BitmapFactory.Options().apply { inJustDecodeBounds = true }
    android.graphics.BitmapFactory.decodeByteArray(bytes, 0, bytes.size, bounds)
    val (w, h) = bounds.outWidth.toLong() to bounds.outHeight.toLong()
    if (w <= 0 || h <= 0 || w * h > 100_000_000L || maxOf(w, h) / minOf(w, h) > 50) return null
    var sample = 1
    while (bounds.outWidth / sample > 2048 || bounds.outHeight / sample > 2048) sample *= 2
    val options = android.graphics.BitmapFactory.Options().apply { inSampleSize = sample }
    return android.graphics.BitmapFactory.decodeByteArray(bytes, 0, bytes.size, options)?.asImageBitmap()
}

/// One shared chat: its history as text, a comment box, and Ask with Stop.
@Composable
internal fun TeamChatReader(calls: TeamCalls, chat: ChatTarget, draftStorage: TeamCommentDraftStore, onBack: () -> Unit) {
    val colors = LocalTsColors.current
    val scope = rememberCoroutineScope()
    var history by remember(chat) { mutableStateOf(TeamHistoryWindow(emptyList())) }
    var blocks by remember(chat) { mutableStateOf<List<TeamBlock>>(emptyList()) }
    var nextCursor by remember(chat) { mutableStateOf<String?>(null) }
    var hasMore by remember(chat) { mutableStateOf(false) }
    var loadedEarlier by remember(chat) { mutableStateOf(false) }
    var loading by remember(chat) { mutableStateOf(false) }
    var allowsComments by remember(chat) { mutableStateOf(false) }
    var allowsAgentRuns by remember(chat) { mutableStateOf(false) }
    val commentTarget = remember(calls, chat) { calls.commentTarget(chat) }
    val commentModel = remember(calls, chat) { commentTarget?.let { TeamCommentModel(draftStorage, it,
        chat.title.take(160) + " · " + chat.computer.take(160), calls::call) } }
    var ask by remember(chat) { mutableStateOf("") }
    var askAttempt by remember(chat) { mutableStateOf<JsonObject?>(null) }
    var fence by remember(chat) { mutableStateOf<JsonElement?>(null) }
    var error by remember(chat) { mutableStateOf<String?>(null) }
    var busy by remember(chat) { mutableStateOf(false) }

    suspend fun read(method: String, params: JsonObject = buildJsonObject {}): JsonObject =
        calls.call("teams.connection.call", buildJsonObject {
            put("target", chat.target); put("method", method); put("params", params)
        })
    suspend fun load(earlier: Boolean = false) {
        if (loading || earlier && !hasMore) return
        loading = true
        try {
            val details = read("team.chat.details")["chat"] as? JsonObject
                ?: throw CoreFailure("invalid_response", L10n.text("common.teams.history_cannot_display"))
            val cursor = if (earlier) nextCursor else null
            val page = read("team.chat.events", buildJsonObject {
                put("direction", "older"); put("limit", 100)
                cursor?.let { put("cursor", it) }
            })
            val more = page.bool("hasMore")
            val next = page.str("nextCursor")
            val incoming = page.list("events")
            if (details.str("id") != chat.target.str("share") || details.str("checkoutId") != chat.target.str("checkout") ||
                page.str("shareId") != chat.target.str("share") || more && (incoming.isEmpty() || next == null || next == cursor)) {
                throw CoreFailure("invalid_response", L10n.text("common.teams.history_cannot_display"))
            }
            val before = history
            val projected = withContext(Dispatchers.Default) {
                val window = before.merge(incoming, earlier)
                window to TeamTranscript.project(window.events, details.str("backend").orEmpty())
            }
            history = projected.first; blocks = projected.second
            nextCursor = next; hasMore = more; loadedEarlier = earlier
            allowsComments = details.bool("allowsComments")
            allowsAgentRuns = details.bool("allowsAgentRuns")
            error = null
        } catch (cancelled: CancellationException) {
            throw cancelled
        } catch (failure: Throwable) {
            val invalid = failure is IllegalArgumentException || failure is IllegalStateException
            error = if (invalid) L10n.text("common.teams.history_cannot_display") else failure.message
            if (invalid || failure is CoreFailure && failure.code !in setOf("team_connection_unavailable", "teams_unreachable", "teams_busy", "chat_window_full")) {
                history = TeamHistoryWindow(emptyList()); blocks = emptyList(); hasMore = false; nextCursor = null
                allowsComments = false; allowsAgentRuns = false
            }
        } finally {
            loading = false
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
            if (!busy && fence == null && !loadedEarlier && commentModel?.text.isNullOrBlank() && ask.isBlank()) load()
        }
    }
    LaunchedEffect(fence) {
        val running = fence ?: return@LaunchedEffect
        while (true) {
            delay(3000)
            if (!loadedEarlier) load()
            val status = runCatching { askCall("team.chat.ask.status", buildJsonObject { put("fence", running) }) }.getOrNull()
            if (status?.bool("running") == false) break
        }
        fence = null
        if (!loadedEarlier) load()
    }

    Column(Modifier.fillMaxSize().padding(16.dp), verticalArrangement = Arrangement.spacedBy(8.dp)) {
        Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
            TsSecondaryButton(L10n.text("common.back"), onClick = onBack, icon = ActionIcon.Back.vector)
            TsSecondaryButton(L10n.text("common.refresh"), enabled = !loading, icon = ActionIcon.Refresh.vector,
                onClick = { scope.launch { load() } })
        }
        Text(chat.title, style = TsType.cardTitle, color = colors.textPrimary)
        error?.let { Text(it, color = colors.danger) }
        if (history.truncated) Text(L10n.text("common.teams.shared_history_window"), color = colors.textSecondary)
        LazyColumn(Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(6.dp)) {
            if (hasMore) item {
                TsSecondaryButton(L10n.text("common.teams.load_earlier"), enabled = !loading,
                    icon = ActionIcon.History.vector, onClick = { scope.launch { load(earlier = true) } })
            }
            items(blocks, key = { it.id }) { block ->
                TeamTranscriptRow(block) { id -> read("team.chat.attachment", buildJsonObject { put("attachment", id) }) }
            }
        }
        if (allowsComments && commentModel != null) TeamCommentComposer(commentModel, onPosted = {
            if (!loadedEarlier) load()
        })
        if (allowsAgentRuns || fence != null) {
            val running = fence
            if (running != null) {
                Text(L10n.text("common.teams.agent_working", chat.computer), color = colors.textSecondary)
                TsSecondaryButton(L10n.text("common.teams.stop_agent"), icon = ActionIcon.Stop.vector, onClick = {
                    scope.launch { runCatching { askCall("team.chat.ask.stop", buildJsonObject { put("fence", running) }) } }
                })
            } else {
                OutlinedTextField(ask, { ask = it }, Modifier.fillMaxWidth(), enabled = !busy && askAttempt == null,
                    placeholder = { Text(L10n.text("common.teams.ask_placeholder")) })
                TsAccentButton(L10n.text("common.teams.ask"), enabled = ask.isNotBlank() && !busy, icon = ActionIcon.Run.vector, onClick = {
                    scope.launch {
                        busy = true
                        try {
                            if (askAttempt == null) {
                                val review = askCall("team.chat.ask.review", buildJsonObject {})
                                if (!review.bool("agentRuns")) {
                                    error = L10n.text("common.teams.agent_runs_off", chat.computer)
                                    return@launch
                                }
                                askAttempt = buildJsonObject {
                                    put("text", ask.trim()); put("review", review.str("review") ?: "")
                                    put("clientMessageId", UUID.randomUUID().toString())
                                    put("clientMessageCreatedAtMs", System.currentTimeMillis())
                                }
                            }
                            val sent = askCall("team.chat.ask", askAttempt ?: return@launch)
                            ask = ""; askAttempt = null
                            if (sent.str("state") == "running") fence = sent["fence"]
                            load()
                        } catch (cancelled: CancellationException) {
                            throw cancelled
                        } catch (failure: Throwable) {
                            if (failure is CoreFailure && failure.code in setOf("team_run_review_changed", "invalid_ask")) askAttempt = null
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
