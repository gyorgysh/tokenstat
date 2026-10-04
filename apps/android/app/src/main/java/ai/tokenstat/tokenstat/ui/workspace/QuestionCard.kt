// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
package ai.tokenstat.tokenstat.ui.workspace

import ai.tokenstat.tokenstat.ui.components.ActionIcon
import ai.tokenstat.tokenstat.ui.components.TsAccentButton
import ai.tokenstat.tokenstat.ui.components.TsSecondaryButton
import ai.tokenstat.tokenstat.ui.localization.L10n
import ai.tokenstat.tokenstat.ui.theme.LocalTsColors
import ai.tokenstat.tokenstat.ui.theme.Space
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.ExperimentalLayoutApi
import androidx.compose.foundation.layout.FlowRow
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.KeyboardActions
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateListOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.text.TextStyle
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.input.ImeAction
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp

/// A question the agent asked, drawn where it asked it. Port of
/// ChatQuestionCard.swift: choices answer in one tap, a multiple-choice
/// question collects its picks first, and the field takes an answer of the
/// person's own. Once answered it says what was sent and offers nothing more.
@OptIn(ExperimentalLayoutApi::class)
@Composable
internal fun QuestionCard(question: ChatQuestion, sending: Boolean, error: String?, canAnswer: Boolean = true, onAnswer: (String) -> Unit) {
    val colors = LocalTsColors.current
    var written by remember(question.id) { mutableStateOf("") }
    val picked = remember(question.id) { mutableStateListOf<String>() }
    fun sendWritten() {
        val text = written.trim()
        if (text.isNotEmpty() && !sending) {
            onAnswer(text)
        }
    }
    Column(
        Modifier
            .fillMaxWidth()
            .clip(RoundedCornerShape(14.dp))
            .background(colors.accentSoft.copy(alpha = 0.5f))
            .border(1.dp, colors.accent.copy(alpha = if (question.answer != null) 0.2f else 0.45f), RoundedCornerShape(14.dp))
            .padding(Space.m),
        verticalArrangement = Arrangement.spacedBy(Space.s),
    ) {
        Text(L10n.text("android.chatquestion.title"), style = TextStyle(fontSize = 12.sp, fontWeight = FontWeight.Medium), color = colors.accent)
        Text(question.question, style = TextStyle(fontSize = 14.sp, fontWeight = FontWeight.SemiBold), color = colors.textPrimary)
        val answer = question.answer
        if (answer != null) {
            Text(L10n.text("android.chatquestion.answered", answer), style = TextStyle(fontSize = 12.sp), color = colors.textPrimary)
            when (question.delivery) {
                "note" -> L10n.text("android.chatquestion.delivery_note")
                "queued" -> L10n.text("android.chatquestion.delivery_queued")
                "sent" -> L10n.text("android.chatquestion.delivery_sent")
                else -> null
            }?.let { Text(it, style = TextStyle(fontSize = 12.sp), color = colors.textSecondary) }
            return@Column
        }
        val fallback = question.defaultAnswer
        Text(
            if (!question.blocking && fallback != null) L10n.text("android.chatquestion.going_with", fallback)
            else L10n.text("android.chatquestion.waiting"),
            style = TextStyle(fontSize = 12.sp),
            color = colors.textSecondary,
        )
        if (!canAnswer) return@Column
        if (question.options.isNotEmpty()) {
            FlowRow(horizontalArrangement = Arrangement.spacedBy(Space.s), verticalArrangement = Arrangement.spacedBy(Space.s)) {
                question.options.forEach { option ->
                    val selected = option in picked
                    Text(
                        option,
                        style = TextStyle(fontSize = 13.sp, fontWeight = FontWeight.Medium),
                        color = if (selected) colors.background else colors.accent,
                        modifier = Modifier
                            .heightIn(min = 40.dp)
                            .clip(RoundedCornerShape(50))
                            .background(if (selected) colors.accent else colors.panel)
                            .border(1.dp, colors.accent.copy(alpha = 0.5f), RoundedCornerShape(50))
                            .clickable(enabled = !sending, role = Role.Button) {
                                if (question.multiple) {
                                    if (selected) picked.remove(option) else picked.add(option)
                                } else {
                                    onAnswer(option)
                                }
                            }
                            .padding(horizontal = 14.dp, vertical = 10.dp),
                    )
                }
            }
            if (question.multiple) {
                TsAccentButton(
                    label = L10n.text("android.chatquestion.send_choices"),
                    icon = ActionIcon.Send.vector,
                    small = true,
                    enabled = picked.isNotEmpty() && !sending,
                    // Quoted, so a comma inside a choice cannot read as two.
                    onClick = { onAnswer(picked.joinToString(", ") { "“$it”" }) },
                )
            }
        }
        Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(Space.s)) {
            OutlinedTextField(
                written,
                { written = it },
                label = { Text(L10n.text("android.chatquestion.own_answer")) },
                enabled = !sending,
                singleLine = true,
                keyboardOptions = KeyboardOptions(imeAction = ImeAction.Send),
                keyboardActions = KeyboardActions(onSend = { sendWritten() }),
                modifier = Modifier.weight(1f),
            )
            TsSecondaryButton(
                label = L10n.text("android.chatquestion.send"),
                icon = ActionIcon.Send.vector,
                small = true,
                enabled = written.isNotBlank() && !sending,
                onClick = { sendWritten() },
            )
        }
        error?.let { Text(it, style = TextStyle(fontSize = 12.sp), color = colors.danger) }
    }
}
