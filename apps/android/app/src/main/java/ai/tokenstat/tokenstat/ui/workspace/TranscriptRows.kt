// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
package ai.tokenstat.tokenstat.ui.workspace

import ai.tokenstat.tokenstat.ui.localization.L10n

import ai.tokenstat.tokenstat.AppViewModel
import ai.tokenstat.tokenstat.ui.components.ActionIcon
import ai.tokenstat.tokenstat.ui.components.TsAccentButton
import ai.tokenstat.tokenstat.ui.components.TsSecondaryButton
import ai.tokenstat.tokenstat.ui.components.TsType
import ai.tokenstat.tokenstat.ui.logic.ChatSeat
import ai.tokenstat.tokenstat.ui.logic.TunnelCopy
import ai.tokenstat.tokenstat.ui.logic.harnessName
import ai.tokenstat.tokenstat.ui.theme.LocalTsColors
import ai.tokenstat.tokenstat.ui.theme.Space
import ai.tokenstat.tokenstat.ui.theme.cardRadius
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.ui.draw.drawBehind
import androidx.compose.ui.draw.rotate
import androidx.compose.ui.geometry.Offset
import androidx.compose.material.icons.automirrored.filled.KeyboardArrowRight
import androidx.compose.material.icons.automirrored.filled.List
import androidx.compose.material.icons.filled.Lightbulb
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.IntrinsicSize
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxHeight
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.ui.platform.ClipEntry
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Book
import androidx.compose.material.icons.filled.Build
import androidx.compose.material.icons.filled.Check
import androidx.compose.material.icons.filled.Description
import androidx.compose.material.icons.filled.Edit
import androidx.compose.material.icons.filled.Folder
import androidx.compose.material.icons.filled.Person
import androidx.compose.material.icons.filled.Search
import androidx.compose.material.icons.filled.Star
import androidx.compose.material.icons.filled.Terminal
import androidx.compose.material3.Card
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
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
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.platform.LocalClipboard
import androidx.compose.ui.text.AnnotatedString
import androidx.compose.ui.text.LinkAnnotation
import androidx.compose.ui.text.SpanStyle
import androidx.compose.ui.text.withLink
import androidx.compose.ui.text.TextStyle
import androidx.compose.ui.text.buildAnnotatedString
import androidx.compose.ui.text.font.FontStyle
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.text.withStyle
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import kotlinx.coroutines.launch
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.contentOrNull
import kotlinx.serialization.json.put

/// One coalesced transcript row. Ported from ClientChatRows.swift
/// `ClientChatEventRow`: user bubbles right, assistant prose in a panel with
/// the agent name in accent, tools as ToolRow cards, edits as file cards.
@Composable
internal fun TranscriptItemRow(
    item: ChatDisplayItem,
    model: AppViewModel,
    peer: String,
    chatId: String,
    hostLabel: String,
    defaultAgentName: String,
    /// The Detailed level: tool output and diffs start open.
    expandsOutput: Boolean = false,
    /// Opens or folds a step group, by the group's row id.
    onToggleGroup: (String) -> Unit = {},
    canAnswerQuestions: Boolean = true,
    /// Opens the folder's changes. Null where there is no folder to open.
    onReviewChanges: (() -> Unit)? = null,
) {
    val scope = rememberCoroutineScope()
    when (item) {
        is ChatDisplayItem.Group ->
            if (item.group.plain) {
                PlainStepLine(group = item.group, onClick = { onToggleGroup(item.id) })
            } else {
                StepGroupRow(group = item.group, onClick = { onToggleGroup(item.id) })
            }
        is ChatDisplayItem.Changes -> TurnChangesCard(item, onReviewChanges)
        is ChatDisplayItem.GroupStep -> {
            // Inset under its open header, with a rule down the left so the
            // steps read as belonging to the line above them.
            val rule = LocalTsColors.current.border
            Box(
                Modifier
                    .fillMaxWidth()
                    .drawBehind {
                        drawLine(rule, Offset(13.dp.toPx(), 0f), Offset(13.dp.toPx(), size.height), 1.dp.toPx())
                    }
                    .padding(start = 20.dp),
            ) {
                when (item.plain) {
                    PlainStep.Detail -> PlainStepDetail(item.item)
                    PlainStep.Line -> PlainStepRow(item.item)
                    null -> TranscriptItemRow(
                    item = item.item,
                    model = model,
                    peer = peer,
                    chatId = chatId,
                    hostLabel = hostLabel,
                    defaultAgentName = defaultAgentName,
                    expandsOutput = expandsOutput,
                    onToggleGroup = onToggleGroup,
                    canAnswerQuestions = canAnswerQuestions,
                    onReviewChanges = onReviewChanges,
                )
                }
            }
        }
        is ChatDisplayItem.User -> {
            Row(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.End) {
                Spacer(Modifier.width(36.dp))
                Text(
                    item.text,
                    style = TsType.chatBody,
                    color = LocalTsColors.current.textPrimary,
                    modifier = Modifier
                        .clip(RoundedCornerShape(16.dp))
                        .background(LocalTsColors.current.accentSoft)
                        .padding(Space.m),
                )
            }
        }
        is ChatDisplayItem.Assistant -> AssistantPanel(
            text = item.text,
            agentName = item.backend?.let { harnessName(it) } ?: defaultAgentName,
        )
        is ChatDisplayItem.TurnSeparator -> {
            Row(
                Modifier.fillMaxWidth(),
                verticalAlignment = Alignment.CenterVertically,
                horizontalArrangement = Arrangement.spacedBy(Space.s),
            ) {
                HorizontalDivider(Modifier.weight(1f), color = LocalTsColors.current.border)
                Text(
                    L10n.text("android.transcriptrows.0_new_turn.9f36f0a8", "${harnessName(item.backend)}"),
                    style = TextStyle(fontSize = 12.sp, fontWeight = FontWeight.Medium),
                    color = LocalTsColors.current.accent,
                )
                HorizontalDivider(Modifier.weight(1f), color = LocalTsColors.current.border)
            }
        }
        is ChatDisplayItem.Handoff -> HandoffRow(to = item.to, brief = item.brief)
        is ChatDisplayItem.Thinking -> {
            // Reasoning stays an aside: small, secondary, markdown.
            MarkdownText(
                text = item.text,
                baseStyle = TextStyle(fontSize = 12.sp),
                color = LocalTsColors.current.textSecondary,
                presentation = MarkdownPresentation.Aside,
                modifier = Modifier.fillMaxWidth(),
            )
        }
        is ChatDisplayItem.Tool -> TranscriptToolRow(state = item.state, expandsOutput = expandsOutput)
        is ChatDisplayItem.Edit -> TranscriptEditCard(state = item.state, expandsOutput = expandsOutput)
        is ChatDisplayItem.Attachment -> AttachmentRow(
            item = item,
            model = model,
            peer = peer,
            chatId = chatId,
            hostLabel = hostLabel,
        )
        is ChatDisplayItem.Question -> {
            var sending by remember(item.question.id) { mutableStateOf(false) }
            var error by remember(item.question.id) { mutableStateOf<String?>(null) }
            QuestionCard(item.question, sending, error, canAnswer = canAnswerQuestions) { answer ->
                if (sending || !canAnswerQuestions) return@QuestionCard
                sending = true
                scope.launch {
                    runCatching {
                        model.workspaceSection(peer, "chat.answerQuestion", buildJsonObject {
                            put("id", chatId)
                            put("questionId", item.question.id)
                            put("text", answer)
                        })
                    }.onSuccess { error = null }.onFailure { error = it.message }
                    // The answer comes back on the next poll of the transcript,
                    // and the card turns answered then on every device.
                    sending = false
                }
            }
        }
        is ChatDisplayItem.Approval -> ApprovalCard(
            approval = item.raw,
            onResolve = { choice ->
                scope.launch {
                    runCatching {
                        model.workspaceSection(peer, "chat.resolveApproval", buildJsonObject {
                            put("id", item.raw.str("id") ?: "")
                            put("choice", choice)
                        })
                    }
                }
            },
        )
        is ChatDisplayItem.Usage -> {
            Row(horizontalArrangement = Arrangement.spacedBy(Space.s)) {
                Text(
                    L10n.text("android.transcriptrows.0_in_1_out.f48051a0", "${item.input}", "${item.output}"),
                    style = TextStyle(fontSize = 12.sp),
                    color = LocalTsColors.current.textSecondary,
                )
                val cost = item.costUsd
                if (cost != null && cost > 0) {
                    Text(
                        "$" + "%.2f".format(cost),
                        style = TextStyle(fontSize = 12.sp),
                        color = LocalTsColors.current.accent,
                    )
                }
            }
        }
        is ChatDisplayItem.Failed -> {
            Text(
                item.text,
                style = TextStyle(fontSize = 13.sp, fontWeight = FontWeight.Medium),
                color = LocalTsColors.current.danger,
            )
        }
    }
}

