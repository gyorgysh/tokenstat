// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
package ai.tokenstat.tokenstat.ui.workspace

import androidx.compose.material.icons.filled.Cloud
import androidx.compose.material.icons.filled.Computer
import ai.tokenstat.tokenstat.ui.localization.L10n
import ai.tokenstat.tokenstat.ui.logic.ChatCacheRules

import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.Icon
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.unit.dp
import ai.tokenstat.tokenstat.AppViewModel
import ai.tokenstat.tokenstat.ui.components.ActionIcon
import ai.tokenstat.tokenstat.ui.components.Banner
import ai.tokenstat.tokenstat.ui.components.BannerSeverity
import ai.tokenstat.tokenstat.ui.components.PickerChoice
import ai.tokenstat.tokenstat.ui.components.TsPickerOptionList
import ai.tokenstat.tokenstat.ui.components.TsPickerSheet
import ai.tokenstat.tokenstat.ui.components.TsSecondaryButton
import ai.tokenstat.tokenstat.ui.components.TsType
import ai.tokenstat.tokenstat.ui.logic.HostContracts
import ai.tokenstat.tokenstat.ui.logic.ModelFavorites
import ai.tokenstat.tokenstat.ui.logic.SharedPrefsModelFavorites
import ai.tokenstat.tokenstat.ui.logic.TunnelCopy
import ai.tokenstat.tokenstat.ui.logic.favoriteOrderedModels
import ai.tokenstat.tokenstat.ui.marks.HarnessMark
import ai.tokenstat.tokenstat.ui.theme.LocalTsColors
import ai.tokenstat.tokenstat.ui.theme.Space
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.launch
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonArray
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.booleanOrNull
import kotlinx.serialization.json.longOrNull
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.put


sealed interface ChatAgentChoice {
    data class Agent(val id: String) : ChatAgentChoice

    data class Model(val id: String) : ChatAgentChoice

    data class Effort(val id: String) : ChatAgentChoice
}

private val SECTION_AGENT = L10n.text("android.chatagentpanel.agent.11b39c93")
private val SECTION_MODEL = L10n.text("android.chatagentpanel.model.5e2c614c")
private val SECTION_EFFORT = L10n.text("android.chatagentpanel.effort.4387e5d3")

internal fun backendOf(backends: List<JsonObject>, id: String?): JsonObject? =
    backends.firstOrNull { it.str("id") == id }

internal fun backendNotInstalled(backend: JsonObject?): Boolean =
    (backend?.get("installed") as? JsonPrimitive)?.booleanOrNull == false

internal fun chatAgentChoices(
    backends: List<JsonObject>,
    chat: JsonObject?,
    favorites: List<String> = emptyList(),
    profiles: AgentProfiles? = null,
    profileId: String? = chat?.str("profileId"),
): List<PickerChoice<ChatAgentChoice>> {
    val rows = mutableListOf<PickerChoice<ChatAgentChoice>>()
    chatBackendOptions(backends).forEach { (id, label) ->
        val backend = backendOf(backends, id)
        rows.add(
            PickerChoice(
                value = ChatAgentChoice.Agent(id),
                label = label,
                detail = if (ownAgentProfile(profiles, profileId, backend?.str("launcherId")) != null) {
                    L10n.text("common.profiles.manage_login_on_host")
                } else when (backend?.str("readiness")) {
                    "needsSignIn" -> L10n.text("android.chatagentpanel.sign_in_may_be_needed.c3dde98c")
                    "expired" -> L10n.text("android.chatagentpanel.stored_login_has_expired.bf189dae")
                    else -> null
                },
                section = SECTION_AGENT,
            ),
        )
    }
    val current = backendOf(backends, chat?.str("backend"))
    if (current != null && !backendNotInstalled(current)) {
        val label = current.str("label")?.ifBlank { null } ?: current.str("id").orEmpty()
        rows.add(
            PickerChoice(
                value = ChatAgentChoice.Model(""),
                label = L10n.text("android.chatagentpanel.default.21b111cb"),
                detail = L10n.text("android.chatagentpanel.0_picks_the_model.59367853", "${label}"),
                section = SECTION_MODEL,
            ),
        )
        val listed = stringList(current, "models")
        favoriteOrderedModels(chatModelOptions(current, chat?.str("model")), favorites).forEach { id ->
            rows.add(
                PickerChoice(
                    value = ChatAgentChoice.Model(id),
                    label = localChatModelName(id) ?: id,
                    detail = if (id !in listed) L10n.text("android.chatagentpanel.saved_choice_availability_unverified.96a7ce32")
                        else localChatProvider(id)?.let { place ->
                            val host = L10n.text("common.chat.local_model_host", place)
                            val tokens = localModelContext(current, id)
                            if (tokens != null && tokens < LOCAL_ROOMY_CONTEXT) {
                                host + " · " + L10n.text("common.chat.local_model_small", "${tokens / 1024}K")
                            } else host
                        },
                    section = SECTION_MODEL,
                ),
            )
        }
        val efforts = chatEffortOptions(current, chat?.str("effort"))
        if (efforts.isNotEmpty()) {
            rows.add(PickerChoice(ChatAgentChoice.Effort(""), L10n.text("android.chatagentpanel.default.21b111cb"), section = SECTION_EFFORT))
            efforts.forEach { rows.add(PickerChoice(ChatAgentChoice.Effort(it), it, section = SECTION_EFFORT)) }
        }
    }
    return rows
}

