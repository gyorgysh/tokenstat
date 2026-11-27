// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
package ai.tokenstat.tokenstat.ui.workspace

import ai.tokenstat.tokenstat.AppViewModel
import ai.tokenstat.tokenstat.ui.components.TsPickerField
import ai.tokenstat.tokenstat.ui.localization.L10n
import ai.tokenstat.tokenstat.ui.logic.HostContracts
import androidx.compose.material3.DropdownMenu
import androidx.compose.material3.DropdownMenuItem
import androidx.compose.material3.Text
import androidx.compose.foundation.background
import androidx.compose.material.icons.filled.AccountCircle
import androidx.compose.material.icons.filled.Lock
import androidx.compose.foundation.clickable
import androidx.compose.foundation.border
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.widthIn
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.filled.Add
import androidx.compose.material.icons.filled.Check
import androidx.compose.material.icons.filled.UnfoldMore
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.ui.draw.clip
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.unit.dp
import androidx.compose.runtime.*
import kotlinx.coroutines.CancellationException
import kotlinx.serialization.json.*

internal data class AgentProfile(val id: String, val name: String, val own: Set<String>, val platform: String?) {
    val title: String get() = if (id != "system") name else L10n.text("common.profiles.main")
}

internal class AgentProfiles(value: JsonObject) {
    val defaultId = value.str("default") ?: "system"
    val profiles = (value["profiles"] as? JsonArray).orEmpty().mapNotNull { entry ->
        val profile = entry as? JsonObject ?: return@mapNotNull null
        val id = profile.str("id") ?: return@mapNotNull null
        val own = (profile["own"] as? JsonArray).orEmpty().mapNotNull { (it as? JsonPrimitive)?.contentOrNull }.toSet()
        AgentProfile(id, profile.str("name").orEmpty(), own, profile.str("platform"))
    }
    private val locks = value["workspaceLocks"] as? JsonObject
    fun byId(id: String?): AgentProfile? = profiles.find { it.id == id }
    fun title(id: String?): String = byId(id)?.title ?: L10n.text("common.profiles.removed")
    fun locked(workspace: String?): String? = workspace?.let { locks?.str(it) }
}

@Composable
internal fun rememberAgentProfiles(model: AppViewModel, peer: String, protocol: Long?): AgentProfiles? {
    var value by remember(model, peer, protocol) { mutableStateOf<AgentProfiles?>(null) }
    LaunchedEffect(model, peer, protocol) {
        if (peer.isBlank() || !HostContracts.supportsAgentProfiles(protocol)) return@LaunchedEffect
        try {
            value = (model.workspaceSection(peer, "profiles.list", buildJsonObject {}) as? JsonObject)?.let(::AgentProfiles)
        } catch (cancelled: CancellationException) {
            throw cancelled
        } catch (_: Exception) {
        }
    }
    return value
}

internal fun ownAgentProfile(profiles: AgentProfiles?, id: String?, launcher: String?): String? {
    if (id == null || id == "system") return null
    return id.takeIf { profiles?.byId(id)?.own?.contains(launcher) != false }
}

internal fun agentProfileTitle(profiles: AgentProfiles?, id: String?): String? =
    id?.takeIf { it != "system" }?.let { profiles?.title(it) ?: L10n.text("common.profiles.named_limits") }

internal fun withAgentProfile(summary: String, profiles: AgentProfiles?, id: String?): String =
    agentProfileTitle(profiles, id)?.let { "$summary · $it" } ?: summary

@Composable
internal fun AgentProfilePicker(profiles: AgentProfiles, selected: String?, lock: String?,
    enabled: Boolean, onChange: (String) -> Unit,
) {
    if (profiles.profiles.size < 2 && (selected == null || selected == "system") && lock == null) return
    if (lock != null && lock == selected) {
        Text(L10n.text("common.profiles.locked", profiles.title(lock)))
        return
    }
    var open by remember { mutableStateOf(false) }
    val active = selected ?: profiles.defaultId
    Box {
        TsPickerField(
            summary = L10n.text("common.profiles.label") + " · " + profiles.title(active),
            enabled = enabled,
            onOpen = { open = true },
        )
        DropdownMenu(expanded = open, onDismissRequest = { open = false }) {
            profiles.profiles.filter { lock == null || it.id == lock }.forEach { profile ->
                DropdownMenuItem(
                    text = { Text(profile.title) },
                    enabled = profile.id != active,
                    onClick = { open = false; onChange(profile.id) },
                )
            }
        }
    }
}