@Composable
private fun AssistantPanel(text: String, agentName: String) {
    val colors = LocalTsColors.current
    val clipboard = LocalClipboard.current
    val copyScope = rememberCoroutineScope()
    var copied by remember(text) { mutableStateOf(false) }
    Column(
        Modifier
            .fillMaxWidth()
            .clip(RoundedCornerShape(16.dp))
            .background(colors.panel.copy(alpha = 0.72f))
            .border(1.dp, colors.border.copy(alpha = 0.72f), RoundedCornerShape(16.dp))
            .padding(Space.m),
        verticalArrangement = Arrangement.spacedBy(Space.s),
    ) {
        Row(verticalAlignment = Alignment.CenterVertically) {
            Icon(
                Icons.Default.Star,
                null,
                tint = colors.accent,
                modifier = Modifier.size(14.dp),
            )
            Spacer(Modifier.width(Space.s))
            Text(
                agentName,
                style = TextStyle(fontSize = 12.sp, fontWeight = FontWeight.Medium),
                color = colors.accent,
                modifier = Modifier.weight(1f),
            )
            IconButton(onClick = {
                copyScope.launch {
                    clipboard.setClipEntry(
                        ClipEntry(android.content.ClipData.newPlainText("response", text)),
                    )
                    copied = true
                }
            }, modifier = Modifier.size(28.dp)) {
                Icon(
                    if (copied) Icons.Default.Check else ActionIcon.Copy.vector,
                    L10n.text("android.transcriptrows.copy_response.f0f755af"),
                    tint = colors.textSecondary,
                    modifier = Modifier.size(16.dp),
                )
            }
        }
        MarkdownText(
            text = text,
            baseStyle = TsType.chatBody,
            color = colors.textPrimary,
            presentation = MarkdownPresentation.Chat,
            modifier = Modifier.fillMaxWidth(),
        )
    }
}