internal fun chatAgentSections(choices: List<PickerChoice<ChatAgentChoice>>): List<String> =
    choices.map { it.section }.distinct().filter { it.isNotEmpty() }

internal fun chatAgentSectionValue(
    section: String,
    backends: List<JsonObject>,
    chat: JsonObject?,
): String? = when (section) {
    SECTION_AGENT -> backendOf(backends, chat?.str("backend"))?.str("label")?.ifBlank { null }
        ?: chat?.str("backend")
    SECTION_MODEL -> chat?.str("model")?.ifBlank { null }?.let { localChatModelName(it) ?: it } ?: L10n.text("android.chatagentpanel.default.21b111cb")
    SECTION_EFFORT -> chat?.str("effort")?.ifBlank { null } ?: L10n.text("android.chatagentpanel.default.21b111cb")
    else -> null
}

internal fun chatAgentSearchPrompt(section: String): String = when (section) {
    SECTION_AGENT -> L10n.text("android.chatagentpanel.search_agents.212fd04a")
    SECTION_MODEL -> L10n.text("android.chatagentpanel.search_models.10421935")
    SECTION_EFFORT -> L10n.text("android.chatagentpanel.search_efforts.f7909b52")
    else -> L10n.text("android.chatagentpanel.filter_agents_models_and_efforts.315032da")
}

internal fun chatAgentIsSelected(choice: ChatAgentChoice, chat: JsonObject?): Boolean = when (choice) {
    is ChatAgentChoice.Agent -> choice.id == (chat?.str("backend") ?: "")
    is ChatAgentChoice.Model -> choice.id == (chat?.str("model") ?: "")
    is ChatAgentChoice.Effort -> choice.id == (chat?.str("effort") ?: "")
}

internal fun chatAgentField(choice: ChatAgentChoice): Pair<String, String> = when (choice) {
    is ChatAgentChoice.Agent -> "backend" to choice.id
    is ChatAgentChoice.Model -> "model" to choice.id
    is ChatAgentChoice.Effort -> "effort" to choice.id
}

internal fun chatAgentForcesBypass(backends: List<JsonObject>, id: String): Boolean =
    backendOf(backends, id)?.str("gateTier") == "bypassOnly"

internal const val LOCAL_ROOMY_CONTEXT = 65_536L

internal fun localModelContext(backend: JsonObject?, id: String): Long? =
    (backend?.get("localModels") as? JsonArray)?.filterIsInstance<JsonObject>()
        ?.firstOrNull { it.str("id") == id }?.get("contextLength")
        ?.let { (it as? JsonPrimitive)?.longOrNull }

