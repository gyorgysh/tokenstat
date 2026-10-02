// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
package ai.tokenstat.tokenstat.ui.connection

import ai.tokenstat.tokenstat.ui.components.ActionIcon
import ai.tokenstat.tokenstat.ui.components.TsSecondaryButton
import ai.tokenstat.tokenstat.ui.components.TsType
import ai.tokenstat.tokenstat.ui.components.cardRadiusDp
import ai.tokenstat.tokenstat.ui.components.tsPanel
import ai.tokenstat.tokenstat.ui.localization.L10n
import ai.tokenstat.tokenstat.ui.marks.FeatureMark
import ai.tokenstat.tokenstat.ui.ssh.TunnelStatusBanner
import ai.tokenstat.tokenstat.ui.theme.LocalTsColors
import ai.tokenstat.tokenstat.ui.theme.Space
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.dp
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.contentOrNull
import kotlinx.serialization.json.longOrNull

/** Compact local connection details, independent of the host that loads them. */
@Composable
internal fun LocalTrafficPanel(
    status: JsonObject?,
    loading: Boolean,
    error: String?,
    onRefresh: () -> Unit,
    modifier: Modifier = Modifier,
) {
    val colors = LocalTsColors.current
    Column(
        modifier
            .fillMaxWidth()
            .clip(RoundedCornerShape(cardRadiusDp))
            .tsPanel()
            .padding(12.dp),
        verticalArrangement = Arrangement.spacedBy(Space.s),
    ) {
        Row(
            verticalAlignment = Alignment.CenterVertically,
            horizontalArrangement = Arrangement.spacedBy(Space.s),
        ) {
            FeatureMark(name = "mark_activity", tint = colors.accent, size = 18)
            Column(Modifier.weight(1f)) {
                Text(
                    L10n.text("android.tokenstatapp.this_device.d052579c"),
                    style = TsType.cardTitle,
                    color = colors.textPrimary,
                )
                Text(
                    L10n.text("android.tokenstatapp.how_connections_leave_this_machine.a5ac544a"),
                    style = TsType.caption,
                    color = colors.textSecondary,
                )
            }
        }
        Column(verticalArrangement = Arrangement.spacedBy(Space.xs)) {
            error?.let { Text(it, style = TsType.footnote, color = colors.warning) }
            TunnelStatusBanner(status = status)
            val snapshot = status?.get("traffic") as? JsonObject
            if (snapshot == null && !loading && error == null) {
                Text(
                    L10n.text("android.tokenstatapp.this_computer_does_not_report_local_traffi.c31505cb"),
                    style = TsType.footnote,
                    color = colors.textSecondary,
                )
            } else if (snapshot != null) {
                LocalTrafficUsageRow(L10n.text("android.tokenstatapp.direct.002c7c68"), snapshot.long("directBytes") ?: 0L)
                LocalTrafficUsageRow(L10n.text("android.tokenstatapp.relayed.feb39b70"), snapshot.long("relayBytes") ?: 0L)
                Text(
                    L10n.text("android.tokenstatapp.counted_on_this_device_since_tokenstat_sta.0fc360a7"),
                    style = TsType.caption,
                    color = colors.textSecondary,
                )
                val peers = (snapshot["peers"] as? JsonArray).orEmpty().mapNotNull { it as? JsonObject }
                if (peers.isEmpty()) {
                    Text(
                        L10n.text("android.tokenstatapp.no_live_connections_right_now.a7f971c5"),
                        style = TsType.caption,
                        color = colors.textSecondary,
                    )
                } else {
                    peers.forEach { peer ->
                        Row(
                            Modifier.fillMaxWidth().semantics(mergeDescendants = true) { },
                            horizontalArrangement = Arrangement.spacedBy(Space.s),
                            verticalAlignment = Alignment.Top,
                        ) {
                            Text(
                                peer.string("label")?.ifBlank { null } ?: peer.string("peer").orEmpty(),
                                style = TsType.footnote,
                                color = colors.textPrimary,
                                modifier = Modifier.weight(1f),
                            )
                            Text(
                                transportLabel(peer.string("route")),
                                style = TsType.caption,
                                color = colors.textSecondary,
                                textAlign = TextAlign.End,
                                modifier = Modifier.weight(1f),
                            )
                        }
                    }
                }
            }
            TsSecondaryButton(
                label = if (loading) L10n.text("android.tokenstatapp.refreshing.1c0def7b") else L10n.text("android.tokenstatapp.refresh_traffic.9e5ac8c2"),
                icon = ActionIcon.Refresh.vector,
                onClick = onRefresh,
                enabled = !loading,
                modifier = Modifier.fillMaxWidth(),
            )
        }
    }
}

@Composable
private fun LocalTrafficUsageRow(label: String, bytes: Long) {
    val colors = LocalTsColors.current
    Row(
        Modifier.fillMaxWidth().semantics(mergeDescendants = true) { },
        horizontalArrangement = Arrangement.spacedBy(Space.s),
        verticalAlignment = Alignment.Top,
    ) {
        Text(label, style = TsType.footnote, modifier = Modifier.weight(1f), color = colors.textSecondary)
        Text(formatTrafficBytes(bytes), style = TsType.numeric(13), color = colors.textPrimary)
    }
}

internal fun formatTrafficBytes(n: Long): String {
    val value = n.coerceAtLeast(0).toDouble()
    val kibi = 1024.0
    fun fmt(x: Double, unit: String): String {
        // Trim decimal zeros only; whole amounts such as 20 GiB keep their zero.
        val shown = if (x >= 10) {
            "%.0f".format(x)
        } else {
            "%.1f".format(x).trimEnd('0').trimEnd('.', ',')
        }
        return shown + " " + unit
    }
    return when {
        value >= kibi * kibi * kibi -> fmt(value / (kibi * kibi * kibi), "GiB")
        value >= kibi * kibi -> fmt(value / (kibi * kibi), "MiB")
        value >= kibi -> fmt(value / kibi, "KiB")
        else -> "${n.coerceAtLeast(0)} B"
    }
}

private fun transportLabel(raw: String?): String = when (raw) {
    "direct" -> L10n.text("android.tokenstatapp.direct_connection.28d0ad54")
    "relay" -> L10n.text("android.tokenstatapp.encrypted_relay.153d7b1c")
    else -> raw ?: L10n.text("common.unknown")
}

private fun JsonObject.string(key: String): String? = (this[key] as? JsonPrimitive)?.contentOrNull
private fun JsonObject.long(key: String): Long? = (this[key] as? JsonPrimitive)?.longOrNull