@Composable
private fun HandoffRow(to: String, brief: String) {
    val colors = LocalTsColors.current
    var expanded by remember { mutableStateOf(false) }
    Column(
        Modifier
            .fillMaxWidth()
            .padding(vertical = Space.xs),
        verticalArrangement = Arrangement.spacedBy(Space.xs),
    ) {
        Row(horizontalArrangement = Arrangement.spacedBy(Space.s)) {
            Text(
                L10n.text("android.transcriptrows.handed_to_0.902d7234", "${to.ifBlank { L10n.text("android.transcriptrows.another_agent.03a23179") }}"),
                style = TextStyle(fontSize = 12.sp, fontWeight = FontWeight.Medium),
                color = colors.accent,
                modifier = Modifier.weight(1f),
            )
            if (brief.isNotBlank()) {
                Text(
                    if (expanded) L10n.text("android.transcriptrows.hide.ac20a57b") else L10n.text("android.transcriptrows.what_it_was_told.4b2128b2"),
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

/// A tool call on a transcript: verb, target, optional snippet, and how it
/// ended. Ported from Design/ToolRow.swift.
@Composable
private fun TranscriptToolRow(state: ChatToolState, expandsOutput: Boolean = false) {
    val colors = LocalTsColors.current
    var showSnippet by remember { mutableStateOf(false) }
    var snippetToggled by remember { mutableStateOf(false) }
    val hasDiff = (state.verb == "Edit" || state.verb == "NotebookEdit" || state.verb == "Diff") &&
        state.snippet.any { ChatToolState.isDiffLine(displaySnippet(it)) || ChatToolState.isDiffLine(it) }
    val added = state.snippet.count { ChatToolState.isDiffLine(displaySnippet(it)) && displaySnippet(it).startsWith("+") }
    val removed = state.snippet.count { ChatToolState.isDiffLine(displaySnippet(it)) && displaySnippet(it).startsWith("-") }
    val snippetIsOutput = state.snippet.any { it.startsWith("|") }

    // Few-line edits open on their own; anything bigger stays a stat with
    // the full diff one tap away. Never overrules a hand toggle.
    // Detailed opens every finished output, and closes what it opened when
    // it is switched off.
    LaunchedEffect(state.snippet, state.running, expandsOutput) {
        if (snippetToggled || state.running) return@LaunchedEffect
        showSnippet = when {
            expandsOutput && state.snippet.isNotEmpty() -> true
            hasDiff && state.snippet.size <= 10 -> true
            else -> if (expandsOutput) showSnippet else false
        }
    }

    val tint = when {
        state.failed -> colors.danger
        state.running -> colors.accent
        state.verb == "Shell" || state.verb == "Bash" -> colors.warning
        else -> colors.accent
    }
    val border = when {
        state.failed -> colors.danger.copy(alpha = 0.45f)
        state.running -> colors.accent.copy(alpha = 0.45f)
        else -> colors.border
    }
    // One line shown while collapsed so a row is never just the verb. The
    // header already shows the target; this is the first output line
    // beneath it. Diffs skip this: their +/- stat lives in the header.
    val preview = if (!hasDiff) {
        state.snippet.firstNotNullOfOrNull { line ->
            val text = displaySnippet(line).trim()
            if (text.isNotEmpty() && text != "…") text.take(160) else null
        }
    } else {
        null
    }

    Column(
        Modifier
            .fillMaxWidth()
            .clip(RoundedCornerShape(cardRadius))
            .background(colors.panel)
            .border(1.dp, border, RoundedCornerShape(cardRadius))
            .padding(Space.s),
        verticalArrangement = Arrangement.spacedBy(Space.xs),
    ) {
        Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(Space.s)) {
            Box(Modifier.size(16.dp), contentAlignment = Alignment.Center) {
                if (state.running) {
                    CircularProgressIndicator(
                        modifier = Modifier.size(12.dp),
                        strokeWidth = 2.dp,
                        color = tint,
                    )
                } else {
                    Icon(toolGlyph(state.verb), null, tint = tint, modifier = Modifier.size(14.dp))
                }
            }
            Text(
                ChatSeat.word(state.verb, state.running),
                style = TextStyle(fontSize = 13.sp, fontWeight = FontWeight.Medium),
                color = tint,
                maxLines = 1,
                overflow = TextOverflow.Ellipsis,
            )
            if (state.target.isNotEmpty()) {
                Text(
                    state.target,
                    style = TsType.mono(11),
                    color = colors.textSecondary,
                    maxLines = 2,
                    overflow = TextOverflow.Ellipsis,
                    modifier = Modifier.weight(1f),
                )
            } else {
                Spacer(Modifier.weight(1f))
            }
            if (hasDiff && !state.running) {
                DiffStat(added = added.toLong(), removed = removed.toLong())
            }
            if (state.running && !ChatSeat.speaks(state.verb)) {
                Text(L10n.text("common.running"), style = TsType.mono(10), color = colors.accent, maxLines = 1)
            } else if (state.failed) {
                Text(L10n.text("common.failed"), style = TsType.mono(10), color = colors.danger, maxLines = 1)
            }
            if (!state.running) {
                val time = state.duration
                if (!time.isNullOrEmpty()) {
                    Text(time, style = TsType.mono(10), color = colors.textTertiary, maxLines = 1)
                }
            }
            if (state.snippet.isNotEmpty() && !state.running) {
                TsAccentButton(
                    label = if (showSnippet) {
                        if (hasDiff) L10n.text("android.transcriptrows.hide_edit.e9dbd4f5") else if (snippetIsOutput) L10n.text("android.transcriptrows.hide_output.64876c47") else L10n.text("android.transcriptrows.hide_edit.e9dbd4f5")
                    } else {
                        if (hasDiff) L10n.text("android.transcriptrows.show_edit.8da806e1") else if (snippetIsOutput) L10n.text("android.transcriptrows.show_output.9dbbb249") else L10n.text("android.transcriptrows.show_edit.8da806e1")
                    },
                    small = true,
                    onClick = {
                        snippetToggled = true
                        showSnippet = !showSnippet
                    },
                )
            }
        }
        if (!showSnippet && !state.running && preview != null) {
            Text(
                preview,
                style = TsType.mono(11),
                color = colors.textSecondary,
                maxLines = 1,
                overflow = TextOverflow.Ellipsis,
            )
        }
        if (showSnippet && state.snippet.isNotEmpty() && !state.running) {
            Column(
                Modifier
                    .fillMaxWidth()
                    .clip(RoundedCornerShape(6.dp))
                    .background(colors.background)
                    .padding(Space.s),
            ) {
                state.snippet.forEach { line ->
                    Text(
                        displaySnippet(line),
                        style = TsType.mono(11),
                        color = snippetColor(line, colors.textSecondary, colors.diffAdded, colors.diffRemoved),
                    )
                }
            }
        }
    }
}

private fun displaySnippet(line: String): String {
    if (line.startsWith("| ")) return line.drop(2)
    if (line == "| …") return "…"
    return line
}

@Composable
private fun snippetColor(
    line: String,
    secondary: androidx.compose.ui.graphics.Color,
    added: androidx.compose.ui.graphics.Color,
    removed: androidx.compose.ui.graphics.Color,
): androidx.compose.ui.graphics.Color {
    val shown = displaySnippet(line)
    if (ChatToolState.isDiffLine(shown)) {
        return if (shown.startsWith("+")) added else removed
    }
    return secondary
}

/// A side with nothing in it is left out, so a new file reads "+22"
/// rather than "+22 −0".
@Composable
private fun DiffStat(added: Long, removed: Long, style: TextStyle = TsType.mono(11, FontWeight.Medium)) {
    val colors = LocalTsColors.current
    Row(horizontalArrangement = Arrangement.spacedBy(4.dp)) {
        if (added > 0 || removed == 0L) Text("+$added", style = style, color = colors.diffAdded, maxLines = 1)
        if (removed > 0) Text("−$removed", style = style, color = colors.diffRemoved, maxLines = 1)
    }
}

/// What one step produced, below its open Compact line. The line above
/// already says what the step was, so there is no card, no second header
/// and no show button. Port of ChatStepDetail.swift.
@Composable
private fun PlainStepDetail(item: ChatDisplayItem) {
    val colors = LocalTsColors.current
    val subject: String
    val lines: List<Pair<String, androidx.compose.ui.graphics.Color>>
    val empty: String
    when (item) {
        is ChatDisplayItem.Tool -> {
            subject = item.state.target
            lines = item.state.snippet.map {
                displaySnippet(it) to snippetColor(it, colors.textSecondary, colors.diffAdded, colors.diffRemoved)
            }
            empty = if (item.state.running) L10n.text("common.running") else L10n.text("android.chatstepdetail.no_output")
        }
        is ChatDisplayItem.Edit -> {
            subject = item.state.path
            val all = if (item.state.patch.isEmpty()) emptyList() else item.state.patch.split("\n")
            lines = all.take(200).map { line ->
                line to when {
                    ChatToolState.isDiffLine(line) -> if (line.startsWith("+")) colors.diffAdded else colors.diffRemoved
                    else -> colors.textSecondary
                }
            } + listOfNotNull(
                (all.size - 200).takeIf { it > 0 }?.let {
                    L10n.text("android.transcriptrows.0_more_lines.c352841d", "$it") to colors.textTertiary
                },
            )
            empty = if (item.state.running) L10n.text("common.running") else L10n.text("android.chatstepdetail.no_diff")
        }
        else -> return
    }
    Column(
        Modifier
            .fillMaxWidth()
            .padding(horizontal = Space.s, vertical = 2.dp),
        verticalArrangement = Arrangement.spacedBy(1.dp),
    ) {
        if (subject.isNotEmpty()) {
            Text(subject, style = TsType.mono(11), color = colors.textTertiary, maxLines = 6, overflow = TextOverflow.Ellipsis)
        }
        if (lines.isEmpty()) {
            Text(empty, style = TsType.mono(11), color = colors.textTertiary)
        }
        lines.forEach { (text, color) -> Text(text, style = TsType.mono(11), color = color) }
    }
}

/// One step of a run under an open Compact line: the verb and what it
/// acted on, with its output a tap away and no card around either.
@Composable
private fun PlainStepRow(item: ChatDisplayItem) {
    val colors = LocalTsColors.current
    var open by remember(item.id) { mutableStateOf(false) }
    val (verb, subject, running) = when (item) {
        is ChatDisplayItem.Tool -> Triple(item.state.verb, item.state.target, item.state.running)
        is ChatDisplayItem.Edit -> Triple("Edit", item.state.path, item.state.running)
        else -> return
    }
    Column(Modifier.fillMaxWidth()) {
        Row(
            Modifier
                .fillMaxWidth()
                .heightIn(min = 36.dp)
                .clip(RoundedCornerShape(cardRadius))
                .clickable(
                    onClickLabel = if (open) L10n.text("android.chatdetail.hide_steps") else L10n.text("android.chatdetail.show_steps"),
                    onClick = { open = !open },
                )
                .padding(horizontal = Space.s, vertical = 3.dp),
            verticalAlignment = Alignment.CenterVertically,
            horizontalArrangement = Arrangement.spacedBy(6.dp),
        ) {
            Text(
                ChatSeat.word(verb, running),
                style = TextStyle(fontSize = 13.sp, fontWeight = FontWeight.Medium),
                color = if (running) colors.accent else colors.textSecondary,
                maxLines = 1,
            )
            Text(
                shortStepSubject(verb, subject),
                style = TextStyle(fontSize = 13.sp),
                color = colors.textTertiary,
                maxLines = 1,
                overflow = TextOverflow.Ellipsis,
                modifier = Modifier.weight(1f, fill = false),
            )
            if (item is ChatDisplayItem.Edit && (item.state.added > 0 || item.state.removed > 0)) {
                DiffStat(added = item.state.added, removed = item.state.removed, style = TextStyle(fontSize = 13.sp))
            }
            Spacer(Modifier.weight(1f))
        }
        if (open) PlainStepDetail(item)
    }
}

private fun toolGlyph(verb: String): ImageVector {
    return when (verb) {
        "Read" -> Icons.Default.Book
        "Write" -> Icons.Default.Edit
        "Edit", "NotebookEdit" -> Icons.Default.Edit
        "Diff" -> Icons.Default.Description
        "Shell", "Bash" -> Icons.Default.Terminal
        "Grep", "Search" -> Icons.Default.Search
        "Glob", "Find" -> Icons.Default.Folder
        "Task", "Subagent" -> Icons.Default.Person
        else -> Icons.Default.Build
    }
}

/// One file the agent changed, named after the file rather than after the
/// tool. Ported from ChatFileEditRow.swift.
@Composable
private fun TranscriptEditCard(state: ChatEditState, expandsOutput: Boolean = false) {
    val colors = LocalTsColors.current
    var expanded by remember { mutableStateOf(false) }
    var toggled by remember { mutableStateOf(false) }

    LaunchedEffect(state.patch, state.running, expandsOutput) {
        if (!toggled && !state.running && state.patch.isNotEmpty()) {
            val lines = state.patch.split("\n").size
            expanded = expandsOutput || lines in 1..10
        }
    }

    val tint = if (state.failed) colors.danger else colors.accent
    val bar = if (state.failed) colors.danger else colors.accent
    val border = when {
        state.failed -> colors.danger.copy(alpha = 0.45f)
        state.running -> colors.accent.copy(alpha = 0.45f)
        else -> colors.border
    }
    val meta = listOfNotNull(state.changeLabel, state.location.ifEmpty { null }).joinToString(" · ")

    Row(
        Modifier
            .fillMaxWidth()
            .height(IntrinsicSize.Min)
            .clip(RoundedCornerShape(cardRadius))
            .background(colors.panel)
            .border(1.dp, border, RoundedCornerShape(cardRadius))
            .padding(start = 8.dp, top = Space.s, end = Space.s, bottom = Space.s),
    ) {
        Box(
            Modifier
                .width(3.dp)
                .fillMaxHeight()
                .clip(RoundedCornerShape(2.dp))
                .background(bar),
        ) { }
        Spacer(Modifier.width(Space.s))
        Column(Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(Space.xs)) {
            Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(Space.s)) {
                Box(Modifier.size(16.dp), contentAlignment = Alignment.Center) {
                    if (state.running) {
                        CircularProgressIndicator(
                            modifier = Modifier.size(12.dp),
                            strokeWidth = 2.dp,
                            color = tint,
                        )
                    } else {
                        Icon(Icons.Default.Description, null, tint = tint, modifier = Modifier.size(14.dp))
                    }
                }
                Text(
                    state.fileName,
                    style = TextStyle(fontSize = 14.sp, fontWeight = FontWeight.SemiBold),
                    color = tint,
                    maxLines = 1,
                    overflow = TextOverflow.Ellipsis,
                    modifier = Modifier.weight(1f),
                )
                if ((state.added > 0 || state.removed > 0) && !state.running) {
                    DiffStat(added = state.added, removed = state.removed)
                }
                if (state.running) {
                    Text(ChatSeat.word(L10n.text("common.edit"), true), style = TextStyle(fontSize = 12.sp), color = colors.accent, maxLines = 1)
                } else if (state.failed) {
                    Text(L10n.text("common.failed"), style = TextStyle(fontSize = 12.sp), color = colors.danger, maxLines = 1)
                }
                if (!state.running) {
                    val time = state.duration
                    if (!time.isNullOrEmpty()) {
                        Text(time, style = TextStyle(fontSize = 12.sp), color = colors.textTertiary, maxLines = 1)
                    }
                }
                if (state.patch.isNotEmpty() && !state.running) {
                    TsAccentButton(
                        label = if (expanded) L10n.text("android.transcriptrows.hide_changes.c960be38") else L10n.text("android.transcriptrows.show_changes.b12a6ef8"),
                        small = true,
                        onClick = {
                            toggled = true
                            expanded = !expanded
                        },
                    )
                }
            }
            if (meta.isNotEmpty()) {
                Text(
                    meta,
                    style = TextStyle(fontSize = 12.sp),
                    color = colors.textSecondary,
                    maxLines = 1,
                    overflow = TextOverflow.Ellipsis,
                )
            }
            if (expanded && state.patch.isNotEmpty()) {
                val lines = state.patch.split("\n")
                val shown = lines.take(200)
                val cut = lines.size - shown.size
                Column(
                    Modifier
                        .fillMaxWidth()
                        .clip(RoundedCornerShape(6.dp))
                        .background(colors.background)
                        .padding(Space.s),
                ) {
                    shown.forEach { line ->
                        Text(
                            line,
                            style = TsType.mono(11),
                            color = if (ChatToolState.isDiffLine(line)) {
                                if (line.startsWith("+")) colors.diffAdded else colors.diffRemoved
                            } else {
                                colors.textSecondary
                            },
                        )
                    }
                }
                if (cut > 0) {
                    Text(
                        L10n.text("android.transcriptrows.0_more_lines.c352841d", "${cut}"),
                        style = TsType.mono(11),
                        color = colors.textSecondary,
                    )
                }
            }
        }
    }
}

@Composable
private fun AttachmentRow(
    item: ChatDisplayItem.Attachment,
    model: AppViewModel,
    peer: String,
    chatId: String,
    hostLabel: String,
) {
    val colors = LocalTsColors.current
    val scope = rememberCoroutineScope()
    var downloaded by remember(item.attachmentId) { mutableStateOf(false) }
    var busy by remember(item.attachmentId) { mutableStateOf(false) }
    var failure by remember(item.attachmentId) { mutableStateOf<String?>(null) }
    Card {
        Column(Modifier.padding(10.dp), verticalArrangement = Arrangement.spacedBy(Space.xs)) {
            Text(
                item.name,
                style = TextStyle(fontSize = 14.sp, fontWeight = FontWeight.Medium),
                color = colors.textPrimary,
                maxLines = 1,
                overflow = TextOverflow.Ellipsis,
            )
            val detail = listOfNotNull(
                item.mediaType,
                item.size?.let { L10n.text("android.transcriptrows.0_bytes.5ad0649b", "${it}") },
            ).joinToString(" · ")
            if (detail.isNotBlank()) {
                Text(detail, style = TextStyle(fontSize = 12.sp), color = colors.textSecondary)
            }
            if (failure != null) {
                Text(failure!!, style = TextStyle(fontSize = 12.sp), color = colors.danger)
            }
            if (downloaded) {
                Text(L10n.text("android.transcriptrows.downloaded.f0b0738f"), style = TextStyle(fontSize = 12.sp), color = colors.accent)
            } else {
                TsSecondaryButton(
                    label = if (busy) "…" else if (failure == null) L10n.text("android.transcriptrows.download.d6eafe82") else L10n.text("common.retry"),
                    small = true,
                    enabled = !busy && item.attachmentId.isNotBlank(),
                    onClick = {
                        busy = true
                        scope.launch {
                            runCatching {
                                model.workspaceSection(peer, "chat.attachment", buildJsonObject {
                                    put("id", chatId); put("attachmentId", item.attachmentId)
                                }) as? JsonObject
                            }.onSuccess {
                                downloaded = (it?.get("data")?.let { el ->
                                    (el as? kotlinx.serialization.json.JsonPrimitive)?.contentOrNull?.length
                                } ?: 0) > 0
                                failure = null
                            }.onFailure {
                                failure = TunnelCopy.display(it.message ?: L10n.text("android.transcriptrows.the_request_failed.db4fb447"), hostLabel)
                            }
                            busy = false
                        }
                    },
                )
            }
        }
    }
}

internal enum class MarkdownPresentation { Document, Chat, Aside }

/// Lightweight chat markdown: fences, headers, bullets, quotes, inline
/// code, bold, italic and links. Full Markwon would need View interop in
/// every lazy row; the transcript only ever uses this subset.
@Composable
internal fun MarkdownText(
    text: String,
    baseStyle: TextStyle,
    color: androidx.compose.ui.graphics.Color,
    modifier: Modifier = Modifier,
    presentation: MarkdownPresentation = MarkdownPresentation.Document,
) {
    val colors = LocalTsColors.current
    val blocks = remember(text) { parseMarkdown(text) }
    Column(modifier, verticalArrangement = Arrangement.spacedBy(6.dp)) {
        blocks.forEach { block ->
            when (block) {
                is MdBlock.Code -> {
                    Text(
                        block.code.trimEnd(),
                        style = TsType.mono(12),
                        color = color,
                        modifier = Modifier
                            .fillMaxWidth()
                            .clip(RoundedCornerShape(6.dp))
                            .background(colors.background)
                            .padding(Space.s),
                    )
                }
                is MdBlock.Header -> {
                    val headingStyle = when (presentation) {
                        MarkdownPresentation.Chat -> when (block.level) {
                            1 -> baseStyle.merge(TsType.chatHeading)
                            2 -> baseStyle.merge(TsType.chatSubheading)
                            else -> baseStyle.copy(fontWeight = FontWeight.SemiBold)
                        }
                        MarkdownPresentation.Aside -> baseStyle.copy(
                            fontWeight = if (block.level <= 2) FontWeight.Bold else FontWeight.SemiBold,
                        )
                        MarkdownPresentation.Document -> baseStyle.merge(TextStyle(
                            fontSize = when (block.level) { 1 -> 18.sp; 2 -> 16.sp; else -> 15.sp },
                            fontWeight = FontWeight.SemiBold,
                        ))
                    }
                    InlineMarkdown(
                        block.text,
                        headingStyle,
                        color,
                    )
                }
                is MdBlock.Bullet -> {
                    Row(horizontalArrangement = Arrangement.spacedBy(Space.s)) {
                        Text("•", style = baseStyle, color = color)
                        InlineMarkdown(block.text, baseStyle, color, Modifier.weight(1f))
                    }
                }
                is MdBlock.Numbered -> {
                    Row(horizontalArrangement = Arrangement.spacedBy(Space.s)) {
                        Text("${block.number}.", style = baseStyle, color = color)
                        InlineMarkdown(block.text, baseStyle, color, Modifier.weight(1f))
                    }
                }
                is MdBlock.Quote -> {
                    Row(
                        Modifier.height(IntrinsicSize.Min),
                        horizontalArrangement = Arrangement.spacedBy(Space.s),
                    ) {
                        Box(
                            Modifier
                                .width(3.dp)
                                .fillMaxHeight()
                                .clip(RoundedCornerShape(2.dp))
                                .background(colors.accent),
                        ) { }
                        InlineMarkdown(block.text, baseStyle, colors.textSecondary, Modifier.weight(1f))
                    }
                }
                is MdBlock.Rule -> {
                    HorizontalDivider(color = colors.border)
                }
                is MdBlock.Paragraph -> {
                    InlineMarkdown(block.text, baseStyle, color)
                }
            }
        }
    }
}

private sealed interface MdBlock {
    data class Code(val code: String) : MdBlock
    data class Header(val level: Int, val text: String) : MdBlock
    data class Bullet(val text: String) : MdBlock
    data class Numbered(val number: Int, val text: String) : MdBlock
    data class Quote(val text: String) : MdBlock
    data object Rule : MdBlock
    data class Paragraph(val text: String) : MdBlock
}

private fun parseMarkdown(text: String): List<MdBlock> {
    val blocks = mutableListOf<MdBlock>()
    val paragraph = StringBuilder()
    var fence: StringBuilder? = null
    var number = 0

    fun flushParagraph() {
        val body = paragraph.toString().trim()
        if (body.isNotEmpty()) {
            blocks.add(MdBlock.Paragraph(body))
            // A paragraph breaks a numbered list; an empty flush between
            // two numbered lines must not restart its counter.
            number = 0
        }
        paragraph.clear()
    }

    fun breakList() {
        number = 0
    }

    for (raw in text.split("\n")) {
        val line = raw.trimEnd()
        if (line.trimStart().startsWith("```")) {
            val open = fence
            if (open == null) {
                flushParagraph()
                breakList()
                fence = StringBuilder()
            } else {
                blocks.add(MdBlock.Code(open.toString()))
                fence = null
            }
            continue
        }
        val active = fence
        if (active != null) {
            active.append(raw).append("\n")
            continue
        }
        val stripped = line.trimStart()
        when {
            stripped.isEmpty() -> flushParagraph()
            stripped == "---" || stripped == "***" || stripped == "___" -> {
                flushParagraph()
                breakList()
                blocks.add(MdBlock.Rule)
            }
            stripped.startsWith("#") -> {
                val level = stripped.takeWhile { it == '#' }.length.coerceIn(1, 3)
                val title = stripped.drop(level).trim().ifEmpty { stripped }
                flushParagraph()
                breakList()
                blocks.add(MdBlock.Header(level, title))
            }
            stripped.startsWith("- ") || stripped.startsWith("* ") -> {
                flushParagraph()
                breakList()
                blocks.add(MdBlock.Bullet(stripped.drop(2)))
            }
            stripped.matches(Regex("\\d+[.)] .*")) -> {
                flushParagraph()
                number += 1
                blocks.add(MdBlock.Numbered(number, stripped.substringAfter(" ").substringAfter(". ")))
            }
            stripped.startsWith(">") -> {
                flushParagraph()
                breakList()
                blocks.add(MdBlock.Quote(stripped.drop(1).trim()))
            }
            stripped.startsWith("|") -> {
                // Tables are rare in chat; keep the pipes in mono so the
                // columns still line up instead of reflowing as prose.
                flushParagraph()
                breakList()
                blocks.add(MdBlock.Code(stripped))
            }
            else -> {
                if (paragraph.isNotEmpty()) paragraph.append("\n")
                paragraph.append(line.trim())
            }
        }
    }
    val open = fence
    if (open != null) {
        blocks.add(MdBlock.Code(open.toString()))
    } else {
        flushParagraph()
    }
    return blocks
}

@Composable
private fun InlineMarkdown(
    text: String,
    style: TextStyle,
    color: androidx.compose.ui.graphics.Color,
    modifier: Modifier = Modifier,
) {
    val colors = LocalTsColors.current
    val annotated = remember(text, color) {
        buildAnnotatedString {
            withStyle(style.toSpanStyle().copy(color = color)) {
                parseInline(text, colors.accent, colors.textSecondary)
            }
        }
    }
    // Links ride as LinkAnnotations, which Text opens itself.
    Text(annotated, style = style, modifier = modifier)
}

private fun AnnotatedString.Builder.parseInline(
    text: String,
    accent: androidx.compose.ui.graphics.Color,
    secondary: androidx.compose.ui.graphics.Color,
) {
    var i = 0
    fun codeStyle() = SpanStyle(fontFamily = TsType.mono(12).fontFamily, color = secondary)
    while (i < text.length) {
        when {
            text.startsWith("**", i) -> {
                val end = text.indexOf("**", i + 2)
                if (end < 0) {
                    append(text.drop(i))
                    return
                }
                // Parsed again inside, not appended raw: a link inside bold
                // is a bold link, not the letters `[text](url)`.
                withStyle(SpanStyle(fontWeight = FontWeight.Bold)) {
                    parseInline(text.substring(i + 2, end), accent, secondary)
                }
                i = end + 2
            }
            text.startsWith("`", i) -> {
                val end = text.indexOf("`", i + 1)
                if (end < 0) {
                    append(text.drop(i))
                    return
                }
                withStyle(codeStyle()) { append(text.substring(i + 1, end)) }
                i = end + 1
            }
            text.startsWith("[", i) -> {
                val mid = text.indexOf("](", i + 1)
                val end = if (mid >= 0) text.indexOf(")", mid + 2) else -1
                if (mid < 0 || end < 0) {
                    append(text[i])
                    i += 1
                } else {
                    withLink(LinkAnnotation.Url(text.substring(mid + 2, end))) {
                        withStyle(SpanStyle(color = accent)) { append(text.substring(i + 1, mid)) }
                    }
                    i = end + 1
                }
            }
            text[i] == '*' || text[i] == '_' -> {
                val mark = text[i]
                // An underscore inside a word is snake_case, not emphasis.
                // An asterisk opens anywhere, like CommonMark.
                val opens = mark == '*' || i == 0 || !text[i - 1].isLetterOrDigit()
                val end = if (opens) text.indexOf(mark, i + 1) else -1
                if (end < 0 || end == i + 1) {
                    append(mark)
                    i += 1
                } else {
                    withStyle(SpanStyle(fontStyle = FontStyle.Italic)) {
                        parseInline(text.substring(i + 1, end), accent, secondary)
                    }
                    i = end + 1
                }
            }
            else -> {
                append(text[i])
                i += 1
            }
        }
    }
}

/// One line standing in for folded steps. Port of ChatStepGroupRow.swift:
/// the whole line is the control, and tapping it shows or hides the steps.
@Composable
private fun StepGroupRow(group: ChatStepGroup, onClick: () -> Unit) {
    val colors = LocalTsColors.current
    val title = when (group.style) {
        ChatStepGroup.Style.Work -> when {
            group.running && group.liveVerb != null -> ChatSeat.phrase(group.liveVerb, group.liveTarget)
            group.running -> L10n.text("common.working")
            else -> stepGroupDuration(group)?.let { L10n.text("android.chatdetail.worked_for", it) }
                ?: L10n.text("android.chatdetail.worked")
        }
        ChatStepGroup.Style.Explored ->
            if (group.running) L10n.text("android.chatdetail.exploring") else L10n.text("android.chatdetail.explored")
        ChatStepGroup.Style.Thought -> L10n.text("android.chatdetail.thought")
        ChatStepGroup.Style.Step -> ChatSeat.word(group.verb, group.running)
    }
    val summary = stepGroupSummary(group)
    val glyph = when (group.style) {
        ChatStepGroup.Style.Work -> Icons.AutoMirrored.Filled.List
        ChatStepGroup.Style.Explored -> Icons.Default.Search
        ChatStepGroup.Style.Thought -> Icons.Default.Lightbulb
        ChatStepGroup.Style.Step -> Icons.AutoMirrored.Filled.KeyboardArrowRight
    }
    val tint = if (group.running) colors.accent else colors.textSecondary
    Row(
        Modifier
            .fillMaxWidth()
            .heightIn(min = 44.dp)
            .clip(RoundedCornerShape(cardRadius))
            .clickable(
                onClickLabel = if (group.open) L10n.text("android.chatdetail.hide_steps") else L10n.text("android.chatdetail.show_steps"),
                onClick = onClick,
            )
            .padding(horizontal = Space.s, vertical = 6.dp),
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(Space.s),
    ) {
        Icon(
            Icons.AutoMirrored.Filled.KeyboardArrowRight,
            null,
            tint = colors.textSecondary,
            modifier = Modifier.size(16.dp).rotate(if (group.open) 90f else 0f),
        )
        Box(Modifier.size(16.dp), contentAlignment = Alignment.Center) {
            if (group.running) {
                CircularProgressIndicator(modifier = Modifier.size(12.dp), strokeWidth = 2.dp, color = tint)
            } else {
                Icon(glyph, null, tint = tint, modifier = Modifier.size(14.dp))
            }
        }
        Text(
            title,
            style = TextStyle(fontSize = 13.sp, fontWeight = FontWeight.Medium),
            color = if (group.running) colors.accent else colors.textPrimary,
            maxLines = 1,
            overflow = TextOverflow.Ellipsis,
        )
        Text(
            summary.orEmpty(),
            style = TsType.mono(11),
            color = colors.textSecondary,
            maxLines = 1,
            overflow = TextOverflow.Ellipsis,
            modifier = Modifier.weight(1f),
        )
        if (group.added > 0 || group.removed > 0) {
            DiffStat(added = group.added, removed = group.removed)
        }
        val cost = group.cost
        if (cost != null && cost > 0) {
            Text("$" + "%.2f".format(cost), style = TsType.mono(11), color = colors.accent, maxLines = 1)
        }
    }
}

/// The counts after the title: steps and files for work, what was looked at
/// for a run of reads, the first line for a thought.
private fun stepGroupSummary(group: ChatStepGroup): String? = when (group.style) {
    ChatStepGroup.Style.Work -> buildList {
        add(if (group.steps == 1) L10n.text("android.chatdetail.steps.one", "1") else L10n.text("android.chatdetail.steps.other", "${group.steps}"))
        if (group.files > 0) add(if (group.files == 1) L10n.text("android.chatdetail.files_edited.one", "1") else L10n.text("android.chatdetail.files_edited.other", "${group.files}"))
    }.joinToString(" · ")
    ChatStepGroup.Style.Explored -> buildList {
        if (group.reads > 0) add(if (group.reads == 1) L10n.text("android.chatdetail.files.one", "1") else L10n.text("android.chatdetail.files.other", "${group.reads}"))
        if (group.searches > 0) add(if (group.searches == 1) L10n.text("android.chatdetail.searches.one", "1") else L10n.text("android.chatdetail.searches.other", "${group.searches}"))
        if (group.pages > 0) add(if (group.pages == 1) L10n.text("android.chatdetail.pages.one", "1") else L10n.text("android.chatdetail.pages.other", "${group.pages}"))
    }.joinToString(", ")
    ChatStepGroup.Style.Thought -> group.preview
    ChatStepGroup.Style.Step -> group.subject?.let { shortStepSubject(group.verb, it) }
}

/// A path becomes its file name. A command keeps its first line.
internal fun shortStepSubject(verb: String?, subject: String): String {
    val line = subject.lineSequence().firstOrNull()?.trim() ?: subject.trim()
    return when (verb) {
        "Read", "Edit", "NotebookEdit", "Write", "Diff" -> line.substringAfterLast('/').ifEmpty { line }
        else -> line.take(160)
    }
}

/// Compact: the verb, what it acted on and the lines it changed, in one
/// quiet line. Port of ChatStepGroupRow.swift `plainLine`.
@Composable
private fun PlainStepLine(group: ChatStepGroup, onClick: () -> Unit) {
    val colors = LocalTsColors.current
    val title = when (group.style) {
        ChatStepGroup.Style.Step -> ChatSeat.word(group.verb, group.running)
        ChatStepGroup.Style.Explored ->
            if (group.running) L10n.text("android.chatdetail.exploring") else L10n.text("android.chatdetail.explored")
        ChatStepGroup.Style.Thought -> L10n.text("android.chatdetail.thought")
        ChatStepGroup.Style.Work -> L10n.text("android.chatdetail.worked")
    }
    val subject = when {
        group.style == ChatStepGroup.Style.Thought -> group.preview
        group.memberIds.size == 1 && group.subject != null -> shortStepSubject(group.verb, group.subject)
        else -> stepGroupSummary(group)
    }
    Row(
        Modifier
            .fillMaxWidth()
            .heightIn(min = 36.dp)
            .clip(RoundedCornerShape(cardRadius))
            .clickable(
                onClickLabel = if (group.open) L10n.text("android.chatdetail.hide_steps") else L10n.text("android.chatdetail.show_steps"),
                onClick = onClick,
            )
            .padding(horizontal = Space.s, vertical = 3.dp),
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(6.dp),
    ) {
        if (group.running) {
            CircularProgressIndicator(modifier = Modifier.size(12.dp), strokeWidth = 2.dp, color = colors.accent)
        }
        Text(
            title,
            style = TextStyle(fontSize = 13.sp, fontWeight = FontWeight.Medium),
            color = if (group.running) colors.accent else colors.textSecondary,
            maxLines = 1,
        )
        Text(
            subject.orEmpty(),
            style = TextStyle(fontSize = 13.sp),
            color = colors.textTertiary,
            maxLines = 1,
            overflow = TextOverflow.Ellipsis,
            modifier = Modifier.weight(1f, fill = false),
        )
        if (group.added > 0 || group.removed > 0) {
            DiffStat(added = group.added, removed = group.removed, style = TextStyle(fontSize = 13.sp))
        }
        Spacer(Modifier.weight(1f))
    }
}

/// The files a finished turn changed, under its last reply. Port of
/// ChatTurnChangesCard.swift: the first four files, the rest one tap away,
/// and Review opens the folder's changes.
@Composable
private fun TurnChangesCard(changes: ChatDisplayItem.Changes, onReview: (() -> Unit)?) {
    val colors = LocalTsColors.current
    var showingAll by remember(changes.id) { mutableStateOf(false) }
    val shown = if (showingAll) changes.files else changes.files.take(4)
    Column(
        Modifier
            .fillMaxWidth()
            .clip(RoundedCornerShape(cardRadius))
            .background(colors.panel)
            .border(1.dp, colors.border, RoundedCornerShape(cardRadius))
            .padding(Space.m),
        verticalArrangement = Arrangement.spacedBy(2.dp),
    ) {
        Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(Space.s)) {
            Text(
                if (changes.files.size == 1) L10n.text("android.chatchanges.files_changed.one", "1")
                else L10n.text("android.chatchanges.files_changed.other", "${changes.files.size}"),
                style = TextStyle(fontSize = 13.sp, fontWeight = FontWeight.Medium),
                color = colors.textPrimary,
            )
            DiffStat(added = changes.added, removed = changes.removed)
            Spacer(Modifier.weight(1f))
            if (onReview != null) {
                TsSecondaryButton(
                    label = L10n.text("android.chatchanges.review"),
                    icon = ActionIcon.Preview.vector,
                    small = true,
                    onClick = onReview,
                )
            }
        }
        shown.forEach { file ->
            Row(
                Modifier
                    .fillMaxWidth()
                    .heightIn(min = 36.dp)
                    .clip(RoundedCornerShape(6.dp))
                    .clickable(enabled = onReview != null) { onReview?.invoke() }
                    .padding(vertical = 3.dp),
                verticalAlignment = Alignment.CenterVertically,
                horizontalArrangement = Arrangement.spacedBy(Space.s),
            ) {
                Text(
                    file.fileName,
                    style = TextStyle(fontSize = 13.sp),
                    color = colors.textPrimary,
                    maxLines = 1,
                    overflow = TextOverflow.Ellipsis,
                    modifier = Modifier.weight(1f),
                )
                DiffStat(added = file.added, removed = file.removed)
            }
        }
        if (changes.files.size > 4) {
            Text(
                if (showingAll) L10n.text("android.chatchanges.show_less")
                else L10n.text("android.chatchanges.show_more", "${changes.files.size - 4}"),
                style = TextStyle(fontSize = 13.sp),
                color = colors.textSecondary,
                modifier = Modifier
                    .clip(RoundedCornerShape(6.dp))
                    .clickable { showingAll = !showingAll }
                    .padding(vertical = 4.dp),
            )
        }
    }
}

/// "10s", "3m", "1h 5m", floored, the way the Apple client's turn timer reads.
private fun stepGroupDuration(group: ChatStepGroup): String? {
    val start = group.startedAtMs ?: return null
    val end = group.endedAtMs ?: return null
    if (group.running || end <= start) return null
    val seconds = (end - start) / 1000
    if (seconds < 60) return L10n.text("android.chatdetail.duration_s", "$seconds")
    val minutes = seconds / 60
    if (minutes < 60) return L10n.text("android.chatdetail.duration_m", "$minutes")
    val rest = minutes % 60
    return if (rest == 0L) L10n.text("android.chatdetail.duration_h", "${minutes / 60}")
    else L10n.text("android.chatdetail.duration_h_m", "${minutes / 60}", "$rest")
}
