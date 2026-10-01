// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
package ai.tokenstat.tokenstat.ui.billing

import ai.tokenstat.tokenstat.ui.localization.L10n

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
        L10n.text("android.paywallsheet.supporter.2ce6c010"),
        L10n.text("android.paywallsheet.a_year_of_heatmap_across_your_devices_encr.366cc2bf"),
        listOf(
            L10n.text("android.paywallsheet.everything_in_free.407e92c7"),
            L10n.text("android.paywallsheet.4_devices_added_up_into_one_profile.49ff8de9"),
            L10n.text("android.paywallsheet.a_year_of_history_on_your_profile_not_30_d.c88cc7eb"),
            L10n.text("android.paywallsheet.end_to_end_encrypted_ssh_vault_sync_across.cff83495"),
            L10n.text("android.paywallsheet.the_supporter_star_next_to_your_name.86fa5b88"),
        ),
        L10n.text("android.paywallsheet.connections_try_a_direct_path_first_relaye.06561ccb"),
    ),
    Pitch(
        "ai.tokenstat.patron.yearly",
        true,
        "patron",
        L10n.text("android.paywallsheet.patron.dbcd07c6"),
        L10n.text("android.paywallsheet.for_people_running_agents_on_everything_th.071758f2"),
        listOf(
            L10n.text("android.paywallsheet.everything_in_supporter.ac732c35"),
            L10n.text("android.paywallsheet.remote_management_your_other_devices_from.5c8c63a3"),
            L10n.text("android.paywallsheet.6_devices_added_up_into_one_profile.71834dc6"),
            L10n.text("android.paywallsheet.every_day_you_have_ever_synced_with_no_win.f6cd292f"),
            L10n.text("android.paywallsheet.profile_updates_every_10_minutes.c3a2c533"),
            L10n.text("android.paywallsheet.the_patron_badge_next_to_your_name.628638b8"),
        ),
        L10n.text("android.paywallsheet.connections_try_a_direct_path_first_relaye.144646ae"),
    ),
    Pitch(
        "ai.tokenstat.legend.yearly",
        true,
        "legend",
        L10n.text("android.paywallsheet.legend.7482e374"),
        L10n.text("android.paywallsheet.the_top_plan_view_and_control_your_own_scr.d61084e5"),
        listOf(
            L10n.text("android.paywallsheet.everything_in_patron.e6e965d3"),
            L10n.text("android.paywallsheet.remote_screen_viewing_and_control.5b1dad2e"),
            L10n.text("android.paywallsheet.direct_connection_first_end_to_end_encrypt.5b8aed3e"),
            L10n.text("android.paywallsheet.10_devices_added_up_into_one_profile.9d901234"),
            L10n.text("android.paywallsheet.profile_updates_every_5_minutes.eae8dc37"),
            L10n.text("android.paywallsheet.the_legend_crown_next_to_your_name.26b349fa"),
            L10n.text("android.paywallsheet.read_api_your_numbers_as_json_or_csv.c424c30d"),
            L10n.text("android.paywallsheet.first_in_line_when_something_new_lands.93cc7a6b"),
        ),
        L10n.text("android.paywallsheet.connections_try_a_direct_path_first_relaye.fa4da6d5"),
    ),
)

