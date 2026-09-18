// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
package ai.tokenstat.tokenstat.ui.workspace

import ai.tokenstat.tokenstat.AppViewModel
import ai.tokenstat.tokenstat.ui.components.ActionIcon
import ai.tokenstat.tokenstat.ui.components.TsAccentButton
import ai.tokenstat.tokenstat.ui.components.TsSecondaryButton
import ai.tokenstat.tokenstat.ui.components.TsType
import ai.tokenstat.tokenstat.ui.logic.TunnelCopy
import ai.tokenstat.tokenstat.ui.logic.harnessName
import ai.tokenstat.tokenstat.ui.theme.LocalTsColors
import ai.tokenstat.tokenstat.ui.theme.Space
import ai.tokenstat.tokenstat.ui.theme.cardRadius
import androidx.compose.foundation.background
import androidx.compose.foundation.border
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
) {
    val scope = rememberCoroutineScope()
    when (item) {
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
                    "${harnessName(item.backend)} · new turn",
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
                modifier = Modifier.fillMaxWidth(),
            )
        }
        is ChatDisplayItem.Tool -> TranscriptToolRow(state = item.state)
        is ChatDisplayItem.Edit -> TranscriptEditCard(state = item.state)
        is ChatDisplayItem.Attachment -> AttachmentRow(
            item = item,
            model = model,
            peer = peer,
            chatId = chatId,
            hostLabel = hostLabel,
        )
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
                    "${item.input} in · ${item.output} out",
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
                    "Copy response",
                    tint = colors.textSecondary,
                    modifier = Modifier.size(16.dp),
                )
            }
        }
        MarkdownText(
            text = text,
            baseStyle = TsType.chatBody,
            color = colors.textPrimary,
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

/// A tool call on a transcript: verb, target, optional snippet, and how it
/// ended. Ported from Design/ToolRow.swift.
@Composable
private fun TranscriptToolRow(state: ChatToolState) {
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
    LaunchedEffect(state.snippet, state.running) {
        if (!snippetToggled && hasDiff && !state.running && state.snippet.size <= 10) {
            showSnippet = true
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
                state.verb,
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
                    overflow = TextOverflow.MiddleEllipsis,
                    modifier = Modifier.weight(1f),
                )
            } else {
                Spacer(Modifier.weight(1f))
            }
            if (hasDiff && !state.running) {
                DiffStat(added = added, removed = removed)
            }
            if (state.running) {
                Text("Running", style = TsType.mono(10), color = colors.accent, maxLines = 1)
            } else {
                val time = state.duration
                if (!time.isNullOrEmpty()) {
                    Text(time, style = TsType.mono(10), color = colors.textTertiary, maxLines = 1)
                }
            }
            if (state.snippet.isNotEmpty() && !state.running) {
                TsAccentButton(
                    label = if (showSnippet) {
                        if (hasDiff) "Hide edit" else if (snippetIsOutput) "Hide output" else "Hide edit"
                    } else {
                        if (hasDiff) "Show edit" else if (snippetIsOutput) "Show output" else "Show edit"
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

@Composable
private fun DiffStat(added: Int, removed: Int) {
    val colors = LocalTsColors.current
    Row(horizontalArrangement = Arrangement.spacedBy(4.dp)) {
        Text("+$added", style = TsType.mono(11, FontWeight.Medium), color = colors.diffAdded, maxLines = 1)
        Text("−$removed", style = TsType.mono(11, FontWeight.Medium), color = colors.diffRemoved, maxLines = 1)
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
private fun TranscriptEditCard(state: ChatEditState) {
    val colors = LocalTsColors.current
    var expanded by remember { mutableStateOf(false) }
    var toggled by remember { mutableStateOf(false) }

    LaunchedEffect(state.patch, state.running) {
        if (!toggled && !state.running && state.patch.isNotEmpty()) {
            val lines = state.patch.split("\n").size
            if (lines in 1..10) expanded = true
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
                    overflow = TextOverflow.MiddleEllipsis,
                    modifier = Modifier.weight(1f),
                )
                if (state.added + state.removed > 0 && !state.running) {
                    DiffStat(added = state.added, removed = state.removed)
                }
                if (state.running) {
                    Text("Writing", style = TextStyle(fontSize = 12.sp), color = colors.accent, maxLines = 1)
                } else {
                    val time = state.duration
                    if (!time.isNullOrEmpty()) {
                        Text(time, style = TextStyle(fontSize = 12.sp), color = colors.textTertiary, maxLines = 1)
                    }
                }
                if (state.patch.isNotEmpty() && !state.running) {
                    TsAccentButton(
                        label = if (expanded) "Hide changes" else "Show changes",
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
                    overflow = TextOverflow.MiddleEllipsis,
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
                        "… $cut more lines",
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
                item.size?.let { "$it bytes" },
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
                                failure = TunnelCopy.display(it.message ?: "The request failed.", hostLabel)
                            }
                            busy = false
                        }
                    },
                )
            }
        }
    }
}

/// Lightweight chat markdown: fences, headers, bullets, quotes, inline
/// code, bold, italic and links. Full Markwon would need View interop in
/// every lazy row; the transcript only ever uses this subset.
@Composable
internal fun MarkdownText(
    text: String,
    baseStyle: TextStyle,
    color: androidx.compose.ui.graphics.Color,
    modifier: Modifier = Modifier,
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
                    val size = when (block.level) {
                        1 -> 18.sp
                        2 -> 16.sp
                        else -> 15.sp
                    }
                    InlineMarkdown(
                        block.text,
                        baseStyle.merge(TextStyle(fontSize = size, fontWeight = FontWeight.SemiBold)),
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
                withStyle(SpanStyle(fontWeight = FontWeight.Bold)) {
                    append(text.substring(i + 2, end))
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
                        append(text.substring(i + 1, end))
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