internal fun localChatProvider(id: String): String? =
    localChatModelTitle(id).takeIf { it != id }?.substringBefore(": ")

internal fun localChatModelName(id: String): String? =
    localChatModelTitle(id).takeIf { it != id }?.substringAfter(": ")

internal fun localChatModelTitle(id: String): String {
    val rest = id.trim().removePrefix("local:").takeIf { it != id.trim() } ?: return id
    val provider = rest.substringBefore('/', "")
    val model = rest.substringAfter('/', "")
    if (provider.isEmpty() || model.isEmpty()) return id
    val name = when (provider) { "lmstudio" -> "LM Studio"; "ollama" -> "Ollama"; else -> provider }
    return "$name: $model"
}

internal fun chatAgentLabel(backends: List<JsonObject>, chat: JsonObject?): String {
    val id = chat?.str("backend").orEmpty()
    val backend = backendOf(backends, id)
    return backend?.str("label")?.ifBlank { null }
        ?: id.ifBlank { null }?.let { ai.tokenstat.tokenstat.ui.logic.harnessName(it) }
        ?: L10n.text("common.chat.select_agent")
}

internal fun chatAgentCompactSummary(backends: List<JsonObject>, chat: JsonObject?): String {
    val parts = mutableListOf(chat?.str("model")?.takeIf { it.isNotBlank() }?.let { localChatModelName(it) ?: it } ?: chatAgentLabel(backends, chat))
    val effort = chat?.str("effort")?.takeIf { it.isNotBlank() }
    if (stringList(backendOf(backends, chat?.str("backend")), "efforts").isNotEmpty() && effort != null) {
        parts.add(effort)
    }
    return parts.joinToString(" · ")
}

internal fun chatAgentSummary(backends: List<JsonObject>, chat: JsonObject?): String {
    val agent = chatAgentLabel(backends, chat)
    val backend = backendOf(backends, chat?.str("backend").orEmpty())
    val parts = mutableListOf(agent)
    chat?.str("model")?.takeIf { it.isNotBlank() }?.let { parts.add(localChatModelTitle(it)) }
    val effort = chat?.str("effort")?.takeIf { it.isNotBlank() }
    if (stringList(backend, "efforts").isNotEmpty() && effort != null) {
        parts.add(L10n.text("android.chatagentpanel.0_effort.b0d63362", "${effort}"))
    }
    return parts.joinToString(" · ")
}

