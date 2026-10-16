// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
package ai.tokenstat.tokenstat.ui.components

import android.content.ClipData
import android.os.Build
import android.widget.Toast
import ai.tokenstat.tokenstat.ui.localization.L10n
import ai.tokenstat.tokenstat.ui.logic.SessionIdentities
import ai.tokenstat.tokenstat.ui.logic.SessionIdentity
import ai.tokenstat.tokenstat.ui.logic.SessionIdentityStatus
import ai.tokenstat.tokenstat.ui.theme.LocalTsColors
import ai.tokenstat.tokenstat.ui.theme.Space
import androidx.compose.foundation.clickable
import androidx.compose.foundation.verticalScroll
import androidx.compose.foundation.layout.*
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.rotate
import androidx.compose.ui.platform.ClipEntry
import androidx.compose.ui.platform.LocalClipboard
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.semantics.stateDescription
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch

/** Copies only the explicitly supplied identifier, never an associated resume payload. */
@Composable
internal fun SessionIdentifierRow(label: String, value: String) {
    val colors = LocalTsColors.current
    val clipboard = LocalClipboard.current
    val context = LocalContext.current
    val scope = rememberCoroutineScope()
    var copied by remember(value) { mutableStateOf(false) }
    val copyLabel = L10n.text("common.session_identity.copy", label)
    val copiedLabel = L10n.text("common.session_identity.copied")
    LaunchedEffect(copied) { if (copied) { delay(1800); copied = false } }
    Row(Modifier.fillMaxWidth().heightIn(min = 48.dp)
        .clickable(role = Role.Button, onClickLabel = copyLabel) {
            scope.launch {
                clipboard.setClipEntry(ClipEntry(ClipData.newPlainText(label, value)))
                copied = true
                // Android 13+ supplies clipboard confirmation itself.
                if (Build.VERSION.SDK_INT < 33) Toast.makeText(context, copiedLabel, Toast.LENGTH_SHORT).show()
            }
        }.padding(vertical = Space.xs),
        verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(Space.s)) {
        Column(Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(2.dp)) {
            Text(label, style = TsType.caption, color = colors.textSecondary)
            Text(value, style = TsType.mono(12), color = colors.textPrimary, maxLines = 1, overflow = TextOverflow.Ellipsis)
        }
        Icon(if (copied) ActionIcon.Done.vector else ActionIcon.Copy.vector,
            null, tint = colors.accent, modifier = Modifier.size(18.dp))
    }
}

@Composable
internal fun SessionIdentifierDialog(value: String, onDismiss: () -> Unit) {
    SessionIdentifierDialog(value, SessionIdentities(), onDismiss)
}

@Composable
internal fun SessionIdentifierDialog(value: String, identities: SessionIdentities, onDismiss: () -> Unit) {
    AlertDialog(onDismissRequest = onDismiss,
        title = { Text(L10n.text("common.session_identity.title")) },
        text = {
            Column(Modifier.heightIn(max = 480.dp).verticalScroll(androidx.compose.foundation.rememberScrollState())) {
                SessionIdentifierRow(L10n.text("common.session_identity.terminal"), value)
                AgentSessionIdentifiers(identities)
            }
        },
        confirmButton = { TextButton(onClick = onDismiss) { Text(L10n.text("common.done")) } })
}

@Composable
internal fun AgentSessionIdentifiers(identities: SessionIdentities, conversationId: String? = null) {
    val current = identities.entries.filter { it.status == SessionIdentityStatus.Current }
    val previous = identities.entries.filter { it.status != SessionIdentityStatus.Current }
    val sources = identities.sourceConversationIds.filter { it != conversationId }
    var historyOpen by remember(conversationId) { mutableStateOf(false) }
    if (identities.entries.isEmpty()) {
        Text(L10n.text("common.session_identity.not_reported"), style = TsType.caption, color = LocalTsColors.current.textSecondary)
    }
    current.forEach { AgentSessionIdentifierRow(it) }
    if (previous.isNotEmpty() || sources.isNotEmpty()) {
        Row(Modifier.fillMaxWidth().heightIn(min = 48.dp)
            .clickable(role = Role.Button) { historyOpen = !historyOpen }
            .semantics { stateDescription = L10n.text(if (historyOpen) "common.collapse" else "common.expand") },
            verticalAlignment = Alignment.CenterVertically) {
            Text(L10n.text("common.history") + " · " + (previous.size + sources.size), Modifier.weight(1f), style = TsType.caption)
            Icon(ActionIcon.Disclosure.vector, null, tint = LocalTsColors.current.textSecondary,
                modifier = Modifier.size(18.dp).rotate(if (historyOpen) 90f else 0f))
        }
        if (historyOpen) {
            previous.forEach { AgentSessionIdentifierRow(it) }
            val label = L10n.text("common.session_identity.previous", L10n.text("common.session_identity.conversation"))
            sources.forEach { SessionIdentifierRow(label, it) }
            Text(L10n.text("common.session_identity.history_help"), style = TsType.caption, color = LocalTsColors.current.textSecondary)
        }
    }
    if (identities.truncated) Text(L10n.text("common.session_identity.truncated", identities.entries.size, identities.total),
        style = TsType.caption, color = LocalTsColors.current.textSecondary)
}

@Composable
private fun AgentSessionIdentifierRow(entry: SessionIdentity) {
    val backend = when (entry.backend) {
        "codex" -> "Codex"
        "claude" -> "Claude"
        "muse" -> "Muse"
        "grok" -> "Grok"
        "cursor" -> "Cursor"
        "agy" -> "Antigravity"
        "opencode", "opencode2" -> "OpenCode"
        else -> entry.backend
    }
    val label = when (entry.status) {
        SessionIdentityStatus.Current -> L10n.text("common.session_identity.current", backend)
        SessionIdentityStatus.Saved -> L10n.text("common.session_identity.saved", backend)
        SessionIdentityStatus.Historical -> L10n.text("common.session_identity.previous", backend)
    }
    SessionIdentifierRow(label, entry.id)
}
