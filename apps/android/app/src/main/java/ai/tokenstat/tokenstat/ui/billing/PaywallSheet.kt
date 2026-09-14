// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
package ai.tokenstat.tokenstat.ui.billing

import android.app.Activity
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.ModalBottomSheet
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.TextStyle
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.sp
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import ai.tokenstat.tokenstat.billing.PlayBillingManager
import ai.tokenstat.tokenstat.ui.components.TsAccentButton
import ai.tokenstat.tokenstat.ui.components.TsSecondaryButton
import ai.tokenstat.tokenstat.ui.marks.TierMark
import ai.tokenstat.tokenstat.ui.theme.LocalTsColors
import ai.tokenstat.tokenstat.ui.theme.Space

/// Tier ladder, the same words the website and the Apple client use. Relay
/// allowances are captions, not feats: they share one window with everything
/// else the connection carries, not a line in the feature list.
private data class Pitch(
    val id: String,
    val tier: String,
    val title: String,
    val summary: String,
    val feats: List<String>,
    val relayCaption: String,
)

private val pitches = listOf(
    Pitch(
        "ai.tokenstat.supporter.yearly",
        "supporter",
        "Supporter",
        "A year of heatmap across your devices, encrypted vault sync, and a public profile worth sharing.",
        listOf(
            "Everything in Free",
            "4 devices, added up into one profile",
            "A year of history on your profile, not 30 days",
            "End-to-end encrypted SSH vault sync across your devices",
            "The supporter star next to your name",
        ),
        "Connections try a direct path first. Relayed traffic shares 1 GiB per rolling 30 UTC days. Direct connections do not count.",
    ),
    Pitch(
        "ai.tokenstat.patron.yearly",
        "patron",
        "Patron",
        "For people running agents on everything they own, and reaching those machines from anywhere.",
        listOf(
            "Everything in Supporter",
            "Remote management: your other devices, from the app",
            "6 devices, added up into one profile",
            "Every day you have ever synced, with no window",
            "Profile updates every 10 minutes",
            "The patron badge next to your name",
        ),
        "Connections try a direct path first. Relayed traffic shares 5 GiB per rolling 30 UTC days. Direct connections do not count.",
    ),
    Pitch(
        "ai.tokenstat.legend.yearly",
        "legend",
        "Legend",
        "The top plan. View and control your own screen remotely, plus more devices, faster sync, and the read API.",
        listOf(
            "Everything in Patron",
            "Remote screen viewing and control",
            "Direct connection first; end-to-end encrypted relay fallback",
            "10 devices, added up into one profile",
            "Profile updates every 5 minutes",
            "The legend crown next to your name",
            "Read API: your numbers as JSON or CSV",
            "First in line when something new lands",
        ),
        "Connections try a direct path first. Relayed traffic shares 20 GiB per rolling 30 UTC days, including terminals, files and screen. Direct connections do not count. One relayed screen can run at a time, with up to 10 minutes per relayed session before reconnecting.",
    ),
)

/// The pitch wraps Play Billing. The system sheet stays the purchase.
@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun PaywallSheet(billing: PlayBillingManager, onDismiss: () -> Unit, currentTier: String? = null) {
    val colors = LocalTsColors.current
    val context = LocalContext.current
    val billingState by billing.state.collectAsStateWithLifecycle()
    ModalBottomSheet(onDismissRequest = onDismiss) {
        Column(
            Modifier
                .fillMaxWidth()
                .verticalScroll(rememberScrollState())
                .padding(horizontal = Space.l)
                .padding(bottom = Space.xl),
            verticalArrangement = Arrangement.spacedBy(Space.m),
        ) {
            Text(
                "The app stays free. A plan unlocks more devices, longer history, and remote management.",
                color = colors.textSecondary,
            )
            pitches.forEach { pitch ->
                val product = billingState.products.find { it.details.productId == pitch.id }
                val isCurrent = currentTier?.equals(pitch.tier, ignoreCase = true) == true
                Column(verticalArrangement = Arrangement.spacedBy(Space.xs)) {
                    Row(horizontalArrangement = Arrangement.spacedBy(Space.s)) {
                        TierMark(pitch.title.lowercase(), markSize = 22)
                        Text(pitch.title, style = TextStyle(fontSize = 18.sp, fontWeight = FontWeight.SemiBold), color = colors.textPrimary)
                    }
                    if (isCurrent) {
                        Text("Your current plan", style = TextStyle(fontSize = 13.sp), color = colors.accent)
                    }
                    Text(pitch.summary, color = colors.textSecondary)
                    pitch.feats.forEach { feat ->
                        Text("· $feat", style = TextStyle(fontSize = 13.sp), color = colors.textSecondary)
                    }
                    Text(pitch.relayCaption, style = TextStyle(fontSize = 12.sp), color = colors.textSecondary)
                    val buttonLabel = when {
                        isCurrent -> "Your current plan"
                        product != null -> "${pitch.title} · ${product.price}"
                        billingState.products.isEmpty() -> "Loading price…"
                        else -> "Price unavailable"
                    }
                    TsAccentButton(
                        label = buttonLabel,
                        enabled = product != null && !isCurrent,
                        onClick = {
                            val found = product ?: return@TsAccentButton
                            (context as? Activity)?.let { billing.purchase(it, found) }
                        },
                        modifier = Modifier.fillMaxWidth(),
                    )
                }
            }
            Text(
                "Plans renew automatically. Payment is charged through Google Play. Each plan change says whether it happens today or at your next renewal. Manage or cancel in Play subscriptions.",
                style = TextStyle(fontSize = 12.sp),
                color = colors.textSecondary,
            )
            billingState.error?.let { Text(it, color = colors.danger) }
            TsSecondaryButton(label = "Close", onClick = onDismiss, modifier = Modifier.fillMaxWidth())
        }
    }
}
