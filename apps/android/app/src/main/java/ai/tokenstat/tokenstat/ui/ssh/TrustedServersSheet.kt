// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
package ai.tokenstat.tokenstat.ui.ssh

import ai.tokenstat.tokenstat.ui.components.TsBottomSheet
import ai.tokenstat.tokenstat.ui.components.ActionIcon
import ai.tokenstat.tokenstat.ui.components.Banner
import ai.tokenstat.tokenstat.ui.components.BannerSeverity
import ai.tokenstat.tokenstat.ui.components.TsCard
import ai.tokenstat.tokenstat.ui.components.TsSecondaryButton
import ai.tokenstat.tokenstat.ui.components.TsType
import ai.tokenstat.tokenstat.ui.localization.L10n
import ai.tokenstat.tokenstat.ui.theme.LocalTsColors
import ai.tokenstat.tokenstat.ui.theme.Space
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.text.selection.SelectionContainer
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.Text
import androidx.compose.material3.rememberModalBottomSheetState
import androidx.compose.runtime.Composable
import androidx.compose.ui.Modifier
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.contentOrNull
import kotlinx.serialization.json.intOrNull

/// A server this phone has agreed to trust, and the keys it showed then.
internal data class TrustedServer(
    val hostId: String,
    val label: String,
    val address: String,
    val fingerprints: List<String>,
)

/// Port of the Apple `SSHKnownHost` rows, answered by `ssh.knownhost.list`.
internal fun trustedServers(answer: JsonElement?): List<TrustedServer> =
    (answer as? JsonArray).orEmpty().mapNotNull { row ->
        val item = row as? JsonObject ?: return@mapNotNull null
        fun text(key: String) = (item[key] as? JsonPrimitive)?.contentOrNull
        val id = text("hostId") ?: return@mapNotNull null
        val hostname = text("hostname").orEmpty()
        val port = (item["port"] as? JsonPrimitive)?.intOrNull ?: 22
        TrustedServer(
            hostId = id,
            label = text("label")?.ifBlank { null } ?: hostname,
            address = "$hostname:$port",
            fingerprints = (item["fingerprints"] as? JsonArray).orEmpty().mapNotNull { (it as? JsonPrimitive)?.contentOrNull },
        )
    }

/// Every trusted server, and the way to take it back. Forgetting one is what
/// makes the next connection ask again, after a server was reinstalled.
@OptIn(ExperimentalMaterial3Api::class)
@Composable
internal fun TrustedServersSheet(
    servers: List<TrustedServer>,
    working: Boolean,
    error: String?,
    onForget: (TrustedServer) -> Unit,
    onDismiss: () -> Unit,
) {
    val colors = LocalTsColors.current
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
            Text(L10n.text("android.ssh.trusted_servers"), style = TsType.headline, color = colors.textPrimary)
            Text(L10n.text("android.ssh.trusted_servers_help"), style = TsType.caption, color = colors.textSecondary)
            error?.let { Banner(it, BannerSeverity.WARNING) }
            if (servers.isEmpty()) {
                Text(L10n.text("android.ssh.no_trusted_servers"), style = TsType.body, color = colors.textSecondary)
            }
            servers.forEach { server ->
                TsCard {
                    Text(server.label, style = TsType.headline, color = colors.textPrimary)
                    Text(server.address, style = TsType.caption, color = colors.textSecondary)
                    SelectionContainer {
                        Column {
                            server.fingerprints.forEach {
                                Text(it, style = TsType.mono(11), color = colors.textSecondary)
                            }
                        }
                    }
                    TsSecondaryButton(
                        label = L10n.text("android.ssh.forget_trust"),
                        icon = ActionIcon.Revoke.vector,
                        small = true,
                        enabled = !working,
                        onClick = { onForget(server) },
                        modifier = Modifier.padding(top = Space.s),
                    )
                }
            }
        }
    }
}