@Composable
internal fun ChatAgentSheet(
    model: AppViewModel,
    peer: String,
    chatId: String,
    chat: JsonObject?,
    hostLabel: String,
    protocol: Long?,
    locked: Boolean,
    backends: List<JsonObject>,
    onBackends: (List<JsonObject>) -> Unit,
    onChanged: suspend (JsonObject) -> Unit,
    onDismiss: () -> Unit,
    onContinueProfile: (suspend (String) -> Unit)? = null,
    profiles: AgentProfiles? = null,
) {
    val colors = LocalTsColors.current
    val scope = rememberCoroutineScope()
    val context = LocalContext.current
    val favorites: ModelFavorites = remember(context) { SharedPrefsModelFavorites(context) }
    val backendId = chat?.str("backend").orEmpty()
    var pinned by remember(backendId) { mutableStateOf(favorites.ids(backendId)) }
    var refreshError by remember { mutableStateOf<String?>(null) }
    var setupError by remember { mutableStateOf<String?>(null) }
    var showingSetup by remember { mutableStateOf(false) }
    var installing by remember { mutableStateOf<String?>(null) }
    var updating by remember { mutableStateOf(false) }
    val supportsUpdates = HostContracts.supportsAgentUpdates(protocol)
    var versions by remember(peer) { mutableStateOf<Map<String, JsonObject>>(emptyMap()) }
    var checkingUpdates by remember(peer) { mutableStateOf(false) }
    var checkedUpdates by remember(peer) { mutableStateOf(false) }
    val updatingAgent by model.updatingAgent.collectAsStateWithLifecycle()
    var updateNotes by remember(peer) { mutableStateOf<Map<String, String>>(emptyMap()) }
    val quotaReadings = rememberAgentQuotaReadings(model, peer)
    val profileId = chat?.str("profileId") ?: "system"
    val profileLock = profiles?.locked(chat?.str("workspaceId"))
    var continueProfile by remember(peer, chatId) { mutableStateOf<String?>(null) }

    suspend fun load(refresh: Boolean) {
        runCatching {
            model.workspaceSection(peer, "chat.backends", buildJsonObject { if (refresh) put("refresh", true) })
        }.onSuccess {
            onBackends(asObjects(it))
            refreshError = null
        }.onFailure {
            refreshError = TunnelCopy.display(it.message ?: L10n.text("android.chatagentpanel.the_request_failed.db4fb447"), hostLabel.ifBlank { L10n.text("android.chatagentpanel.that_computer.2b209061") })
        }
    }
    LaunchedEffect(peer, chatId) { if (backends.isEmpty()) load(refresh = false) }

    val target = continueProfile
    if (target != null) androidx.compose.material3.AlertDialog(
        onDismissRequest = { continueProfile = null },
        title = { Text(L10n.text("common.profiles.continue", profiles?.title(target).orEmpty())) },
        confirmButton = {
            androidx.compose.material3.TextButton(onClick = {
                continueProfile = null
                scope.launch { onContinueProfile?.invoke(target) }
            }) { Text(L10n.text("common.done")) }
        },
        dismissButton = {
            androidx.compose.material3.TextButton(onClick = { continueProfile = null }) { Text(L10n.text("common.cancel")) }
        },
    )

    val current = backends.firstOrNull { it.str("id") == chat?.str("backend") }
    val choices = remember(backends, chat, pinned, profiles) { chatAgentChoices(backends, chat, pinned, profiles) }

    var cacheQuestion by remember(chatId) { mutableStateOf<ChatCacheQuestion?>(null) }
    var cacheAnswer by remember(chatId) { mutableStateOf<kotlinx.coroutines.CompletableDeferred<ChatCacheAnswer>?>(null) }
    DisposableEffect(chatId) { onDispose { cacheAnswer?.complete(ChatCacheAnswer.CANCEL) } }
    cacheQuestion?.let { question -> ChatCacheDialog(question, context) { cacheAnswer?.complete(it) } }

    suspend fun confirmModelSwitch(next: String): Boolean {
        if (ChatCacheSuppression.model(context) || !ChatCacheRules.switching(chat, next, System.currentTimeMillis())) return true
        if (cacheAnswer != null) return false
        val answer = kotlinx.coroutines.CompletableDeferred<ChatCacheAnswer>()
        cacheQuestion = ChatCacheQuestion.ModelSwitch(ChatCacheRules.cachedModel(chat), next, ChatCacheRules.tokens(chat))
        cacheAnswer = answer
        return try { answer.await() == ChatCacheAnswer.PROCEED } finally { cacheQuestion = null; cacheAnswer = null }
    }

    suspend fun pick(choice: ChatAgentChoice): List<String>? {
        if (updating || locked) return null
        if (choice is ChatAgentChoice.Agent && backendNotInstalled(backendOf(backends, choice.id))) return null
        val (field, value) = chatAgentField(choice)
        if (chatAgentIsSelected(choice, chat)) return chatAgentSections(choices)
        if (choice is ChatAgentChoice.Model && !confirmModelSwitch(choice.id)) return null
        updating = true
        try {
            val updated = model.workspaceSection(peer, "chat.update", buildJsonObject {
                put("id", chatId)
                put(field, value)
                if (choice is ChatAgentChoice.Agent && chatAgentForcesBypass(backends, choice.id)) {
                    put("autonomy", "bypass")
                }
            }) as? JsonObject ?: return null
            refreshError = null
            onChanged(updated)
            return chatAgentSections(chatAgentChoices(backends, updated, profiles = profiles))
        } catch (error: kotlinx.coroutines.CancellationException) {
            throw error
        } catch (error: Exception) {
            refreshError = TunnelCopy.display(error.message ?: L10n.text("android.chatagentpanel.the_request_failed.db4fb447"), hostLabel.ifBlank { L10n.text("android.chatagentpanel.that_computer.2b209061") })
            return null
        } finally {
            updating = false
        }
    }

    suspend fun loadVersions(check: Boolean) {
        if (check) checkingUpdates = true
        try {
            val rows = model.workspaceSection(peer, "launcher.updates", buildJsonObject { put("check", check) }) as? JsonArray
            versions = asObjects(rows ?: JsonArray(emptyList())).associateBy { it.str("id").orEmpty() }
            if (check) checkedUpdates = true
        } catch (error: kotlinx.coroutines.CancellationException) {
            throw error
        } catch (error: Exception) {
            if (check) setupError = TunnelCopy.display(error.message ?: L10n.text("android.chatagentpanel.the_request_failed.db4fb447"), hostLabel.ifBlank { L10n.text("android.chatagentpanel.that_computer.2b209061") })
        } finally {
            if (check) checkingUpdates = false
        }
    }

    fun updateAgent(id: String, label: String) {
        if (updatingAgent != null) return
        updateNotes = updateNotes - id
        model.updateAgent(peer, id, label) { result ->
            val note = if (result?.bol("ok") == true) {
                result.str("after")?.let { L10n.text("common.agent_updates.updated", it) } ?: L10n.text("common.agent_updates.updated_unknown")
            } else {
                L10n.text("common.agent_updates.failed", result?.str("output").orEmpty().trim().takeLast(600))
            }
            updateNotes = updateNotes + (id to note)
            scope.launch {
                loadVersions(check = false)
                load(refresh = false)
            }
        }
    }

    fun install(backend: JsonObject) {
        val id = backend.str("launcherId") ?: return
        if (installing != null) return
        installing = backend.str("id")
        setupError = null
        scope.launch {
            runCatching {
                model.workspaceSection(peer, "launcher.install", buildJsonObject { put("id", id) })
            }.onSuccess { result ->
                val obj = result as? JsonObject
                if (obj?.bol("ok") != true) {
                    setupError = L10n.text("android.chatagentpanel.installation_failed_0.f293f900", "${(obj?.str("output").orEmpty().takeLast(600))}")
                }
                load(refresh = true)
            }.onFailure {
                setupError = TunnelCopy.display(it.message ?: L10n.text("android.chatagentpanel.the_request_failed.db4fb447"), hostLabel.ifBlank { L10n.text("android.chatagentpanel.that_computer.2b209061") })
            }
            installing = null
        }
    }

    TsPickerSheet(title = L10n.text("android.chatagentpanel.agent_model_and_effort.217ff8ae"), onDismiss = onDismiss) {
        Column(Modifier.fillMaxWidth().padding(bottom = Space.l)) {
            if (showingSetup) {
                Column(
                    Modifier
                        .fillMaxWidth()
                        .heightIn(max = 420.dp)
                        .verticalScroll(rememberScrollState())
                        .padding(Space.m),
                    verticalArrangement = Arrangement.spacedBy(Space.m),
                ) {
                    LaunchedEffect(peer, supportsUpdates) { if (supportsUpdates) loadVersions(check = false) }
                    Row(verticalAlignment = Alignment.CenterVertically) {
                        Text(
                            L10n.text("android.chatagentpanel.set_up_on_0.3a4e92e0", "${hostLabel.ifBlank { L10n.text("android.chatagentpanel.this_computer.058bf37c") }}"),
                            style = TsType.callout.copy(fontWeight = androidx.compose.ui.text.font.FontWeight.SemiBold),
                            color = colors.textPrimary,
                            modifier = Modifier.weight(1f),
                        )
                        if (supportsUpdates) {
                            TsSecondaryButton(
                                label = if (checkingUpdates) L10n.text("common.agent_updates.checking") else L10n.text("common.agent_updates.check"),
                                icon = ActionIcon.Refresh.vector,
                                small = true,
                                enabled = !checkingUpdates && updatingAgent == null && installing == null && !locked,
                                onClick = { scope.launch { loadVersions(check = true) } },
                            )
                        }
                    }
                    current?.takeIf { ownAgentProfile(profiles, profileId, it.str("launcherId")) == null }?.let { backend ->
                        AgentSetupCard(model, peer, hostLabel, backend, locked || updating, showWhenReady = true) { readiness, verified ->
                            onBackends(backends.map {
                                if (it.str("id") == backend.str("id")) JsonObject(it + ("readiness" to JsonPrimitive(readiness)) + ("signInVerified" to JsonPrimitive(verified))) else it
                            })
                        }
                    }
                    backends.filter { it.str("id") != "sh" }.forEach { backend ->
                        Row(verticalAlignment = Alignment.CenterVertically) {
                            Column(Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(3.dp)) {
                                Text(
                                    backend.str("label")?.ifBlank { null } ?: backend.str("id").orEmpty(),
                                    style = TsType.callout,
                                    color = colors.textPrimary,
                                )
                                Text(
                                    when {
                                        backendNotInstalled(backend) -> L10n.text("android.chatagentpanel.not_installed.d177cdc0")
                                        ownAgentProfile(profiles, profileId, backend.str("launcherId")) != null ->
                                            L10n.text("common.profiles.manage_login_on_host")
                                        backend.str("readiness") == "needsSignIn" ||
                                            backend.str("readiness") == "expired" ->
                                            L10n.text("android.chatagentpanel.open_this_agent_in_the_host_s_terminal_to.758284f3")
                                        backend.bol("installed") -> L10n.text("android.chatagentpanel.installed.f8b32f4e")
                                        else -> L10n.text("android.chatagentpanel.availability_unknown.2e0078a8")
                                    },
                                    style = TsType.caption,
                                    color = colors.controlGlyph,
                                )
                                val row = backend.str("launcherId")?.let { versions[it] }
                                if (!backendNotInstalled(backend) && row != null) {
                                    val line = agentVersionLine(row, checkedUpdates)
                                    if (line.isNotEmpty()) {
                                        Text(
                                            line,
                                            style = TsType.caption,
                                            color = if (row.bol("updateAvailable")) colors.accent else colors.controlGlyph,
                                        )
                                    }
                                }
                                backend.str("launcherId")?.let { updateNotes[it] }?.let { note ->
                                    Text(note, style = TsType.caption, color = colors.controlGlyph)
                                }
                            }
                            val updateRow = backend.str("launcherId")?.let { versions[it] }
                            if (supportsUpdates && !backendNotInstalled(backend) && updateRow != null && agentOffersUpdate(updateRow, checkedUpdates)) {
                                TsSecondaryButton(
                                    label = if (updatingAgent == updateRow.str("id")) L10n.text("common.agent_updates.updating") else L10n.text("common.agent_updates.update"),
                                    icon = ActionIcon.Download.vector,
                                    small = true,
                                    enabled = updatingAgent == null && installing == null && !checkingUpdates && !locked && !updateRow.bol("busy"),
                                    onClick = {
                                        updateAgent(updateRow.str("id").orEmpty(), backend.str("label") ?: updateRow.str("id").orEmpty())
                                    },
                                )
                            } else if (backendNotInstalled(backend) && backend.bol("canInstall")) {
                                TsSecondaryButton(
                                    label = if (installing == backend.str("id")) L10n.text("android.chatagentpanel.installing.530bcc35") else L10n.text("android.chatagentpanel.install.569ca49f"),
                                    icon = ActionIcon.Download.vector,
                                    small = true,
                                    enabled = installing == null && !locked,
                                    onClick = { install(backend) },
                                )
                            }
                        }
                    }
                }
            } else {
                fun changeProfile(id: String) {
                        if (id != profileId) {
                            if (chat?.get("lastMessageAtMs") is JsonPrimitive || !chat?.str("resumeToken").isNullOrEmpty()) {
                                if (onContinueProfile != null) continueProfile = id
                            } else {
                                scope.launch {
                                    updating = true
                                    try {
                                        val updated = model.workspaceSection(peer, "chat.update", buildJsonObject {
                                            put("id", chatId); put("profileId", id)
                                            chat?.get("sendRevision")?.let { put("expectedRevision", it) }
                                        }) as? JsonObject
                                        if (updated != null) onChanged(updated)
                                    } catch (cancelled: CancellationException) { throw cancelled }
                                    catch (failure: Exception) { setupError = failure.message }
                                    finally { updating = false }
                                }
                            }
                        }
                    }
                TsPickerOptionList(
                    choices = choices,
                    isSelected = { chatAgentIsSelected(it, chat) },
                    prompt = L10n.text("android.chatagentpanel.filter_agents_models_and_efforts.315032da"),
                    emptyMessage = L10n.text("android.chatagentpanel.no_agents_installed_set_up_an_agent_to_sta.2f73b57f"),
                    caption = L10n.text("android.chatagentpanel.agents_on_0.ebf316db", "${hostLabel.ifBlank { L10n.text("android.chatagentpanel.this_computer.058bf37c") }}"),
                    header = profiles?.let { list ->
                        { AgentProfileRow(list, profileId, profileLock, enabled = !locked && !updating, onChange = ::changeProfile) }
                    },
                    onRefresh = if (HostContracts.supportsModelRefresh(protocol)) {
                        { load(refresh = true) }
                    } else {
                        null
                    },
                    sectionValue = { chatAgentSectionValue(it, backends, chat) },
                    sectionTabs = chatAgentSections(choices),
                    stepped = true,
                    stepPrompt = ::chatAgentSearchPrompt,
                    onFinish = onDismiss,
                    selectionSummary = withAgentProfile(chatAgentSummary(backends, chat), profiles, profileId),
                    enabled = !updating && !locked,
                    pick = {},
                    onStepPick = ::pick,
                    icon = { ChatAgentRowMark(it) },
                    accessory = { value ->
                        ChatAgentRowExtras(value, backends, quotaReadings, enabled = updatingAgent == null && !locked,
                            profiles = profiles, profileId = profileId, onUpdate = ::updateAgent)
                        val id = (value as? ChatAgentChoice.Model)?.id
                        if (!id.isNullOrEmpty() && backendId.isNotEmpty()) {
                            val starred = id in pinned
                            Icon(
                                ActionIcon.Pinned.vector,
                                if (starred) L10n.text("android.chatagentpanel.unpin_0.450ccf9f", "${id}") else L10n.text("android.chatagentpanel.pin_0.67fd141b", "${id}"),
                                tint = if (starred) colors.accent else colors.textTertiary,
                                modifier = Modifier
                                    .size(44.dp)
                                    .clip(CircleShape)
                                    .clickable {
                                        favorites.toggle(backendId, id)
                                        pinned = favorites.ids(backendId)
                                    }
                                    .padding(12.dp),
                            )
                        }
                    },
                )
            }
            when (current?.str("modelListStatus")) {
                "refreshFailed" -> Text(
                    L10n.text("android.chatagentpanel.couldn_t_refresh_models_use_the_agent_defa.5288d275"),
                    style = TsType.caption,
                    color = colors.warning,
                    modifier = Modifier.padding(horizontal = Space.m),
                )
                "loading" -> Text(
                    L10n.text("android.chatagentpanel.checking_models_agent_default_is_available.6cb73a5c"),
                    style = TsType.caption,
                    color = colors.controlGlyph,
                    modifier = Modifier.padding(horizontal = Space.m),
                )
                else -> Unit
            }
            (setupError ?: refreshError)?.let {
                Banner(it, BannerSeverity.DANGER, Modifier.padding(horizontal = Space.m, vertical = Space.xs))
            }
            Row(
                Modifier.fillMaxWidth().padding(Space.m),
                verticalAlignment = Alignment.CenterVertically,
            ) {
                TsSecondaryButton(
                    label = if (showingSetup) L10n.text("android.chatagentpanel.back_to_agent_choices.a5dc0271") else L10n.text("android.chatagentpanel.set_up_another_agent.ba92ba58"),
                    icon = if (showingSetup) ActionIcon.Back.vector else ActionIcon.Create.vector,
                    small = true,
                    enabled = !locked,
                    onClick = { showingSetup = !showingSetup },
                )
                Spacer(Modifier.weight(1f))
                TsSecondaryButton(
                    label = L10n.text("common.retry"),
                    icon = ActionIcon.Refresh.vector,
                    small = true,
                    enabled = installing == null && !locked,
                    onClick = { scope.launch { load(refresh = HostContracts.supportsModelRefresh(protocol)) } },
                )
            }
        }
    }
}

