// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
package ai.tokenstat.tokenstat.ui.workspace

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
import ai.tokenstat.tokenstat.ui.theme.LocalTsColors
import ai.tokenstat.tokenstat.ui.theme.Space
import kotlinx.coroutines.launch
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.booleanOrNull
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.put

/// Agent, model and effort in one panel you can type into. Port of
/// `ChatAgentChoices` and `ChatAgentPanel` in `ChatSetupHeader.swift`.
///
/// This was three dropdowns, each holding one setting and nothing else: no
/// filter over a forty-model list, no way to tell a saved model id from one
/// the host still lists, and no way to ask the host to look again after an API
/// key was added a minute ago. One panel, three sections, one filter that runs
/// across all of them.

/// One row of the panel. Three kinds of choice share a list, so they share a
/// value: the section a row came from is what says which of the three the
/// person just changed.
sealed interface ChatAgentChoice {
    data class Agent(val id: String) : ChatAgentChoice

    /// Empty is the agent's own default.
    data class Model(val id: String) : ChatAgentChoice

    data class Effort(val id: String) : ChatAgentChoice
}

private const val SECTION_AGENT = "Agent"
private const val SECTION_MODEL = "Model"
private const val SECTION_EFFORT = "Effort"

private fun backendOf(backends: List<JsonObject>, id: String?): JsonObject? =
    backends.firstOrNull { it.str("id") == id }

/// `installed` is a tri-state: true, false, or absent when the catalog has no
/// profile for this agent. Absent is not "not installed", so only an explicit
/// false hides a row or empties a model list.
internal fun backendNotInstalled(backend: JsonObject?): Boolean =
    (backend?.get("installed") as? JsonPrimitive)?.booleanOrNull == false