/// The comparison, Free included. Free is not for sale, but a plan's pitch
/// only lands when the free tier's own limits are beside it.
private val compareTitles = listOf(L10n.text("android.paywallsheet.free.f411a1fb"), L10n.text("android.paywallsheet.supporter.2ce6c010"), L10n.text("android.paywallsheet.patron.dbcd07c6"), L10n.text("android.paywallsheet.legend.7482e374"))
private val compareFeatures = listOf(
    "Devices" to listOf("2", "4", "6", "10"),
    "History" to listOf("30 days", "1 yr", L10n.text("android.paywallsheet.all.a52ace42"), L10n.text("android.paywallsheet.all.a52ace42")),
    "Terminal + SSH" to listOf(L10n.text("common.no"), L10n.text("common.no"), L10n.text("common.yes"), L10n.text("common.yes")),
    "View screen" to listOf(L10n.text("common.no"), L10n.text("common.no"), L10n.text("common.no"), L10n.text("common.yes")),
    L10n.text("android.paywallsheet.relay_traffic.250c5414") to listOf(L10n.text("android.paywallsheet.100_mib.98243968"), L10n.text("android.paywallsheet.1_gib.7dd46450"), L10n.text("android.paywallsheet.5_gib.aa5f04aa"), L10n.text("android.paywallsheet.20_gib.4488c54a")),
    "Sync" to listOf(L10n.text("android.paywallsheet.hourly.eab0cd8f"), "30 min", "10 min", "5 min"),
    "Mark" to listOf(L10n.text("android.paywallsheet.none.dc937b59"), L10n.text("android.paywallsheet.star.e357d396"), L10n.text("android.paywallsheet.badge.002474e3"), L10n.text("android.paywallsheet.crown.29968c38")),
    "Read API" to listOf(L10n.text("common.no"), L10n.text("common.no"), L10n.text("common.no"), L10n.text("common.yes")),
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
            SectionTitle(title = if (monthly) L10n.text("android.paywallsheet.monthly_plans.f804dd95") else L10n.text("android.paywallsheet.yearly_plans.e8f5b2a7"), mark = "mark_plan")
            Text(
                L10n.text("android.paywallsheet.the_app_stays_free_a_plan_unlocks_more_dev.6c61f921"),
                color = colors.textSecondary,
            )
            SegmentedCapsulePicker(
                options = listOf(
                    Triple(false, L10n.text("android.paywallsheet.yearly.6e69b59e"), null as ImageVector?),
                    Triple(true, L10n.text("android.paywallsheet.monthly.9b11f6b7"), null as ImageVector?),
                ),
                selection = monthly,
                onSelect = { monthly = it },
                modifier = Modifier.fillMaxWidth(),
            )
            Text(
                if (monthly) L10n.text("android.paywallsheet.supporter_is_yearly_only.927c1185") else L10n.text("android.paywallsheet.two_months_free_versus_monthly.4c985981"),
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
                                    product != null -> product.price + if (monthly) L10n.text("android.paywallsheet.month.38428048") else L10n.text("android.paywallsheet.year.af0dde2c")
                                    billingState.products.isEmpty() -> L10n.text("android.paywallsheet.loading_price.50992858")
                                    else -> L10n.text("android.paywallsheet.price_unavailable.6a9e657b")
                                },
                                style = TextStyle(fontSize = 13.sp, fontWeight = FontWeight.SemiBold),
                                color = colors.textSecondary,
                            )
                        }
                        if (readsCurrent) {
                            Text(L10n.text("android.paywallsheet.your_current_plan.2653f9e7"), style = TextStyle(fontSize = 13.sp), color = colors.accent)
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
                            readsCurrent -> L10n.text("android.paywallsheet.your_current_plan.2653f9e7")
                            canSwitch -> if (monthly) L10n.text("android.paywallsheet.switch_to_monthly.1ade98ed") else L10n.text("android.paywallsheet.switch_to_yearly.015b8cf3")
                            product != null -> "${pitch.title} · ${product.price}"
                            billingState.products.isEmpty() -> L10n.text("android.paywallsheet.loading_price.50992858")
                            else -> L10n.text("android.paywallsheet.price_unavailable.6a9e657b")
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
                L10n.text("android.paywallsheet.plans_renew_automatically_payment_is_charg.cc3b99e3"),
                style = TextStyle(fontSize = 12.sp),
                color = colors.textSecondary,
            )
            billingState.error?.let { Text(it, color = colors.danger) }
            TsSecondaryButton(label = L10n.text("common.close"), onClick = onDismiss, modifier = Modifier.fillMaxWidth())
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
                    L10n.text("android.paywallsheet.compare_plans.30d9abfd"),
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