@Composable
internal fun AgentProfileRow(profiles: AgentProfiles, selected: String?, lock: String?,
    enabled: Boolean, onChange: (String) -> Unit,
) {
    val colors = ai.tokenstat.tokenstat.ui.theme.LocalTsColors.current
    val active = lock ?: selected ?: profiles.defaultId
    var open by remember { mutableStateOf(false) }
    var explaining by remember { mutableStateOf(false) }
    val detail = when {
        lock != null -> L10n.text("common.profiles.locked", profiles.title(lock))
        active == "system" -> L10n.text("common.profiles.main_detail")
        else -> L10n.text("common.profiles.row_detail")
    }
    Box {
        androidx.compose.foundation.layout.Row(
            androidx.compose.ui.Modifier
                .fillMaxWidth()
                .clip(RoundedCornerShape(12.dp))
                .border(1.dp, colors.border, RoundedCornerShape(12.dp))
                .clickable(enabled = enabled && lock == null, role = androidx.compose.ui.semantics.Role.Button) { open = true }
                .semantics(mergeDescendants = true) {
                    contentDescription = L10n.text("common.profiles.label") + ", " + profiles.title(active) + ", " + detail
                }
                .heightIn(min = 56.dp)
                .padding(horizontal = 12.dp, vertical = 8.dp),
            verticalAlignment = androidx.compose.ui.Alignment.CenterVertically,
            horizontalArrangement = androidx.compose.foundation.layout.Arrangement.spacedBy(12.dp),
        ) {
            Box(
                androidx.compose.ui.Modifier.size(32.dp).clip(CircleShape).background(colors.accentSoft),
                contentAlignment = androidx.compose.ui.Alignment.Center,
            ) {
                androidx.compose.material3.Icon(
                    if (lock != null) androidx.compose.material.icons.Icons.Default.Lock
                    else androidx.compose.material.icons.Icons.Default.AccountCircle,
                    null, tint = colors.accent, modifier = androidx.compose.ui.Modifier.size(18.dp),
                )
            }
            androidx.compose.foundation.layout.Column(androidx.compose.ui.Modifier.weight(1f)) {
                Text(profiles.title(active), style = ai.tokenstat.tokenstat.ui.components.TsType.callout,
                    fontWeight = androidx.compose.ui.text.font.FontWeight.SemiBold,
                    color = colors.textPrimary, maxLines = 1, overflow = TextOverflow.Ellipsis)
                Text(detail, style = ai.tokenstat.tokenstat.ui.components.TsType.caption,
                    color = colors.textSecondary, maxLines = 1, overflow = TextOverflow.Ellipsis)
            }
            if (lock == null) androidx.compose.material3.Icon(
                androidx.compose.material.icons.Icons.Default.UnfoldMore, null,
                tint = colors.textSecondary, modifier = androidx.compose.ui.Modifier.size(20.dp),
            )
        }
        DropdownMenu(expanded = open, onDismissRequest = { open = false }) {
            Text(
                L10n.text("common.profiles.explain"),
                style = ai.tokenstat.tokenstat.ui.components.TsType.caption,
                color = colors.textSecondary,
                modifier = androidx.compose.ui.Modifier.widthIn(max = 280.dp).padding(horizontal = 16.dp, vertical = 8.dp),
            )
            profiles.profiles.forEach { profile ->
                DropdownMenuItem(
                    text = { Text(profile.title) },
                    trailingIcon = if (profile.id == active) {
                        { androidx.compose.material3.Icon(androidx.compose.material.icons.Icons.Default.Check, null, tint = colors.accent) }
                    } else null,
                    enabled = profile.id != active,
                    onClick = { open = false; onChange(profile.id) },
                )
            }
            androidx.compose.material3.HorizontalDivider()
            DropdownMenuItem(
                text = { Text(L10n.text("common.profiles.add_ellipsis")) },
                leadingIcon = { androidx.compose.material3.Icon(androidx.compose.material.icons.Icons.Default.Add, null) },
                onClick = { open = false; explaining = true },
            )
        }
    }
    if (explaining) androidx.compose.material3.AlertDialog(
        onDismissRequest = { explaining = false },
        title = { Text(L10n.text("common.profiles.add")) },
        text = { Text(L10n.text("common.profiles.add_on_host")) },
        confirmButton = {
            androidx.compose.material3.TextButton(onClick = { explaining = false }) { Text(L10n.text("common.done")) }
        },
    )
}
