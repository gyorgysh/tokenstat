// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
package ai.tokenstat.tokenstat.ui.workspace

import ai.tokenstat.tokenstat.ui.components.TsBottomSheet
import ai.tokenstat.tokenstat.ui.components.ActionIcon
import ai.tokenstat.tokenstat.ui.components.Banner
import ai.tokenstat.tokenstat.ui.components.BannerSeverity
import ai.tokenstat.tokenstat.ui.components.BrandCheckbox
import ai.tokenstat.tokenstat.ui.components.TsAccentButton
import ai.tokenstat.tokenstat.ui.components.TsCard
import ai.tokenstat.tokenstat.ui.components.TsSecondaryButton
import ai.tokenstat.tokenstat.ui.components.TsType
import ai.tokenstat.tokenstat.ui.localization.L10n
import ai.tokenstat.tokenstat.ui.theme.LocalTsColors
import ai.tokenstat.tokenstat.ui.theme.Space
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.text.selection.SelectionContainer
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.Text
import androidx.compose.material3.rememberModalBottomSheetState
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import java.text.DateFormat
import java.util.Date
import java.util.UUID
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.launch
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.buildJsonArray
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.contentOrNull
import kotlinx.serialization.json.longOrNull
import kotlinx.serialization.json.put

/// Text shared on purpose, with the host's names for any files. Never a send.
internal data class HandoffDraft(val text: String, val attachmentIds: List<String> = emptyList())

internal suspend fun readSharedHandoffFiles(
    call: suspend (String, JsonObject) -> JsonElement,
    workspace: String,
    conversation: String,
    owner: String,
    ids: List<String>,
): List<StagedAttachment> {
    val unavailable = L10n.text("android.handoff.files_unavailable")
    require(ids.size <= 20 && ids.distinct().size == ids.size) { unavailable }
    val answer = gitFormRequest(call, "work.continuity.attachments", buildJsonObject {
        put("workspaceId", workspace)
        put("conversationId", conversation)
        put("attachmentIds", buildJsonArray { ids.forEach { add(JsonPrimitive(it)) } })
    }) as? JsonArray ?: error(unavailable)
    check(answer.size == ids.size) { unavailable }
    return answer.mapIndexed { index, row ->
        val file = row as? JsonObject ?: error(unavailable)
        val id = ids[index]
        val name = file.word("name")?.takeIf { it.isNotBlank() } ?: error(unavailable)
        val size = (file["size"] as? JsonPrimitive)?.longOrNull ?: error(unavailable)
        check(file.word("id") == id && size in 0..FILE_MAX.toLong()) { unavailable }
        StagedAttachment(name, "", file.word("mediaType"), size.toInt(), hostFile = StagedHostFile(id, owner))
    }
}

/// A row and how far down it the reader was, in basis points.
internal data class HandoffAnchor(val eventId: String, val fraction: Int, val followsLatest: Boolean)

/// What one device left for the others, kept by the conversation's computer.
/// Port of the Apple `WorkHandoff`.
internal data class WorkHandoff(
    val revision: Long,
    val requestId: String,
    val deviceId: String,
    val deviceName: String,
    val updatedAtMs: Long,
    val draft: HandoffDraft?,
    val anchor: HandoffAnchor?,
)

internal data class HandoffRequest(
    val requestId: String,
    val expectedRevision: Long,
    val deviceName: String,
    val draft: HandoffDraft?,
    val anchor: HandoffAnchor?,
) {
    fun json(workspace: String, conversation: String): JsonObject = buildJsonObject {
        put("workspaceId", workspace)
        put("conversationId", conversation)
        put("handoff", buildJsonObject {
            put("requestId", requestId)
            put("expectedRevision", expectedRevision)
            put("deviceName", deviceName)
            draft?.let { value ->
                put("draft", buildJsonObject {
                    put("text", value.text)
                    put("attachmentIds", buildJsonArray { value.attachmentIds.forEach { add(JsonPrimitive(it)) } })
                })
            }
            anchor?.let { value ->
                put("anchor", buildJsonObject {
                    put("eventId", value.eventId)
                    put("fraction", value.fraction)
                    put("followsLatest", value.followsLatest)
                })
            }
        })
    }
}

private fun JsonObject.word(key: String) = (this[key] as? JsonPrimitive)?.contentOrNull

