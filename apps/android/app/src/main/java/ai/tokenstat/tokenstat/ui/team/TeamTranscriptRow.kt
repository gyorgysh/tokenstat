// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
package ai.tokenstat.tokenstat.ui.team

import ai.tokenstat.tokenstat.ui.components.*
import ai.tokenstat.tokenstat.ui.localization.L10n
import ai.tokenstat.tokenstat.ui.theme.LocalTsColors
import ai.tokenstat.tokenstat.ui.workspace.MarkdownText
import ai.tokenstat.tokenstat.ui.marks.Avatar
import androidx.compose.ui.Alignment
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.text.selection.SelectionContainer
import androidx.compose.material3.Text
import androidx.compose.runtime.*
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.ClipEntry
import androidx.compose.ui.platform.LocalClipboard
import androidx.compose.ui.semantics.clearAndSetSemantics
import androidx.compose.ui.unit.dp
import kotlinx.coroutines.launch
import kotlinx.serialization.json.JsonObject

internal fun teamBackend(backend: String): String = when (backend) {
    "claude" -> "Claude Code"; "codex" -> "Codex"; "muse" -> "Muse"
    "" -> L10n.text("common.teams.agent"); else -> backend
}
internal fun teamAuthorLabel(author: TeamAuthor): String = when (author.kind) {
    "localBeforeTeams" -> L10n.text("common.teams.local_before_teams")
    "formerMember" -> L10n.text("common.teams.former_member")
    "comment" -> author.name + " · " + L10n.text("common.teams.comment")
    "ask" -> author.name + " · " + L10n.text("common.teams.ask")
    else -> when {
        author.formerInitiator -> L10n.text("common.teams.agent_asked_by", teamBackend(author.backend), L10n.text("common.teams.former_member"))
        author.name.isNotEmpty() -> L10n.text("common.teams.agent_asked_by", teamBackend(author.backend), author.name)
        else -> teamBackend(author.backend)
    }
}

@Composable internal fun TeamTranscriptRow(block: TeamBlock, fetch: suspend (String) -> JsonObject) {
    val colors = LocalTsColors.current
    var expanded by remember(block.id) { mutableStateOf(false) }
    Column(Modifier.fillMaxWidth().padding(vertical = 4.dp), verticalArrangement = Arrangement.spacedBy(6.dp)) {
        block.author?.let { author ->
            Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                if (author.name.isNotBlank() && !author.formerInitiator) Box(Modifier.clearAndSetSemantics {}) { Avatar(name = author.name, size = 24, decorative = true) }
                Text(teamAuthorLabel(author), style = TsType.caption, color = colors.textSecondary)
            }
        }
        when (block.kind) {
            TeamBlockKind.File -> block.file?.let { SharedFile(it, fetch) }
            TeamBlockKind.User -> TeamLiteralText(block.text)
            TeamBlockKind.Text -> {
                val bytes = remember(block.text) { block.text.toByteArray().size }
                val chart = block.text.trim().startsWith("```tokenstat-chart\n") && block.text.trimEnd().endsWith("```")
                if (bytes <= 64 * 1024 || chart && bytes <= 256 * 1024 + 128) SelectionContainer { MarkdownText(block.text, TsType.chatBody, colors.textPrimary) }
                else TeamLiteralText(block.text)
            }
            TeamBlockKind.Thinking, TeamBlockKind.Tool, TeamBlockKind.Edit -> {
                val title = when (block.kind) {
                    TeamBlockKind.Thinking -> L10n.text("common.teams.thinking")
                    TeamBlockKind.Edit -> L10n.text("common.teams.recorded_changes") + " · " + block.title
                    else -> L10n.text("common.teams.tool_output") + block.title.takeIf { it.isNotEmpty() }?.let { " · $it" }.orEmpty()
                }
                val clipped = teamTextPages(title, 160).first() + if (title.length > 160) "…" else ""
                TsSecondaryButton(clipped, icon = ActionIcon.Preview.vector, onClick = { expanded = !expanded })
                block.ok?.let { Text(if (it) L10n.text("common.teams.tool_succeeded") else L10n.text("common.teams.tool_failed"), color = if (it) colors.textSecondary else colors.danger) }
                if (expanded) { Text(title, color = colors.textSecondary); TeamLiteralText(block.text, code = true) }
            }
            TeamBlockKind.Error -> { Text(L10n.text("common.teams.run_failed"), color = colors.danger); TeamLiteralText(block.text) }
            TeamBlockKind.Notice -> { Text(teamNotice(block.title), color = colors.textSecondary); if (block.text.isNotEmpty()) TeamLiteralText(block.text) }
        }
    }
}
@Composable private fun TeamLiteralText(text: String, code: Boolean = false) {
    val colors = LocalTsColors.current; val scope = rememberCoroutineScope(); val clipboard = LocalClipboard.current
    val pages = remember(text) { teamTextPages(text) }
    var index by remember(text) { mutableIntStateOf(0) }
    SelectionContainer { Text(pages[index], style = if (code) TsType.mono(12) else TsType.chatBody, color = colors.textPrimary) }
    if (pages.size > 1) {
        Text(L10n.text("common.teams.text_page", (index + 1).toString(), pages.size.toString()), color = colors.textSecondary)
        FlowRow(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
            TsSecondaryButton(L10n.text("common.teams.previous_page"), enabled = index > 0, icon = ActionIcon.Back.vector, onClick = { index-- })
            TsSecondaryButton(L10n.text("common.next"), enabled = index + 1 < pages.size, icon = ActionIcon.Next.vector, onClick = { index++ })
            TsSecondaryButton(L10n.text("common.copy"), icon = ActionIcon.Copy.vector, onClick = { scope.launch {
                clipboard.setClipEntry(ClipEntry(android.content.ClipData.newPlainText("", text)))
            } })
        }
    }
}
private fun teamNotice(key: String): String = when (key) {
    "run_finished" -> L10n.text("common.teams.run_finished")
    "run_failed" -> L10n.text("common.teams.run_failed")
    "recorded_question" -> L10n.text("common.teams.recorded_question")
    "recorded_message" -> L10n.text("common.teams.recorded_message")
    "recorded_handoff" -> L10n.text("common.teams.recorded_handoff")
    "recorded_approval" -> L10n.text("common.teams.recorded_approval")
    "answer_withdrawn" -> L10n.text("common.teams.answer_withdrawn")
    else -> L10n.text("common.teams.event_unavailable")
}