/// Every row, in the order the sections have always been read in.
internal fun chatAgentChoices(
    backends: List<JsonObject>,
    chat: JsonObject?,
    favorites: List<String> = emptyList(),
): List<PickerChoice<ChatAgentChoice>> {
    val rows = mutableListOf<PickerChoice<ChatAgentChoice>>()
    chatBackendOptions(backends).forEach { (id, label) ->
        val backend = backendOf(backends, id)
        rows.add(
            PickerChoice(
                value = ChatAgentChoice.Agent(id),
                label = label,
                detail = when (backend?.str("readiness")) {
                    "needsSignIn" -> "Sign-in may be needed"
                    "expired" -> "Stored login has expired"
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
                label = "Default",
                detail = "$label picks the model",
                section = SECTION_MODEL,
            ),
        )
        val listed = stringList(current, "models")
        favoriteOrderedModels(chatModelOptions(current, chat?.str("model")), favorites).forEach { id ->
            rows.add(
                PickerChoice(
                    value = ChatAgentChoice.Model(id),
                    label = id,
                    detail = if (id in listed) null else "Saved choice · availability unverified",
                    section = SECTION_MODEL,
                ),
            )
        }
        val efforts = chatEffortOptions(current, chat?.str("effort"))
        if (efforts.isNotEmpty()) {
            rows.add(PickerChoice(ChatAgentChoice.Effort(""), "Default", section = SECTION_EFFORT))
            efforts.forEach { rows.add(PickerChoice(ChatAgentChoice.Effort(it), it, section = SECTION_EFFORT)) }
        }
    }
    return rows
}

/// Only offer filters that have choices for the selected agent. An agent with
/// no effort control should not advertise one.
internal fun chatAgentSections(choices: List<PickerChoice<ChatAgentChoice>>): List<String> =
    choices.map { it.section }.distinct().filter { it.isNotEmpty() }

/// What each section is set to, for its heading. The panel is three settings,
/// and a heading that only names the group leaves somebody scrolling to find
/// which row carries the mark.
internal fun chatAgentSectionValue(
    section: String,
    backends: List<JsonObject>,
    chat: JsonObject?,
): String? = when (section) {
    SECTION_AGENT -> backendOf(backends, chat?.str("backend"))?.str("label")?.ifBlank { null }
        ?: chat?.str("backend")
    SECTION_MODEL -> chat?.str("model")?.ifBlank { null } ?: "Default"
    SECTION_EFFORT -> chat?.str("effort")?.ifBlank { null } ?: "Default"
    else -> null
}

/// Three marks in one list, one per section, each reading the conversation's
/// own setting.
internal fun chatAgentIsSelected(choice: ChatAgentChoice, chat: JsonObject?): Boolean = when (choice) {
    is ChatAgentChoice.Agent -> choice.id == (chat?.str("backend") ?: "")
    is ChatAgentChoice.Model -> choice.id == (chat?.str("model") ?: "")
    is ChatAgentChoice.Effort -> choice.id == (chat?.str("effort") ?: "")
}

/// Which field of `chat.update` a row writes.
internal fun chatAgentField(choice: ChatAgentChoice): Pair<String, String> = when (choice) {
    is ChatAgentChoice.Agent -> "backend" to choice.id
    is ChatAgentChoice.Model -> "model" to choice.id
    is ChatAgentChoice.Effort -> "effort" to choice.id
}

/// Whether picking this agent also forces Bypass, because it has no approval
/// protocol of its own to ask through.
internal fun chatAgentForcesBypass(backends: List<JsonObject>, id: String): Boolean =
    backendOf(backends, id)?.str("gateTier") == "bypassOnly"

/// What this conversation is answered by, in one line: agent, model, and the
/// effort only when the agent has one. Port of `ChatAgentChoices.summary`.
///
/// Named rather than left blank, the way the iPhone composer reads
/// "OpenCode · Default · Effort: Default". A gap where the model should be
/// looks like something failed to load. Effort is left out entirely for an
/// agent that does not offer one, rather than reading "Effort: Default" about
/// a control that does not exist.
internal fun chatAgentSummary(backends: List<JsonObject>, chat: JsonObject?): String {
    val id = chat?.str("backend").orEmpty()
    val backend = backendOf(backends, id)
    val agent = backend?.str("label")?.ifBlank { null }
        ?: id.ifBlank { null }?.let { ai.tokenstat.tokenstat.ui.logic.harnessName(it) }
        ?: "Agent"
    val parts = mutableListOf(agent)
    parts.add(chat?.str("model")?.ifBlank { null } ?: "Default")
    if (stringList(backend, "efforts").isNotEmpty()) {
        parts.add("Effort: ${chat?.str("effort")?.ifBlank { null } ?: "Default"}")
    }
    return parts.joinToString(" · ")
}

/// The bottom sheet: the three settings, the model list's own status, and the
/// way to install an agent that is not here yet.
///
/// The Refresh lives here, not in the app's settings, because this is where
/// somebody notices the list is short: they added an API key to a CLI a minute
/// ago and the provider it unlocked is not in the list yet.
@Composable
fun ChatAgentSheet(
    model: AppViewModel,
    peer: String,
    chatId: String,
    chat: JsonObject?,
    hostLabel: String,
    protocol: Long?,
    locked: Boolean,
    /// Held by the screen, because the composer's summary line reads the same
    /// list to say which agent is answering and whether it has an effort.
    backends: List<JsonObject>,
    onBackends: (List<JsonObject>) -> Unit,
    onChanged: () -> Unit,
    onDismiss: () -> Unit,
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

    suspend fun load(refresh: Boolean) {
        runCatching {
            model.workspaceSection(peer, "chat.backends", buildJsonObject { if (refresh) put("refresh", true) })
        }.onSuccess {
            onBackends(asObjects(it))
            refreshError = null
        }.onFailure {
            refreshError = TunnelCopy.display(it.message ?: "The request failed.", hostLabel.ifBlank { "that computer" })
        }
    }
    LaunchedEffect(peer, chatId) { if (backends.isEmpty()) load(refresh = false) }

    val current = backends.firstOrNull { it.str("id") == chat?.str("backend") }
    val choices = remember(backends, chat, pinned) { chatAgentChoices(backends, chat, pinned) }

    fun pick(choice: ChatAgentChoice) {
        if (updating || locked) return
        if (choice is ChatAgentChoice.Agent && backendNotInstalled(backendOf(backends, choice.id))) return
        val (field, value) = chatAgentField(choice)
        updating = true
        scope.launch {
            runCatching {
                model.workspaceSection(peer, "chat.update", buildJsonObject {
                    put("id", chatId)
                    put(field, value)
                    // An agent with no way to ask runs on Bypass or not at
                    // all, so picking it sets both in one write rather than
                    // leaving the conversation claiming it will ask.
                    if (choice is ChatAgentChoice.Agent && chatAgentForcesBypass(backends, choice.id)) {
                        put("autonomy", "bypass")
                    }
                })
            }.onSuccess {
                refreshError = null
                onChanged()
            }.onFailure {
                refreshError = TunnelCopy.display(it.message ?: "The request failed.", hostLabel.ifBlank { "that computer" })
            }
            updating = false
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
                    setupError = "Installation failed. " + (obj?.str("output").orEmpty().takeLast(600))
                }
                load(refresh = true)
            }.onFailure {
                setupError = TunnelCopy.display(it.message ?: "The request failed.", hostLabel.ifBlank { "that computer" })
            }
            installing = null
        }
    }

    TsPickerSheet(title = "Agent, model and effort", onDismiss = onDismiss) {
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
                    Text(
                        "Set up on ${hostLabel.ifBlank { "this computer" }}",
                        style = TsType.callout.copy(fontWeight = androidx.compose.ui.text.font.FontWeight.SemiBold),
                        color = colors.textPrimary,
                    )
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
                                        backendNotInstalled(backend) -> "Not installed"
                                        backend.str("readiness") == "needsSignIn" ||
                                            backend.str("readiness") == "expired" ->
                                            "Open this agent in the host's Terminal to sign in, then retry."
                                        backend.bol("installed") -> "Installed"
                                        else -> "Availability unknown"
                                    },
                                    style = TsType.caption,
                                    color = colors.controlGlyph,
                                )
                            }
                            if (backendNotInstalled(backend) && backend.bol("canInstall")) {
                                TsSecondaryButton(
                                    label = if (installing == backend.str("id")) "Installing…" else "Install",
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
                TsPickerOptionList(
                    choices = choices,
                    isSelected = { chatAgentIsSelected(it, chat) },
                    prompt = "Filter agents, models and efforts",
                    emptyMessage = "No agents installed. Set up an agent to start chatting.",
                    caption = "Agents on ${hostLabel.ifBlank { "this computer" }}",
                    onRefresh = if (HostContracts.supportsModelRefresh(protocol)) {
                        { load(refresh = true) }
                    } else {
                        null
                    },
                    sectionValue = { chatAgentSectionValue(it, backends, chat) },
                    sectionTabs = chatAgentSections(choices),
                    selectionSummary = chatAgentSummary(backends, chat),
                    enabled = !updating && !locked,
                    pick = ::pick,
                    accessory = { value ->
                        // The favourite star, on model rows only.
                        val id = (value as? ChatAgentChoice.Model)?.id
                        if (!id.isNullOrEmpty() && backendId.isNotEmpty()) {
                            val starred = id in pinned
                            Icon(
                                ActionIcon.Pinned.vector,
                                if (starred) "Unpin $id" else "Pin $id",
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
                    "Couldn't refresh models. Use the agent default or a previously listed model.",
                    style = TsType.caption,
                    color = colors.warning,
                    modifier = Modifier.padding(horizontal = Space.m),
                )
                "loading" -> Text(
                    "Checking models… Agent default is available.",
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
                    label = if (showingSetup) "Back to agent choices" else "Set up another agent…",
                    icon = if (showingSetup) ActionIcon.Back.vector else ActionIcon.Create.vector,
                    small = true,
                    enabled = !locked,
                    onClick = { showingSetup = !showingSetup },
                )
                Spacer(Modifier.weight(1f))
                TsSecondaryButton(
                    label = "Retry",
                    icon = ActionIcon.Refresh.vector,
                    small = true,
                    enabled = installing == null && !locked,
                    // A plain reload on an old host, a refresh where the host
                    // knows how: the same gate the inline Refresh keeps.
                    onClick = { scope.launch { load(refresh = HostContracts.supportsModelRefresh(protocol)) } },
                )
            }
        }
    }
}