internal fun parseHandoff(value: JsonElement?): WorkHandoff? {
    val item = value as? JsonObject ?: return null
    fun number(key: String) = (item[key] as? JsonPrimitive)?.longOrNull
    val draft = (item["draft"] as? JsonObject)?.let { shared ->
        HandoffDraft(
            shared.word("text").orEmpty(),
            (shared["attachmentIds"] as? JsonArray).orEmpty().mapNotNull { (it as? JsonPrimitive)?.contentOrNull },
        )
    }
    val anchor = (item["anchor"] as? JsonObject)?.let { place ->
        val id = place.word("eventId") ?: return@let null
        HandoffAnchor(id, place.word("fraction")?.toIntOrNull()?.coerceIn(0, 10_000) ?: 0, place.word("followsLatest") == "true")
    }
    return WorkHandoff(
        revision = number("revision") ?: return null,
        requestId = item.word("requestId") ?: return null,
        deviceId = item.word("deviceId") ?: return null,
        deviceName = item.word("deviceName").orEmpty(),
        updatedAtMs = number("updatedAtMs") ?: 0,
        draft = draft,
        anchor = anchor,
    )
}

private val STABLE_EVENT = Regex("^(?:(?:user|text|think|handoff|turn|usage|failed|tool|edit)-)?s(\\d+)$")

/// The host's own name for a row, or null for a row named by its place in the
/// page that was loaded. Only the first kind means the same row elsewhere. A
/// folded header stands for its first member.
internal fun stableEvent(rowId: String): String? = rowId.removePrefix("g:").takeIf { STABLE_EVENT.matches(it) }

private fun sequence(rowId: String): Long? = STABLE_EVENT.find(rowId.removePrefix("g:"))?.groupValues?.get(1)?.toLongOrNull()

/// Where the reader is, for another device. At the end there is no place to
/// keep, only that the end is where they were.
internal fun shareAnchor(visible: List<RowSpan>, rows: List<String>, atEnd: Boolean): HandoffAnchor? {
    if (atEnd) return rows.lastOrNull { stableEvent(it) != null }?.let { HandoffAnchor(stableEvent(it)!!, 0, true) }
    val row = visible.firstOrNull { it.key is String && it.key in rows && stableEvent(it.key) != null && it.offset + it.size > 0 }
        ?: return null
    val within = if (row.offset < 0 && row.size > 0) (-row.offset * 10_000L / row.size).toInt().coerceIn(0, 10_000) else 0
    return HandoffAnchor(stableEvent(row.key as String)!!, within, false)
}

/// The row to show for a shared place. Another page size or level of detail
/// can join a reply or fold a step, so without an exact match it is the last
/// row that starts at or before it. Null when the place is not loaded yet.
internal fun anchorRow(eventId: String, rows: List<String>): Int? {
    rows.indexOf(eventId).takeIf { it >= 0 }?.let { return it }
    rows.indexOf("g:$eventId").takeIf { it >= 0 }?.let { return it }
    val target = sequence(eventId) ?: return null
    return rows.withIndex().lastOrNull { (_, id) -> sequence(id)?.let { it <= target } == true }?.index
}

private enum class HandoffPhase { Loading, Ready, Sharing, Shared, Conflict, Failed }

/// Offered at the top of a conversation another device shared. A doorway to
/// the sheet, never a change to the draft or the scroll on its own.
@Composable
internal fun WorkHandoffOffer(record: WorkHandoff, onOpen: () -> Unit, onDismiss: () -> Unit) {
    val colors = LocalTsColors.current
    Row(
        Modifier.fillMaxWidth().background(colors.sidebar).padding(horizontal = Space.m, vertical = Space.xs),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        TsSecondaryButton(
            label = L10n.text("android.handoff.continue_from", record.deviceName),
            icon = ActionIcon.Device.vector,
            small = true,
            onClick = onOpen,
        )
        Spacer(Modifier.weight(1f))
        IconButton(onClick = onDismiss) {
            Icon(ActionIcon.Dismiss.vector, L10n.text("android.handoff.keep_working_here"), tint = colors.textSecondary)
        }
    }
}