@Composable
internal fun rememberAgentQuotaReadings(model: AppViewModel, peer: String): JsonArray {
    val appState by model.state.collectAsStateWithLifecycle()
    var remoteQuota by remember(peer) { mutableStateOf<JsonArray?>(null) }
    LaunchedEffect(peer) {
        if (peer.isNotBlank()) runCatching {
            model.workspaceSection(peer, "usage.limits", buildJsonObject { put("force", false) }) as? JsonArray
        }.onSuccess { remoteQuota = it }
    }
    return if (peer.isBlank()) appState.limits else remoteQuota ?: JsonArray(emptyList())
}

@Composable
internal fun ChatAgentRowExtras(
    value: ChatAgentChoice,
    backends: List<JsonObject>,
    quotaReadings: JsonArray,
    enabled: Boolean,
    profiles: AgentProfiles? = null,
    profileId: String? = null,
    onUpdate: (launcherId: String, label: String) -> Unit,
) {
    val agent = value as? ChatAgentChoice.Agent ?: return
    val colors = LocalTsColors.current
    val behind = backendOf(backends, agent.id)
    val launcherId = behind?.str("launcherId")
    if (behind != null && launcherId != null && behind.bol("updateAvailable") && !backendNotInstalled(behind)) {
        val label = behind.str("label") ?: agent.id
        val description = behind.str("latestVersion")?.let { L10n.text("common.agent_updates.update_to", label, it) }
            ?: L10n.text("common.agent_updates.update")
        Icon(
            ActionIcon.Download.vector,
            description,
            tint = colors.accent,
            modifier = Modifier
                .size(44.dp)
                .clip(CircleShape)
                .clickable(enabled = enabled) { onUpdate(launcherId, label) }
                .padding(10.dp)
                .background(colors.accent.copy(alpha = 0.16f), CircleShape)
                .padding(4.dp),
        )
    }
    val quotaProfile = ownAgentProfile(profiles, profileId, launcherId)
    ChatQuotaLine(chatQuotaReading(quotaReadings, agent.id, profileId = quotaProfile))
}

