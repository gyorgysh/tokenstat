// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
package ai.tokenstat.tokenstat.ui.ssh

import ai.tokenstat.tokenstat.ui.localization.L10n

import ai.tokenstat.tokenstat.ui.components.ActionIcon
import ai.tokenstat.tokenstat.ui.components.TsCard
import ai.tokenstat.tokenstat.ui.components.TsProminentButton
import ai.tokenstat.tokenstat.ui.theme.LocalTsColors
import ai.tokenstat.tokenstat.ui.theme.Space
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Key
import androidx.compose.material.icons.filled.Star
import androidx.compose.material.icons.filled.Terminal
import androidx.compose.material3.DropdownMenu
import androidx.compose.material3.DropdownMenuItem
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.booleanOrNull

/// The tail, not the whole line. A full SHA256 fingerprint is wider than a
/// phone, so the row prints what comes after the `SHA256:` prefix, which is
/// the part you compare against. Port of `SSHLibraryView.shortFingerprint`.
fun shortFingerprint(value: String?): String? {
    if (value.isNullOrEmpty()) return null
    val separator = value.indexOf(":")
    if (separator < 0) return value
    return value.substring(separator + 1).takeIf { it.isNotEmpty() } ?: value
}

@Composable
private fun SshRowShell(
    title: String,
    subtitle: String?,
    onOpen: () -> Unit,
    leading: @Composable () -> Unit,
    menu: @Composable (close: () -> Unit) -> Unit,
    trailing: @Composable (() -> Unit)? = null,
) {
    val colors = LocalTsColors.current
    var open by remember { mutableStateOf(false) }
    TsCard(Modifier.clickable { onOpen() }) {
        Row(verticalAlignment = Alignment.CenterVertically, modifier = Modifier.fillMaxWidth()) {
            leading()
            Spacer(Modifier.width(Space.m))
            Column(Modifier.weight(1f)) {
                Text(title, fontWeight = FontWeight.SemiBold, color = colors.textPrimary, maxLines = 1)
                subtitle?.let {
                    Text(it, style = MaterialTheme.typography.bodySmall, color = colors.textSecondary, maxLines = 1)
                }
            }
            trailing?.let { it() }
            IconButton(onClick = { open = true }) {
                Icon(ActionIcon.More.vector, L10n.text("android.sshrows.more_actions.f8d46c25"), tint = colors.textSecondary)
            }
            DropdownMenu(expanded = open, onDismissRequest = { open = false }) {
                menu { open = false }
            }
        }
    }
}

/// One saved server: its color strip, its platform mark, its name, and a
/// Connect button that stays visible. The long-press menu is a popup:
/// connect, favourites, edit, delete. Port of `SSHHostRow` plus `hostRow`'s
/// context menu.
///
/// The address is deliberately not here. The Apple row shows the name and the
/// confirmed platform only; the address lives in the editor, which is the
/// detail side. A row must never print a bare IP.
@Composable
fun SshHostRow(
    host: JsonObject,
    folderName: String?,
    searching: Boolean,
    onConnect: () -> Unit,
    onEdit: () -> Unit,
    onDelete: () -> Unit,
    onToggleFavorite: () -> Unit,
) {
    val colors = LocalTsColors.current
    val context = androidx.compose.ui.platform.LocalContext.current
    val favorite = (host["favorite"] as? kotlinx.serialization.json.JsonPrimitive)?.booleanOrNull == true
    val platform = remember(host) { SshHostPlatform.label(context, host) }
    val label = host.sshString("label") ?: L10n.text("android.sshrows.ssh_host.7e873f33")
    var open by remember { mutableStateOf(false) }
    TsCard(Modifier.clickable { onConnect() }) {
        Row(verticalAlignment = Alignment.CenterVertically, modifier = Modifier.fillMaxWidth()) {
            Box(
                Modifier
                    .width(4.dp)
                    .height(40.dp)
                    .clip(RoundedCornerShape(2.dp))
                    .background(sshStripColor(host.sshString("color"))),
            )
            Spacer(Modifier.width(Space.s))
            SshHostMark(platformLabel = platform)
            Spacer(Modifier.width(Space.m))
            Column(Modifier.weight(1f)) {
                Row(verticalAlignment = Alignment.CenterVertically) {
                    Text(
                        label,
                        fontWeight = FontWeight.SemiBold,
                        color = colors.textPrimary,
                        maxLines = 1,
                        overflow = TextOverflow.Ellipsis,
                        modifier = Modifier.weight(1f, fill = false),
                    )
                    if (favorite) {
                        Spacer(Modifier.width(4.dp))
                        Icon(Icons.Default.Star, L10n.text("android.sshrows.favourite.e39b2499"), tint = colors.warning, modifier = Modifier.size(12.dp))
                    }
                }
                if (searching && folderName != null) {
                    Text(
                        folderName,
                        style = MaterialTheme.typography.labelSmall,
                        color = colors.textSecondary,
                        maxLines = 1,
                        overflow = TextOverflow.Ellipsis,
                        modifier = Modifier
                            .padding(top = 2.dp)
                            .clip(RoundedCornerShape(8.dp))
                            .background(colors.rowHighlight)
                            .padding(horizontal = 6.dp, vertical = 1.dp),
                    )
                }
                platform?.let {
                    Text(it, style = MaterialTheme.typography.bodySmall, color = colors.textSecondary, maxLines = 1)
                }
            }
            TsProminentButton(label = L10n.text("common.connect"), small = true, onClick = onConnect)
            IconButton(onClick = { open = true }) {
                Icon(ActionIcon.More.vector, L10n.text("android.sshrows.more_actions.f8d46c25"), tint = colors.textSecondary)
            }
            DropdownMenu(expanded = open, onDismissRequest = { open = false }) {
                DropdownMenuItem(text = { Text(L10n.text("common.connect")) }, onClick = { open = false; onConnect() })
                DropdownMenuItem(
                    text = { Text(if (favorite) L10n.text("android.sshrows.remove_from_favourites.a5bdeced") else L10n.text("android.sshrows.add_to_favourites.9e619bff")) },
                    onClick = { open = false; onToggleFavorite() },
                )
                DropdownMenuItem(text = { Text(L10n.text("common.edit")) }, onClick = { open = false; onEdit() })
                DropdownMenuItem(
                    text = { Text(L10n.text("common.delete"), color = colors.danger) },
                    onClick = { open = false; onDelete() },
                )
            }
        }
    }
}

