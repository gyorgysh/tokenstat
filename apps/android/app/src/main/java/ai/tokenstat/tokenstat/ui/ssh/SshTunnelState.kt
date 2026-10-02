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

/// What the tunnel is actually doing, read from `remote.status`.
///
/// What the user chose and what is true differ while the tunnel is being
/// refused, and a screen that showed only the toggle would invite effort that
/// can never work. Ported from the `serving` banners in `MachinesView.swift`.
sealed interface TunnelState {
    /// Remote reach is off. Nothing to say: an off switch is not a warning.
    data object Off : TunnelState

    /// The toggle is on but the session is not running. Sticky by design: it
    /// stays on screen with its sentence until the tunnel connects, and never
    /// flashes as a transient toast.
    data class NotConnected(val error: String?) : TunnelState

    /// On the tunnel, but the account directory does not list this machine
    /// yet. Registration retries on its own.
    data object Unregistered : TunnelState

    /// The relay refuses this machine until the plan is restored.
    data object PlanExpired : TunnelState

    /// The tunnel is up and registered. Nothing to say.
    data object Up : TunnelState
}

/// Read the tunnel state from a `remote.status` answer. Missing stays
/// missing: an answer that says nothing about the tunnel is not evidence it
/// is down, so it reads as off rather than as a warning.
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

/// The sentence for a state that needs one. Null where silence is the honest
/// answer: off and up are not warnings.
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

/// The sticky tunnel banner. It renders only while the state needs words, so
/// a healthy tunnel adds nothing to the screen and a refusing one cannot be
/// missed or dismissed into being fixed.
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
