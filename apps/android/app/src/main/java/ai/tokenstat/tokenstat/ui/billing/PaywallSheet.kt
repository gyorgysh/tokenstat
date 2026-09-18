// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
package ai.tokenstat.tokenstat.ui.billing

import android.app.Activity
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Check
import androidx.compose.material.icons.filled.ExpandLess
import androidx.compose.material.icons.filled.ExpandMore
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.Icon
import androidx.compose.material3.ModalBottomSheet
import androidx.compose.material3.rememberModalBottomSheetState
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.TextStyle
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import ai.tokenstat.tokenstat.billing.PlayBillingManager
import ai.tokenstat.tokenstat.ui.components.SectionTitle
import ai.tokenstat.tokenstat.ui.components.SegmentedCapsulePicker
import ai.tokenstat.tokenstat.ui.components.TsAccentButton
import ai.tokenstat.tokenstat.ui.components.TsCard
import ai.tokenstat.tokenstat.ui.components.TsSecondaryButton
import ai.tokenstat.tokenstat.ui.marks.TierMark
import ai.tokenstat.tokenstat.ui.theme.LocalTsColors
import ai.tokenstat.tokenstat.ui.theme.Space

/// Tier ladder, the same words the website and the Apple client use. Relay
/// allowances are captions, not feats: they share one window with everything
/// else the connection carries, not a line in the feature list.
private data class Pitch(
    val productId: String,
    val hasMonthly: Boolean,
    val tier: String,
    val title: String,
    val summary: String,
    val feats: List<String>,
    val relayCaption: String,
)

