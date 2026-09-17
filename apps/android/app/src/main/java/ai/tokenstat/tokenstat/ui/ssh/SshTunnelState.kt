// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
package ai.tokenstat.tokenstat.ui.ssh

import ai.tokenstat.tokenstat.ui.components.Banner
import ai.tokenstat.tokenstat.ui.components.BannerSeverity
import androidx.compose.runtime.Composable
import androidx.compose.ui.Modifier
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
        "Remote reach is on, but the tunnel is not connected: $error"
    } else {
        "Remote reach is on, but the tunnel has not connected yet. It retries automatically."
    }
    is TunnelState.Unregistered ->
        "This machine is on the tunnel, but the account directory does not list it yet. It will retry registration automatically."
    is TunnelState.PlanExpired ->
        "Your plan no longer includes remote reach. The relay is refusing this machine until the plan is restored."
    is TunnelState.Off, is TunnelState.Up -> null
}

/// The sticky tunnel banner. It renders only while the state needs words, so
/// a healthy tunnel adds nothing to the screen and a refusing one cannot be
/// missed or dismissed into being fixed.
@Composable
fun TunnelStatusBanner(status: JsonObject?, modifier: Modifier = Modifier) {
    tunnelStateOf(status).message()?.let { text ->
        Banner(text, BannerSeverity.WARNING, modifier = modifier)
    }
}
