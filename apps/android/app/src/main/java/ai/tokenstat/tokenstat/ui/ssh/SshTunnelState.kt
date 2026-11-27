// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
package ai.tokenstat.tokenstat.ui.ssh

import ai.tokenstat.tokenstat.ui.localization.L10n

import ai.tokenstat.tokenstat.ui.components.BannerSeverity
import ai.tokenstat.tokenstat.ui.components.TsType
import ai.tokenstat.tokenstat.ui.components.cardRadiusDp
import ai.tokenstat.tokenstat.ui.theme.LocalTsColors
import ai.tokenstat.tokenstat.ui.theme.Space
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.Icon
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.unit.dp
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.booleanOrNull
import kotlinx.serialization.json.contentOrNull

sealed interface TunnelState {
    data object Off : TunnelState

    data class NotConnected(val error: String?) : TunnelState

    data object Unregistered : TunnelState

    data object PlanExpired : TunnelState

    data object Up : TunnelState
}

fun tunnelStateOf(status: JsonObject?): TunnelState {
    if (status == null) return TunnelState.Off
    val enabled = (status["tunnel"] as? JsonPrimitive)?.booleanOrNull == true
    if (!enabled) return TunnelState.Off
    val error = (status["tunnelError"] as? JsonPrimitive)?.contentOrNull?.takeIf { it.isNotBlank() }
    if (error?.contains("not_on_this_plan") == true) return TunnelState.PlanExpired
    val online = (status["tunnelOnline"] as? JsonPrimitive)?.booleanOrNull
    if (online != true) return TunnelState.NotConnected(error)
    val registered = (status["tunnelRegistered"] as? JsonPrimitive)?.booleanOrNull
    if (registered == false) return TunnelState.Unregistered
    return TunnelState.Up
}

fun TunnelState.message(): String? = when (this) {
    is TunnelState.NotConnected -> if (error != null) {
        L10n.text("android.sshtunnelstate.remote_reach_is_on_but_the_tunnel_is_not_c.c73ccbbf", "${error}")
    } else {
        L10n.text("android.sshtunnelstate.remote_reach_is_on_but_the_tunnel_has_not.024544f1")
    }
    is TunnelState.Unregistered ->
        L10n.text("android.sshtunnelstate.this_machine_is_on_the_tunnel_but_the_acco.7b29b022")
    is TunnelState.PlanExpired ->
        L10n.text("android.sshtunnelstate.your_plan_no_longer_includes_remote_reach.fc6a711f")
    is TunnelState.Off, is TunnelState.Up -> null
}

@Composable
fun TunnelStatusBanner(status: JsonObject?, modifier: Modifier = Modifier) {
    tunnelStateOf(status).message()?.let { text ->
        val colors = LocalTsColors.current
        Row(
            modifier
                .fillMaxWidth()
                .clip(RoundedCornerShape(cardRadiusDp))
                .background(colors.warning.copy(alpha = 0.12f))
                .padding(Space.s),
            horizontalArrangement = Arrangement.spacedBy(Space.s),
            verticalAlignment = Alignment.CenterVertically,
        ) {
            Icon(BannerSeverity.WARNING.symbol, null, tint = colors.warning, modifier = Modifier.size(16.dp))
            Text(text, style = TsType.footnote, color = colors.warning, modifier = Modifier.weight(1f))
        }
    }
}