/// One saved key: its label and the fingerprint tail. Copying the public key
/// is the reason to open one at all, so it has a shortcut rather than hiding
/// behind the editor. Port of `keyRow`.
@Composable
fun SshKeyRow(
    key: JsonObject,
    onEdit: () -> Unit,
    onCopyPublic: () -> Unit,
    onCopyFingerprint: () -> Unit,
    onDelete: () -> Unit,
) {
    val colors = LocalTsColors.current
    val fingerprint = key.sshString("fingerprint").orEmpty()
    SshRowShell(
        title = key.sshString("label") ?: L10n.text("android.sshrows.key.99a52df3"),
        subtitle = shortFingerprint(fingerprint) ?: key.sshString("algorithm") ?: L10n.text("android.sshrows.key.99a52df3"),
        onOpen = onEdit,
        leading = { Icon(Icons.Default.Key, null, tint = colors.accent) },
        menu = { close ->
            DropdownMenuItem(text = { Text(L10n.text("common.edit")) }, onClick = { close(); onEdit() })
            DropdownMenuItem(text = { Text(L10n.text("android.sshrows.copy_public_key.5f2f4548")) }, onClick = { close(); onCopyPublic() })
            if (fingerprint.isNotEmpty()) {
                DropdownMenuItem(text = { Text(L10n.text("android.sshrows.copy_fingerprint.71ab1ba9")) }, onClick = { close(); onCopyFingerprint() })
            }
            DropdownMenuItem(
                text = { Text(L10n.text("common.delete"), color = colors.danger) },
                onClick = { close(); onDelete() },
            )
        },
    )
}

/// One saved command. Port of `snippetRow`.
@Composable
fun SshSnippetRow(
    snippet: JsonObject,
    onEdit: () -> Unit,
    onCopy: () -> Unit,
    onToggleRunOnConnect: () -> Unit,
    onDelete: () -> Unit,
) {
    val colors = LocalTsColors.current
    val runOnConnect = (snippet["runOnConnect"] as? kotlinx.serialization.json.JsonPrimitive)?.booleanOrNull == true
    SshRowShell(
        title = snippet.sshString("title") ?: L10n.text("android.sshrows.snippet.48f55cb8"),
        subtitle = snippet.sshString("command").orEmpty(),
        onOpen = onEdit,
        leading = { Icon(Icons.Default.Terminal, null, tint = colors.accent) },
        menu = { close ->
            DropdownMenuItem(text = { Text(L10n.text("common.edit")) }, onClick = { close(); onEdit() })
            DropdownMenuItem(text = { Text(L10n.text("android.sshrows.copy_command.9a01feec")) }, onClick = { close(); onCopy() })
            DropdownMenuItem(
                text = { Text(if (runOnConnect) L10n.text("android.sshrows.do_not_run_on_connect.7917a1db") else L10n.text("android.sshrows.run_on_connect.185c4e03")) },
                onClick = { close(); onToggleRunOnConnect() },
            )
            DropdownMenuItem(
                text = { Text(L10n.text("common.delete"), color = colors.danger) },
                onClick = { close(); onDelete() },
            )
        },
    )
}
