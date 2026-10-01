// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
package ai.tokenstat.tokenstat.ui.persona

import ai.tokenstat.tokenstat.ui.localization.L10n

import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.interaction.MutableInteractionSource
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.ExperimentalLayoutApi
import androidx.compose.foundation.layout.FlowRow
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.DropdownMenu
import androidx.compose.material3.DropdownMenuItem
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.OutlinedTextField
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
import androidx.compose.ui.text.TextStyle
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.compose.ui.window.Dialog
import androidx.compose.ui.window.DialogProperties
import ai.tokenstat.tokenstat.AppViewModel
import ai.tokenstat.tokenstat.ui.components.Banner
import ai.tokenstat.tokenstat.ui.components.BannerSeverity
import ai.tokenstat.tokenstat.ui.components.TsAccentButton
import ai.tokenstat.tokenstat.ui.components.TsBrandSwitch
import ai.tokenstat.tokenstat.ui.components.TsSecondaryButton
import ai.tokenstat.tokenstat.ui.theme.LocalTsColors
import ai.tokenstat.tokenstat.ui.theme.Space
import kotlinx.coroutines.launch
import kotlinx.serialization.json.JsonNull
import kotlinx.serialization.json.buildJsonObject

/// Personas: a name, a brief, and a face, on one form. Port of the phone
/// `PersonaEditor`.
///
/// There is no rail and no describe/draft/review wizard. The sheet opens on
/// the folder default. New persona, Improve with agent, and Save as written
/// all edit the same two fields. Generated text is a draft until Save.
///
/// Wiring into chat setup is intentionally not here: the caller owns that (see
/// WIRING) and this sheet only needs the peer and the folder id.
@OptIn(ExperimentalLayoutApi::class)
@Composable
fun PersonaSheet(model: AppViewModel, peer: String, workspaceId: String, onDismiss: () -> Unit) {
    val colors = LocalTsColors.current
    val scope = rememberCoroutineScope()
    var personas by remember { mutableStateOf<List<ChatPersona>>(emptyList()) }
    var defaultId by remember { mutableStateOf<String?>(null) }
    var backends by remember { mutableStateOf<List<PersonaBackend>>(emptyList()) }
    var loading by remember { mutableStateOf(true) }
    var draft by remember { mutableStateOf(ChatPersona.blank()) }
    var isNew by remember { mutableStateOf(true) }
    var drafter by remember { mutableStateOf("") }
    var improving by remember { mutableStateOf(false) }
    var saving by remember { mutableStateOf(false) }
    var failure by remember { mutableStateOf<String?>(null) }
    var confirmingDelete by remember { mutableStateOf(false) }
    var pickerOpen by remember { mutableStateOf(false) }
    var defaultOpen by remember { mutableStateOf(false) }
    var backendOpen by remember { mutableStateOf(false) }

    fun reconcileSelection() {
        if (improving || saving) return
        if (!isNew && draft.id.isNotEmpty() && personas.any { it.id == draft.id }) return
        val fallback = defaultId?.let { id -> personas.firstOrNull { it.id == id } } ?: personas.firstOrNull()
        if (fallback != null) {
            draft = fallback
            isNew = false
        } else if (!isNew) {
            draft = ChatPersona.blank()
            isNew = true
        }
    }

    suspend fun load() {
        loading = true
        failure = null
        runCatching { model.workspaceSection(peer, "chat.personas", personaScopeParams(workspaceId)) }
            .onSuccess { element ->
                val (list, current) = parseChatPersonaList(element)
                personas = list
                defaultId = current
            }
            .onFailure { failure = it.message ?: L10n.text("android.personasheet.the_request_failed.db4fb447") }
        runCatching { model.workspaceSection(peer, "chat.backends", buildJsonObject {}) }
            .onSuccess { element -> backends = parsePersonaBackends(element) }
            .onFailure { backends = emptyList() }
        if (drafter.isEmpty() || backends.none { it.id == drafter }) {
            drafter = backends.firstOrNull()?.id ?: ""
        }
        loading = false
        reconcileSelection()
    }

    LaunchedEffect(peer, workspaceId) { load() }

    fun select(persona: ChatPersona) {
        improving = false
        draft = persona
        isNew = false
        failure = null
        confirmingDelete = false
    }

    fun startNew() {
        draft = ChatPersona.blank()
        isNew = true
        improving = false
        failure = null
        confirmingDelete = false
        if (drafter.isEmpty() || backends.none { it.id == drafter }) {
            drafter = backends.firstOrNull()?.id ?: ""
        }
    }

    val isDefault = !isNew && draft.id.isNotEmpty() && draft.id == defaultId
    val canDelete = !isNew && draft.id.isNotEmpty() && !isDefault
    val canSave = !improving && !saving && !loading && draft.name.trim().isNotEmpty()
    val canImprove = !improving && !saving && !loading && drafter.isNotEmpty() &&
        draft.systemPrompt.trim().isNotEmpty()

    fun save() {
        val name = draft.name.trim()
        if (name.isEmpty()) return
        val persona = draft.copy(name = name)
        saving = true
        failure = null
        scope.launch {
            runCatching { model.workspaceSection(peer, "chat.personaSave", personaSaveParams(persona, workspaceId)) }
                .onSuccess { element ->
                    val saved = parseChatPersona(element) ?: persona
                    personas = if (personas.any { it.id == saved.id }) {
                        personas.map { if (it.id == saved.id) saved else it }
                    } else {
                        personas + saved
                    }
                    select(saved)
                }
                .onFailure { failure = it.message ?: L10n.text("android.personasheet.the_request_failed.db4fb447") }
            saving = false
        }
    }

    fun remove() {
        if (!canDelete) return
        val persona = draft
        saving = true
        failure = null
        scope.launch {
            runCatching { model.workspaceSection(peer, "chat.personaRemove", personaRemoveParams(persona.id)) }
                .onSuccess {
                    personas = personas.filter { it.id != persona.id }
                    confirmingDelete = false
                    startNew()
                    reconcileSelection()
                }
                .onFailure { failure = it.message ?: L10n.text("android.personasheet.the_request_failed.db4fb447") }
            saving = false
        }
    }

    fun improve() {
        val brief = draft.systemPrompt.trim()
        if (!canImprove || brief.isEmpty()) return
        val suppliedName = draft.name.trim()
        improving = true
        failure = null
        scope.launch {
            runCatching {
                model.workspaceSection(
                    peer,
                    "chat.personaDraft",
                    personaDraftParams(brief, drafter, suppliedName.ifEmpty { null }),
                )
            }.onSuccess { element ->
                parseChatPersonaDraft(element)?.let { result ->
                    if (suppliedName.isEmpty()) draft = draft.copy(name = result.name)
                    draft = draft.copy(systemPrompt = result.systemPrompt)
                }
            }.onFailure { failure = it.message ?: L10n.text("android.personasheet.the_request_failed.db4fb447") }
            improving = false
        }
    }

    fun setDefault(persona: ChatPersona?) {
        saving = true
        failure = null
        scope.launch {
            runCatching {
                model.workspaceSection(peer, "chat.personaDefault", personaDefaultParams(workspaceId, persona?.id ?: ""))
            }.onSuccess { element ->
                // An empty id means no persona, and comes back as null rather
                // than as an error.
                defaultId = if (element is JsonNull) null else parseChatPersona(element)?.id ?: persona?.id
            }.onFailure { failure = it.message ?: L10n.text("android.personasheet.the_request_failed.db4fb447") }
            saving = false
        }
    }

    Dialog(onDismissRequest = onDismiss, properties = DialogProperties(usePlatformDefaultWidth = false)) {
        Column(
            Modifier
                .fillMaxWidth()
                .padding(Space.m)
                .clip(RoundedCornerShape(14.dp))
                .background(colors.background)
                .padding(Space.m),
            verticalArrangement = Arrangement.spacedBy(Space.m),
        ) {
            Row(verticalAlignment = Alignment.CenterVertically) {
                Column(Modifier.weight(1f)) {
                    Text(
                        L10n.text("android.personasheet.personas.fa2ea3fb"),
                        style = TextStyle(fontSize = 17.sp, fontWeight = FontWeight.SemiBold),
                        color = colors.textPrimary,
                    )
                    Text(
                        L10n.text("android.personasheet.choose_how_new_chats_in_this_folder_should.feb16e26"),
                        style = TextStyle(fontSize = 12.sp),
                        color = colors.textSecondary,
                    )
                }
                TsSecondaryButton(label = L10n.text("common.done"), small = true, onClick = onDismiss)
            }
            if (loading) {
                Text(L10n.text("android.personasheet.loading.ba3bbbe1"), style = TextStyle(fontSize = 14.sp), color = colors.textSecondary)
                return@Column
            }
            Column(
                Modifier.verticalScroll(rememberScrollState()),
                verticalArrangement = Arrangement.spacedBy(Space.m),
            ) {
                Row(
                    horizontalArrangement = Arrangement.spacedBy(Space.m),
                    verticalAlignment = Alignment.CenterVertically,
                ) {
                    Box {
                        val label = if (isNew) {
                            L10n.text("android.personasheet.new_persona.044eafe2")
                        } else {
                            draft.name + if (isDefault) L10n.text("android.personasheet.default.2a7e0b7b") else ""
                        }
                        TsSecondaryButton(label = label.ifEmpty { L10n.text("android.personasheet.choose.c7f93783") }, small = true, onClick = { pickerOpen = true })
                        DropdownMenu(expanded = pickerOpen, onDismissRequest = { pickerOpen = false }) {
                            if (isNew) {
                                DropdownMenuItem(text = { Text(L10n.text("android.personasheet.new_persona.044eafe2")) }, onClick = { pickerOpen = false })
                            }
                            personas.forEach { persona ->
                                val suffix = if (persona.id == defaultId) L10n.text("android.personasheet.default.2a7e0b7b") else L10n.text("android.personasheet..e3b0c442")
                                DropdownMenuItem(
                                    text = { Text(persona.name + suffix) },
                                    onClick = {
                                        pickerOpen = false
                                        select(persona)
                                    },
                                )
                            }
                        }
                    }
                    TsSecondaryButton(
                        label = L10n.text("android.personasheet.new_persona.044eafe2"),
                        small = true,
                        enabled = !improving && !saving,
                        onClick = ::startNew,
                    )
                }
                Row(
                    horizontalArrangement = Arrangement.spacedBy(Space.m),
                    verticalAlignment = Alignment.CenterVertically,
                ) {
                    PersonaMark(seed = faceSeedFor(draft), size = 36.dp)
                    Column(
                        Modifier.weight(1f),
                        verticalArrangement = Arrangement.spacedBy(Space.s),
                    ) {
                        OutlinedTextField(
                            draft.name,
                            { draft = draft.copy(name = it) },
                            modifier = Modifier.fillMaxWidth(),
                            placeholder = { Text(L10n.text("android.personasheet.name.dcd1d522")) },
                            singleLine = true,
                            enabled = !improving && !saving,
                        )
                        Row(
                            horizontalArrangement = Arrangement.spacedBy(Space.s),
                            verticalAlignment = Alignment.CenterVertically,
                        ) {
                            TsSecondaryButton(
                                label = L10n.text("android.personasheet.reroll.18363dbe"),
                                small = true,
                                enabled = !improving && !saving,
                                onClick = { draft = draft.copy(seed = personaSeed("${draft.id}-${java.util.UUID.randomUUID()}")) },
                            )
                            if (isDefault) {
                                Text(
                                    L10n.text("android.personasheet.default.21b111cb"),
                                    style = TextStyle(fontSize = 12.sp, fontWeight = FontWeight.Medium),
                                    color = colors.accent,
                                    modifier = Modifier
                                        .clip(RoundedCornerShape(50))
                                        .background(colors.accentSoft)
                                        .padding(horizontal = 8.dp, vertical = 4.dp),
                                )
                            }
                            Spacer(Modifier.weight(1f))
                            Text(
                                L10n.text("android.personasheet.every_folder.9836340c"),
                                style = TextStyle(fontSize = 12.sp),
                                color = colors.textSecondary,
                            )
                            TsBrandSwitch(
                                checked = draft.workspaceId == null,
                                onCheckedChange = { shared ->
                                    draft = draft.copy(workspaceId = if (shared) null else workspaceId)
                                },
                            )
                        }
                    }
                }
                Column(verticalArrangement = Arrangement.spacedBy(Space.s)) {
                    Text(
                        L10n.text("android.personasheet.what_should_it_be_good_at_and_how_should_i.b3533c88"),
                        style = TextStyle(fontSize = 16.sp, fontWeight = FontWeight.SemiBold),
                        color = colors.textPrimary,
                    )
                    OutlinedTextField(
                        draft.systemPrompt,
                        { draft = draft.copy(systemPrompt = it) },
                        modifier = Modifier.fillMaxWidth(),
                        placeholder = { Text(L10n.text("android.personasheet.someone_who_explains_rust_errors_patiently.cee24939")) },
                        minLines = 3,
                        enabled = !improving && !saving,
                    )
                    Text(
                        L10n.text("android.personasheet.sent_to_whichever_agent_the_chat_is_on_it.19125f42"),
                        style = TextStyle(fontSize = 12.sp),
                        color = colors.textSecondary,
                    )
                    FlowRow(
                        horizontalArrangement = Arrangement.spacedBy(6.dp),
                        verticalArrangement = Arrangement.spacedBy(6.dp),
                    ) {
                        personaStartingPoints.forEach { (label, prompt) ->
                            Text(
                                label,
                                style = TextStyle(fontSize = 12.sp, fontWeight = FontWeight.Medium),
                                color = colors.accent,
                                modifier = Modifier
                                    .clip(RoundedCornerShape(50))
                                    .background(colors.accentSoft)
                                    .clickable(
                                        indication = null,
                                        interactionSource = remember { MutableInteractionSource() },
                                        enabled = !improving && !saving,
                                        onClick = { draft = draft.copy(systemPrompt = prompt) },
                                    )
                                    .padding(horizontal = 9.dp, vertical = 5.dp),
                            )
                        }
                    }
                }
                if (improving) {
                    Row(
                        horizontalArrangement = Arrangement.spacedBy(Space.s),
                        verticalAlignment = Alignment.CenterVertically,
                    ) {
                        PersonaMark(seed = faceSeedFor(draft), size = 30.dp)
                        Text(
                            L10n.text("android.personasheet.improving.e1129ace"),
                            style = TextStyle(fontSize = 16.sp, fontWeight = FontWeight.Medium),
                            color = colors.textPrimary,
                        )
                        Text(
                            L10n.text("android.personasheet.one_turn_on_0.7deee84a", "${backends.firstOrNull { it.id == drafter }?.label ?: drafter}"),
                            style = TextStyle(fontSize = 12.sp),
                            color = colors.textSecondary,
                        )
                    }
                }
                if (saving) {
                    Text(
                        L10n.text("android.personasheet.saving_changes.39520758"),
                        style = TextStyle(fontSize = 12.sp),
                        color = colors.controlGlyph,
                    )
                }
                failure?.let { Banner(it, BannerSeverity.DANGER) }
                Column(verticalArrangement = Arrangement.spacedBy(Space.s)) {
                    Row(
                        horizontalArrangement = Arrangement.spacedBy(Space.s),
                        verticalAlignment = Alignment.CenterVertically,
                    ) {
                        Text(
                            L10n.text("android.personasheet.improve_with.893197e0"),
                            style = TextStyle(fontSize = 14.sp),
                            color = colors.textPrimary,
                        )
                        Box {
                            val backendLabel = backends.firstOrNull { it.id == drafter }?.label ?: drafter.ifEmpty { L10n.text("android.personasheet.none.dc937b59") }
                            TsSecondaryButton(
                                label = backendLabel,
                                small = true,
                                enabled = !improving && backends.isNotEmpty(),
                                onClick = { backendOpen = true },
                            )
                            DropdownMenu(expanded = backendOpen, onDismissRequest = { backendOpen = false }) {
                                backends.forEach { backend ->
                                    DropdownMenuItem(
                                        text = { Text(backend.label) },
                                        onClick = {
                                            backendOpen = false
                                            drafter = backend.id
                                        },
                                    )
                                }
                            }
                        }
                    }
                    Text(
                        L10n.text("android.personasheet.one_short_turn_on_that_agent_in_a_temporar.6be85303"),
                        style = TextStyle(fontSize = 12.sp),
                        color = colors.textSecondary,
                    )
                }
                HorizontalDivider(color = colors.border)
                // Which persona new chats in this folder inherit, including
                // none. A row rather than a button on whichever persona is
                // open, so there is a way to say "none of them".
                Row(verticalAlignment = Alignment.CenterVertically) {
                    Column(Modifier.weight(1f)) {
                        Text(
                            L10n.text("android.personasheet.new_chats_here.cc6a9bf2"),
                            style = TextStyle(fontSize = 16.sp, fontWeight = FontWeight.Medium),
                            color = colors.textPrimary,
                        )
                        Text(
                            L10n.text("android.personasheet.existing_conversations_keep_whatever_they.b48e4eab"),
                            style = TextStyle(fontSize = 12.sp),
                            color = colors.textSecondary,
                        )
                    }
                    Box {
                        val current = defaultId?.let { id -> personas.firstOrNull { it.id == id } }
                        TsSecondaryButton(
                            label = current?.name ?: L10n.text("android.personasheet.no_persona.cce53fca"),
                            small = true,
                            enabled = !improving && !saving,
                            onClick = { defaultOpen = true },
                        )
                        DropdownMenu(expanded = defaultOpen, onDismissRequest = { defaultOpen = false }) {
                            DropdownMenuItem(
                                text = { Text(L10n.text("android.personasheet.no_persona.cce53fca")) },
                                onClick = {
                                    defaultOpen = false
                                    setDefault(null)
                                },
                            )
                            personas.forEach { persona ->
                                DropdownMenuItem(
                                    text = { Text(persona.name) },
                                    onClick = {
                                        defaultOpen = false
                                        setDefault(persona)
                                    },
                                )
                            }
                        }
                    }
                }
                if (confirmingDelete) {
                    Banner(L10n.text("android.personasheet.delete_0_this_cannot_be_undone.90a170bf", "${draft.name}"), BannerSeverity.DANGER)
                }
                Column(verticalArrangement = Arrangement.spacedBy(Space.s)) {
                    if (canDelete || confirmingDelete) {
                        TsSecondaryButton(
                            label = if (confirmingDelete) L10n.text("android.personasheet.confirm_delete.da00fa96") else L10n.text("common.delete"),
                            enabled = !improving && !saving,
                            onClick = {
                                if (confirmingDelete) remove() else confirmingDelete = true
                            },
                        )
                    }
                    Row(horizontalArrangement = Arrangement.spacedBy(Space.s)) {
                        TsSecondaryButton(
                            label = L10n.text("android.personasheet.improve_with_agent.6ccc3e33"),
                            enabled = canImprove,
                            onClick = ::improve,
                        )
                        Spacer(Modifier.weight(1f))
                        TsAccentButton(label = L10n.text("android.personasheet.save_as_written.96a0d96e"), enabled = canSave, onClick = ::save)
                    }
                }
            }
        }
    }
}