private val pitches = listOf(
    Pitch(
        "ai.tokenstat.supporter.yearly",
        false,
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
        true,
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
        true,
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

/// The comparison, Free included. Free is not for sale, but a plan's pitch
/// only lands when the free tier's own limits are beside it.
private val compareTitles = listOf("Free", "Supporter", "Patron", "Legend")
private val compareFeatures = listOf(
    "Devices" to listOf("2", "4", "6", "10"),
    "History" to listOf("30 days", "1 yr", "All", "All"),
    "Terminal + SSH" to listOf("No", "No", "Yes", "Yes"),
    "View screen" to listOf("No", "No", "No", "Yes"),
    "Relay traffic" to listOf("100 MiB", "1 GiB", "5 GiB", "20 GiB"),
    "Sync" to listOf("Hourly", "30 min", "10 min", "5 min"),
    "Mark" to listOf("None", "Star", "Badge", "Crown"),
    "Read API" to listOf("No", "No", "No", "Yes"),
)

/// In-app plans, yearly by default. The pitch wraps Play Billing; the system
/// sheet stays the purchase. Supporter is yearly only, like on Apple.
@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun PaywallSheet(
    billing: PlayBillingManager,
    onDismiss: () -> Unit,
    currentTier: String? = null,
    /// This account's billing interval, "month" or "year", when it has one.
    currentInterval: String? = null,
) {
    val colors = LocalTsColors.current
    val context = LocalContext.current
    val billingState by billing.state.collectAsStateWithLifecycle()
    var monthly by rememberSaveable { mutableStateOf(false) }
    val catalog = if (monthly) pitches.filter { it.hasMonthly } else pitches
    // Full height. This is a list of plans with a paragraph each; opening it
    // half way over the sheet that launched it showed one and a half cards
    // and made comparing them a scroll inside a scroll inside a sheet.
    ModalBottomSheet(
        onDismissRequest = onDismiss,
        sheetState = rememberModalBottomSheetState(skipPartiallyExpanded = true),
        containerColor = colors.background,
    ) {
        Column(
            Modifier
                .fillMaxWidth()
                .verticalScroll(rememberScrollState())
                .padding(horizontal = Space.l)
                .padding(bottom = Space.xl),
            verticalArrangement = Arrangement.spacedBy(Space.m),
        ) {
            SectionTitle(title = if (monthly) "Monthly plans" else "Yearly plans", mark = "mark_plan")
            Text(
                "The app stays free. A plan unlocks more devices, longer history, and remote management.",
                color = colors.textSecondary,
            )
            SegmentedCapsulePicker(
                options = listOf(
                    Triple(false, "Yearly", null as ImageVector?),
                    Triple(true, "Monthly", null as ImageVector?),
                ),
                selection = monthly,
                onSelect = { monthly = it },
                modifier = Modifier.fillMaxWidth(),
            )
            Text(
                if (monthly) "Supporter is yearly only." else "Two months free versus monthly.",
                style = TextStyle(fontSize = 12.sp),
                color = colors.textSecondary,
            )
            catalog.forEach { pitch ->
                val interval = if (monthly) PlayBillingManager.INTERVAL_MONTH else PlayBillingManager.INTERVAL_YEAR
                val product = billingState.products.find {
                    it.details.productId == pitch.productId && it.interval == interval
                }
                val sameTier = currentTier?.equals(pitch.tier, ignoreCase = true) == true
                val isCurrent = sameTier && currentInterval == interval
                // The tier on the other interval, switchable only when Play
                // holds the subscription to replace. A plan bought on the web
                // or the App Store reads as current instead: offering the
                // switch would stack a second subscription beside it.
                val canSwitch = sameTier && currentInterval != null && !isCurrent &&
                    billingState.hasPlaySubscription
                val readsCurrent = isCurrent ||
                    (sameTier && currentInterval != null && !isCurrent && !billingState.hasPlaySubscription)
                TsCard {
                    Column(verticalArrangement = Arrangement.spacedBy(Space.xs)) {
                        Row(horizontalArrangement = Arrangement.spacedBy(Space.s), verticalAlignment = Alignment.CenterVertically) {
                            TierMark(pitch.title.lowercase(), markSize = 22)
                            Text(pitch.title, style = TextStyle(fontSize = 18.sp, fontWeight = FontWeight.SemiBold), color = colors.textPrimary, modifier = Modifier.weight(1f))
                            Text(
                                when {
                                    product != null -> product.price + if (monthly) " / month" else " / year"
                                    billingState.products.isEmpty() -> "Loading price…"
                                    else -> "Price unavailable"
                                },
                                style = TextStyle(fontSize = 13.sp, fontWeight = FontWeight.SemiBold),
                                color = colors.textSecondary,
                            )
                        }
                        if (readsCurrent) {
                            Text("Your current plan", style = TextStyle(fontSize = 13.sp), color = colors.accent)
                        }
                        Text(pitch.summary, color = colors.textSecondary)
                        pitch.feats.forEach { feat ->
                            Row(horizontalArrangement = Arrangement.spacedBy(Space.s)) {
                                Icon(Icons.Default.Check, null, tint = colors.accent, modifier = Modifier.width(14.dp))
                                Text(feat, style = TextStyle(fontSize = 13.sp), color = colors.textSecondary)
                            }
                        }
                        Text(pitch.relayCaption, style = TextStyle(fontSize = 12.sp), color = colors.textSecondary)
                        product?.introCaption?.let {
                            Text(it, style = TextStyle(fontSize = 12.sp), color = colors.accent)
                        }
                        val buttonLabel = when {
                            readsCurrent -> "Your current plan"
                            canSwitch -> if (monthly) "Switch to monthly" else "Switch to yearly"
                            product != null -> "${pitch.title} · ${product.price}"
                            billingState.products.isEmpty() -> "Loading price…"
                            else -> "Price unavailable"
                        }
                        TsAccentButton(
                            label = buttonLabel,
                            enabled = product != null && !readsCurrent,
                            onClick = {
                                val found = product ?: return@TsAccentButton
                                (context as? Activity)?.let { billing.purchase(it, found) }
                            },
                            modifier = Modifier.fillMaxWidth(),
                        )
                    }
                }
            }
            ComparePlansCard()
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

@Composable
private fun ComparePlansCard() {
    val colors = LocalTsColors.current
    var open by rememberSaveable { mutableStateOf(false) }
    TsCard(modifier = Modifier.clickable { open = !open }) {
        Column(verticalArrangement = Arrangement.spacedBy(Space.s)) {
            Row(verticalAlignment = Alignment.CenterVertically) {
                Text(
                    "Compare plans",
                    style = TextStyle(fontSize = 15.sp, fontWeight = FontWeight.SemiBold),
                    color = colors.textPrimary,
                    modifier = Modifier.weight(1f),
                )
                Icon(
                    if (open) Icons.Default.ExpandLess else Icons.Default.ExpandMore,
                    null,
                    tint = colors.accent,
                )
            }
            if (open) {
                Column(verticalArrangement = Arrangement.spacedBy(Space.xs)) {
                    Row {
                        Spacer(Modifier.weight(1.2f))
                        compareTitles.forEach { title ->
                            Text(
                                title,
                                style = TextStyle(fontSize = 11.sp, fontWeight = FontWeight.SemiBold),
                                color = colors.textSecondary,
                                modifier = Modifier.weight(1f),
                            )
                        }
                    }
                    compareFeatures.forEach { (label, values) ->
                        Row {
                            Text(label, style = TextStyle(fontSize = 12.sp), color = colors.textPrimary, modifier = Modifier.weight(1.2f))
                            values.forEach { value ->
                                Text(value, style = TextStyle(fontSize = 12.sp), color = colors.textSecondary, modifier = Modifier.weight(1f))
                            }
                        }
                    }
                }
            }
        }
    }
}