@Composable
internal fun ChatAgentRowMark(value: ChatAgentChoice) {
    when (value) {
        is ChatAgentChoice.Agent -> HarnessMark(value.id, 26.dp)
        is ChatAgentChoice.Model -> if (value.id.isNotEmpty()) {
            val colors = LocalTsColors.current
            val local = localChatProvider(value.id) != null
            Icon(
                if (local) androidx.compose.material.icons.Icons.Default.Computer else androidx.compose.material.icons.Icons.Default.Cloud, null,
                tint = if (local) colors.accent else colors.textTertiary,
                modifier = Modifier.size(18.dp),
            )
        }
        else -> {}
    }
}

internal fun agentVersionLine(row: JsonObject, checked: Boolean): String = listOfNotNull(
    row.str("version")?.let { L10n.text("common.agent_updates.version", it) },
    row.str("latest")?.takeIf { row.bol("updateAvailable") }?.let { L10n.text("common.agent_updates.available", it) },
    L10n.text("common.agent_updates.up_to_date").takeIf { checked && row["updateAvailable"] != null && !row.bol("updateAvailable") },
    L10n.text("common.agent_updates.unknown_latest").takeIf { checked && !row.bol("canCheck") },
    row.str("error")?.let { L10n.text("common.agent_updates.check_failed", it) },
).joinToString(" · ")

internal fun agentOffersUpdate(row: JsonObject, checked: Boolean): Boolean =
    row.bol("canUpdate") && (row.bol("updateAvailable") || (checked && !row.bol("canCheck")))