/// Port of the Apple `WorkHandoffSheet`: share this place, or pick up what
/// another device shared. Reading a record never touches the composer.
@OptIn(ExperimentalMaterial3Api::class)
@Composable
internal fun WorkHandoffSheet(
    title: String,
    draft: String,
    files: List<StagedAttachment>,
    deviceName: String,
    call: suspend (String, JsonObject) -> JsonElement,
    workspace: String,
    conversation: String,
    anchor: () -> HandoffAnchor?,
    onPrepareFiles: suspend (List<StagedAttachment>) -> List<String>,
    onUseDraft: suspend (HandoffDraft) -> Unit,
    onContinueReading: (HandoffAnchor) -> Unit,
    onDismiss: () -> Unit,
) {
    val colors = LocalTsColors.current
    val scope = rememberCoroutineScope()
    var phase by remember { mutableStateOf(HandoffPhase.Loading) }
    var shared by remember { mutableStateOf<WorkHandoff?>(null) }
    // Fixed once a share starts, so typing cannot change an uncertain one.
    var pending by remember { mutableStateOf<HandoffRequest?>(null) }
    var loaded by remember { mutableStateOf(false) }
    var error by remember { mutableStateOf<String?>(null) }
    var includeDraft by remember { mutableStateOf(false) }
    var importing by remember { mutableStateOf(false) }

    suspend fun load() {
        phase = HandoffPhase.Loading
        error = null
        try {
            val answer = call("work.continuity.get", buildJsonObject {
                put("workspaceId", workspace); put("conversationId", conversation)
            })
            shared = parseHandoff((answer as? JsonObject)?.get("handoff"))
            loaded = true
            phase = HandoffPhase.Ready
        } catch (cancelled: CancellationException) { throw cancelled } catch (failure: Exception) {
            error = failure.message
            phase = HandoffPhase.Failed
        }
    }

    suspend fun send() {
        val request = pending ?: return
        phase = HandoffPhase.Sharing
        error = null
        try {
            val answer = call("work.continuity.put", request.json(workspace, conversation)) as? JsonObject
            if (answer?.word("status") == "saved") {
                shared = parseHandoff(answer["handoff"])
                pending = null
                phase = HandoffPhase.Shared
            } else {
                // Another device shared in between. Both versions stay until
                // the person picks one.
                shared = parseHandoff(answer?.get("current"))
                phase = HandoffPhase.Conflict
            }
        } catch (cancelled: CancellationException) { throw cancelled } catch (failure: Exception) {
            error = failure.message
            phase = HandoffPhase.Failed
        }
    }

    fun request(text: HandoffDraft?, place: HandoffAnchor?) =
        HandoffRequest(UUID.randomUUID().toString(), shared?.revision ?: 0, deviceName, text, place)

    suspend fun share() {
        if (phase == HandoffPhase.Loading || phase == HandoffPhase.Sharing || importing) return
        val place = anchor()
        phase = HandoffPhase.Sharing
        error = null
        try {
            val prepared = if (includeDraft && (draft.isNotEmpty() || files.isNotEmpty())) HandoffDraft(draft, onPrepareFiles(files)) else null
            pending = request(prepared, place)
            send()
        } catch (cancelled: CancellationException) { throw cancelled } catch (failure: Exception) {
            error = failure.message ?: L10n.text("android.handoff.files_unavailable")
            phase = HandoffPhase.Failed
        }
    }

    suspend fun use(draft: HandoffDraft) {
        if (importing || phase == HandoffPhase.Loading || phase == HandoffPhase.Sharing) return
        importing = true
        error = null
        try {
            onUseDraft(draft)
        } catch (cancelled: CancellationException) { throw cancelled } catch (failure: Exception) {
            error = failure.message ?: L10n.text("android.handoff.files_unavailable")
        } finally { importing = false }
    }

    LaunchedEffect(Unit) { load() }
    val busy = phase == HandoffPhase.Loading || phase == HandoffPhase.Sharing || importing
    TsBottomSheet(
        onDismissRequest = onDismiss,
        sheetState = rememberModalBottomSheetState(skipPartiallyExpanded = true),
        containerColor = colors.background,
    ) {
        Column(
            Modifier.fillMaxWidth().verticalScroll(rememberScrollState())
                .padding(horizontal = Space.l).padding(bottom = Space.xl),
            verticalArrangement = Arrangement.spacedBy(Space.m),
        ) {
            Text(L10n.text("android.handoff.title"), style = TsType.headline, color = colors.textPrimary)
            Text(title, style = TsType.caption, color = colors.textSecondary, maxLines = 1)
            Text(L10n.text("android.handoff.explanation"), style = TsType.body, color = colors.textSecondary)
            if (busy) {
                Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(Space.s)) {
                    CircularProgressIndicator(color = colors.accent)
                    Text(
                        if (phase == HandoffPhase.Sharing) L10n.text("android.handoff.sharing") else L10n.text("android.handoff.checking"),
                        style = TsType.body,
                        color = colors.textSecondary,
                    )
                }
            }
            error?.let { message ->
                Banner(message, BannerSeverity.WARNING)
                if (pending != null || !loaded) TsSecondaryButton(
                    label = L10n.text("android.handoff.try_again"),
                    icon = ActionIcon.Refresh.vector,
                    onClick = { scope.launch { if (pending != null) send() else load() } },
                )
            }
            if (phase == HandoffPhase.Conflict) Banner(L10n.text("android.handoff.conflict"), BannerSeverity.WARNING)
            shared?.takeIf { phase != HandoffPhase.Shared }?.let { record ->
                TsCard {
                    Column(verticalArrangement = Arrangement.spacedBy(Space.s)) {
                        Text(L10n.text("android.handoff.continue_from", record.deviceName), style = TsType.headline, color = colors.textPrimary)
                        Text(
                            L10n.text(
                                "android.handoff.shared_at",
                                DateFormat.getDateTimeInstance(DateFormat.MEDIUM, DateFormat.SHORT).format(Date(record.updatedAtMs)),
                            ),
                            style = TsType.caption,
                            color = colors.textSecondary,
                        )
                        record.draft?.let { value ->
                            DraftText(L10n.text("android.handoff.shared_draft"), value.text)
                            if (value.attachmentIds.isNotEmpty()) {
                                Text(handoffFileCount(value.attachmentIds.size), style = TsType.caption, color = colors.textSecondary)
                            }
                            if (draft.isNotEmpty() || files.isNotEmpty()) {
                                DraftText(L10n.text("android.handoff.on_this_device"), draft)
                                if (files.isNotEmpty()) Text(handoffFileCount(files.size), style = TsType.caption, color = colors.textSecondary)
                                Text(L10n.text("android.handoff.replaces"), style = TsType.caption, color = colors.textSecondary)
                            }
                            TsAccentButton(
                                label = L10n.text("android.handoff.use_this"),
                                icon = ActionIcon.Restore.vector,
                                enabled = !busy,
                                onClick = { scope.launch { use(value) } },
                                modifier = Modifier.fillMaxWidth(),
                            )
                        }
                        record.anchor?.let { place ->
                            TsSecondaryButton(
                                label = L10n.text("android.handoff.continue_reading"),
                                icon = ActionIcon.History.vector,
                                enabled = !busy,
                                onClick = { onContinueReading(place) },
                                modifier = Modifier.fillMaxWidth(),
                            )
                        }
                    }
                }
            }
            when {
                phase == HandoffPhase.Conflict -> {
                    pending?.draft?.let { DraftText(L10n.text("android.handoff.your_version"), it.text) }
                    TsSecondaryButton(
                        label = L10n.text("android.handoff.keep_mine"),
                        icon = ActionIcon.Done.vector,
                        onClick = { pending = null; phase = HandoffPhase.Ready },
                        modifier = Modifier.fillMaxWidth(),
                    )
                    TsAccentButton(
                        label = L10n.text("android.handoff.share_my_version"),
                        icon = ActionIcon.Upload.vector,
                        onClick = {
                            pending?.let { mine -> pending = request(mine.draft, mine.anchor) }
                            scope.launch { send() }
                        },
                        modifier = Modifier.fillMaxWidth(),
                    )
                }
                phase == HandoffPhase.Shared -> TsCard {
                    Text(L10n.text("android.handoff.ready_title"), style = TsType.headline, color = colors.textPrimary)
                    Text(L10n.text("android.handoff.ready_help"), style = TsType.body, color = colors.textSecondary)
                }
                loaded && pending == null && !busy -> {
                    if (draft.isNotEmpty() || files.isNotEmpty()) {
                        BrandCheckbox(includeDraft, { includeDraft = !includeDraft }, L10n.text("android.handoff.include_draft"))
                        if (includeDraft && files.isNotEmpty()) {
                            Text(handoffFileCount(files.size), style = TsType.caption, color = colors.textSecondary)
                        }
                    }
                    TsAccentButton(
                        label = L10n.text("android.handoff.share_place"),
                        icon = ActionIcon.Upload.vector,
                        onClick = { scope.launch { share() } },
                        modifier = Modifier.fillMaxWidth(),
                    )
                }
            }
            Text(L10n.text("android.handoff.privacy"), style = TsType.caption, color = colors.textTertiary)
        }
    }
}

private fun handoffFileCount(count: Int): String = if (count == 1) L10n.text("android.handoff.files.one", "$count")
    else L10n.text("android.handoff.files.other", "$count")

@Composable
private fun DraftText(title: String, text: String) {
    val colors = LocalTsColors.current
    Column(verticalArrangement = Arrangement.spacedBy(Space.xs)) {
        Text(title, style = TsType.caption, color = colors.textSecondary)
        SelectionContainer { Text(text, style = TsType.body, color = colors.textPrimary) }
    }
}
