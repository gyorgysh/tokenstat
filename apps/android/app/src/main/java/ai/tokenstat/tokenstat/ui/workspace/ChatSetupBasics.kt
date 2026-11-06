// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
package ai.tokenstat.tokenstat.ui.workspace

import ai.tokenstat.tokenstat.ui.components.*
import ai.tokenstat.tokenstat.ui.localization.L10n
import ai.tokenstat.tokenstat.ui.logic.LaunchDefaults
import ai.tokenstat.tokenstat.ui.theme.*
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.*
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.unit.dp
import androidx.compose.ui.window.Dialog
import androidx.compose.ui.window.DialogProperties
import kotlinx.serialization.json.JsonObject

@Composable
internal fun ChatSetupSheetFrame(onDismiss: () -> Unit, content: @Composable ColumnScope.() -> Unit) {
    val colors = LocalTsColors.current
    Dialog(onDismissRequest = onDismiss, properties = DialogProperties(usePlatformDefaultWidth = false)) {
        Surface(shape = RoundedCornerShape(20.dp), color = colors.background, tonalElevation = 0.dp,
            modifier = Modifier.fillMaxWidth(.94f).fillMaxHeight(.9f)) {
            Column {
                Row(Modifier.fillMaxWidth().padding(Space.m), verticalAlignment = Alignment.CenterVertically) {
                    Text(L10n.text("android.chatpullssections.chat_setup.9fa79d00"),
                        style = TsType.headline, color = colors.textPrimary, modifier = Modifier.weight(1f))
                    TsSecondaryButton(label = L10n.text("common.done"), icon = ActionIcon.Done.vector, small = true, onClick = onDismiss)
                }
                HorizontalDivider(color = colors.border)
                Column(Modifier.weight(1f).verticalScroll(rememberScrollState()).padding(Space.m),
                    verticalArrangement = Arrangement.spacedBy(Space.m), content = content)
            }
        }
    }
}

@Composable
internal fun ChatSetupBasics(chat: JsonObject?, backends: List<JsonObject>, locked: Boolean,
                             onAgent: () -> Unit, onChange: (String, String) -> Unit) {
    val colors = LocalTsColors.current
    val hasAgent = !chat?.str("backend").isNullOrBlank()
    val mode = chat?.str("mode")?.ifBlank { null } ?: LaunchDefaults.MODE
    val bypassOnly = chatAgentForcesBypass(backends, chat?.str("backend").orEmpty())
    val bypass = bypassOnly || chat?.str("autonomy") == "bypass"
    Text(L10n.text("common.chat.setup.intro"), style = TsType.callout, color = colors.textSecondary)
    if (locked && chat?.bol("running") == true) {
        Text(L10n.text("common.chat.setup.busy"), style = TsType.caption, color = colors.warning)
    } else if (!hasAgent) {
        Text(L10n.text("common.chat.setup.needs_agent"), style = TsType.caption, color = colors.textSecondary)
    }
    ChatSetupBlock(L10n.text("common.chat.setup.agent"), L10n.text("common.chat.setup.agent_help")) {
        TsPickerField(chatAgentSummary(backends, chat), onAgent, enabled = !locked, modifier = Modifier.fillMaxWidth())
    }
    ChatSetupBlock(L10n.text("common.chat_working_style"), L10n.text(if (mode == "plan") "common.chat.setup.plan_help" else "common.chat.setup.execute_help")) {
        ChatSegmented(listOf("plan" to L10n.text("android.chatpullssections.plan.fa8ed0bd"), "execute" to L10n.text("android.chatpullssections.execute.e3a67d95")),
            mode, !locked && hasAgent, { onChange("mode", it) }, Modifier.fillMaxWidth())
    }
    val help = when {
        bypassOnly -> L10n.text("common.chat.setup.bypass_only_help")
        bypass -> L10n.text("common.chat.setup.bypass_help")
        else -> L10n.text("common.chat.setup.ask_help")
    }
    ChatSetupBlock(L10n.text("common.chat.setup.permissions"), help) {
        ChatSegmented(if (bypassOnly) listOf("bypass" to L10n.text("android.chatpullssections.don_t_ask.15dae980")) else
            listOf("standard" to L10n.text("android.chatpullssections.ask_first.4a9e8cf3"), "bypass" to L10n.text("android.chatpullssections.don_t_ask.15dae980")),
            if (bypass) "bypass" else "standard", !locked && hasAgent && !bypassOnly, { onChange("autonomy", it) }, Modifier.fillMaxWidth())
    }
}

@Composable
private fun ChatSetupBlock(title: String, detail: String, content: @Composable () -> Unit) {
    val colors = LocalTsColors.current
    TsCard(Modifier.fillMaxWidth()) {
        Column(verticalArrangement = Arrangement.spacedBy(Space.s)) {
            Text(title, style = TsType.headline, color = colors.textPrimary)
            Text(detail, style = TsType.caption, color = colors.textSecondary)
            content()
        }
    }
}
