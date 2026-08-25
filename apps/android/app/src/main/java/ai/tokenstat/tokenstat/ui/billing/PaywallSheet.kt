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

private data class Pitch(val id: String, val title: String, val summary: String, val feats: List<String>)

private val pitches = listOf(
    Pitch(
        "ai.tokenstat.supporter.yearly",
        "Supporter",
        "A yearly plan. More devices, a longer history, and a nicer profile.",
        listOf(
            "Everything in Free",
            "4 devices, added up into one profile",
            "A year of history on your profile, not 30 days",
            "Profile updates every 30 minutes, not hourly",
            "The supporter star next to your name",
        ),
    ),
    Pitch(
        "ai.tokenstat.patron.yearly",
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
    ),
    Pitch(
        "ai.tokenstat.legend.yearly",
        "Legend",
        "The top plan. More devices, a faster page, the read API, and first in line when something new lands.",
        listOf(
            "Everything in Patron",
            "10 devices, added up into one profile",
            "Profile updates every 5 minutes",
            "The legend crown next to your name",
            "The read API",
        ),
    ),
)

/// The pitch wraps Play Billing. The system sheet stays the purchase.
@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun PaywallSheet(billing: PlayBillingManager, onDismiss: () -> Unit) {
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
                Column(verticalArrangement = Arrangement.spacedBy(Space.xs)) {
                    Row(horizontalArrangement = Arrangement.spacedBy(Space.s)) {
                        TierMark(pitch.title.lowercase(), markSize = 22)
                        Text(pitch.title, style = TextStyle(fontSize = 18.sp, fontWeight = FontWeight.SemiBold), color = colors.textPrimary)
                    }
                    Text(pitch.summary, color = colors.textSecondary)
                    pitch.feats.forEach { feat ->
                        Text("· $feat", style = TextStyle(fontSize = 13.sp), color = colors.textSecondary)
                    }
                    TsAccentButton(
                        label = if (product != null) "${pitch.title} · ${product.price}" else pitch.title,
                        enabled = product != null,
                        onClick = {
                            val found = product ?: return@TsAccentButton
                            (context as? Activity)?.let { billing.purchase(it, found) }
                        },
                        modifier = Modifier.fillMaxWidth(),
                    )
                }
            }
            billingState.error?.let { Text(it, color = colors.danger) }
            TsSecondaryButton(label = "Close", onClick = onDismiss, modifier = Modifier.fillMaxWidth())
        }
    }
}
