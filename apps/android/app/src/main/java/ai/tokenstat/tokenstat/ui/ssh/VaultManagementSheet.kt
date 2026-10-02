// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
package ai.tokenstat.tokenstat.ui.ssh

import ai.tokenstat.tokenstat.ui.components.Banner
import ai.tokenstat.tokenstat.ui.components.BannerSeverity
import ai.tokenstat.tokenstat.ui.components.TsAccentButton
import ai.tokenstat.tokenstat.ui.components.TsDangerButton
import ai.tokenstat.tokenstat.ui.components.TsSecondaryButton
import ai.tokenstat.tokenstat.ui.components.TsType
import ai.tokenstat.tokenstat.ui.localization.L10n
import ai.tokenstat.tokenstat.ui.theme.LocalTsColors
import ai.tokenstat.tokenstat.ui.theme.Space
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxHeight
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.ModalBottomSheet
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.material3.rememberModalBottomSheetState
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.booleanOrNull
import kotlinx.serialization.json.contentOrNull
import kotlinx.serialization.json.intOrNull

/** One shared status from the library, with operations owned by that screen. */
@Composable
@OptIn(ExperimentalMaterial3Api::class)
internal fun VaultManagementSheet(
    status: JsonObject?,
    canWrite: Boolean,
    unconfirmedRecovery: Boolean,
    busy: Boolean,
    syncing: Boolean,
    error: String?,
    syncError: String?,
    onDismiss: () -> Unit,
    onSetup: () -> Unit,
    onSync: () -> Unit,
    onShowRecovery: () -> Unit,
    onDiscard: (() -> Unit)?,
    onDelete: () -> Unit,
    onRetry: () -> Unit,
    onPlans: () -> Unit,
) {
    val colors = LocalTsColors.current
    val created = (status?.get("created") as? JsonPrimitive)?.booleanOrNull == true
    val locked = (status?.get("locked") as? JsonPrimitive)?.booleanOrNull == true
    val enrolled = (status?.get("enrolled") as? JsonPrimitive)?.booleanOrNull == true
    val count = (status?.get("recordCount") as? JsonPrimitive)?.intOrNull ?: 0
    val unreachable = (status?.get("unreachable") as? JsonPrimitive)?.contentOrNull?.takeIf { it.isNotBlank() }
    val available = !busy && !syncing
    ModalBottomSheet(
        onDismissRequest = onDismiss,
        sheetState = rememberModalBottomSheetState(skipPartiallyExpanded = true),
        modifier = Modifier.fillMaxHeight(0.94f),
        containerColor = colors.background,
    ) {
        Column(Modifier.fillMaxSize()) {
            // Keep the way out visible while the decisions below scroll.
            Row(
                Modifier.fillMaxWidth().padding(start = Space.l, end = Space.s, bottom = Space.s),
                verticalAlignment = Alignment.CenterVertically,
                horizontalArrangement = Arrangement.spacedBy(Space.s),
            ) {
                Text(
                    L10n.text("android.vaultlockcache.encrypted_vault.31939e06"),
                    style = TsType.title,
                    color = colors.textPrimary,
                    modifier = Modifier.weight(1f),
                )
                TextButton(onClick = onDismiss) { Text(L10n.text("common.done")) }
            }
            HorizontalDivider(color = colors.border)
            Column(
                Modifier.weight(1f).fillMaxWidth().verticalScroll(rememberScrollState())
                    .padding(Space.l),
                verticalArrangement = Arrangement.spacedBy(Space.l),
            ) {
                Text(L10n.text("android.vaultmanagement.subtitle"), style = TsType.caption, color = colors.textSecondary)
                error?.let { Banner(it, BannerSeverity.DANGER) }
                syncError?.let { Banner(it, BannerSeverity.WARNING) }
                if (unconfirmedRecovery) {
                    VaultManagementAction(
                        title = L10n.text("android.vaultlockcache.recovery_code_not_confirmed.dc3c61fd"),
                        detail = L10n.text("android.vaultlockcache.the_code_has_been_generated_but_not_writte.e121ffb4"),
                        button = L10n.text("android.tokenstatapp.show_code.c9eab29c"),
                        enabled = available,
                        prominent = true,
                        onClick = onShowRecovery,
                    )
                }
                when {
                    status == null -> {
                        Text(L10n.text("android.vaultmanagement.loading"), style = TsType.body, color = colors.textSecondary)
                        if (error != null) TsSecondaryButton(
                            label = L10n.text("android.vaultmanagement.try_again"),
                            onClick = onRetry,
                            enabled = available,
                            modifier = Modifier.fillMaxWidth(),
                        )
                    }
                    unreachable != null -> {
                        Banner(unreachable, BannerSeverity.WARNING)
                        VaultManagementAction(
                            title = L10n.text("android.vaultmanagement.unreachable_title"),
                            detail = L10n.text("android.vaultmanagement.unreachable_detail"),
                            button = L10n.text("android.vaultmanagement.try_again"),
                            enabled = available,
                            prominent = true,
                            onClick = onRetry,
                        )
                    }
                    !created && canWrite -> VaultManagementAction(
                        title = L10n.text("android.vaultmanagement.setup_title"),
                        detail = L10n.text("android.tokenstatapp.one_password_protects_every_saved_server_a.8bb557dc"),
                        button = L10n.text("android.tokenstatapp.set_up.4da10f1f"),
                        enabled = available,
                        prominent = true,
                        onClick = onSetup,
                    )
                    !created -> VaultManagementAction(
                        title = L10n.text("android.vaultmanagement.not_syncing_title"),
                        detail = L10n.text("android.vaultmanagement.not_syncing_detail"),
                        button = L10n.text("android.tokenstatapp.see_plans.d9898933"),
                        enabled = available,
                        prominent = true,
                        onClick = onPlans,
                    )
                    locked || !enrolled -> VaultManagementAction(
                        title = L10n.text("android.tokenstatapp.unlock_your_vault.67a7b04b"),
                        detail = L10n.text("android.vaultmanagement.unlock_detail"),
                        button = L10n.text("android.tokenstatapp.unlock.4ac709aa"),
                        enabled = available,
                        prominent = true,
                        onClick = onSetup,
                    )
                    else -> {
                        Column(verticalArrangement = Arrangement.spacedBy(Space.xs)) {
                            Text(
                                if (count == 1) L10n.text("android.vaultmanagement.one_record")
                                else L10n.text("android.vaultlockcache.0_records.2cd6fd62", count),
                                style = TsType.body,
                                color = colors.textPrimary,
                            )
                            Text(
                                if (canWrite) L10n.text("android.vaultmanagement.ready_detail")
                                else L10n.text("android.vaultmanagement.read_only_detail"),
                                style = TsType.caption,
                                color = colors.textSecondary,
                            )
                        }
                        if (canWrite) VaultManagementAction(
                            title = L10n.text("common.sync_now"),
                            detail = L10n.text("android.vaultmanagement.sync_detail"),
                            button = if (syncing) L10n.text("android.vaultmanagement.syncing") else L10n.text("common.sync_now"),
                            enabled = available && !unconfirmedRecovery,
                            onClick = onSync,
                        ) else VaultManagementAction(
                            title = L10n.text("android.vaultmanagement.not_syncing_title"),
                            detail = L10n.text("android.vaultmanagement.not_syncing_detail"),
                            button = L10n.text("android.tokenstatapp.see_plans.d9898933"),
                            enabled = available,
                            prominent = true,
                            onClick = onPlans,
                        )
                    }
                }
                // Recovery from an existing vault never gets the shortcut
                // that discards a newly created one. Typed Delete stays here.
                if (unconfirmedRecovery && onDiscard != null) {
                    HorizontalDivider(color = colors.border)
                    VaultManagementAction(
                        title = L10n.text("android.tokenstatapp.discard_vault.cea8fd68"),
                        detail = L10n.text("android.vaultmanagement.discard_detail"),
                        button = L10n.text("android.tokenstatapp.discard_vault.cea8fd68"),
                        enabled = available,
                        destructive = true,
                        onClick = onDiscard,
                    )
                } else if (created || unreachable != null) {
                    HorizontalDivider(color = colors.border)
                    VaultManagementAction(
                        title = L10n.text("android.tokenstatapp.delete_the_vault_and_start_over.e49d06f1"),
                        detail = L10n.text("android.vaultmanagement.delete_detail"),
                        button = L10n.text("android.tokenstatapp.delete_vault.9fd7de76"),
                        enabled = available,
                        destructive = true,
                        onClick = onDelete,
                    )
                }
            }
        }
    }
}

@Composable
private fun VaultManagementAction(
    title: String,
    detail: String,
    button: String,
    enabled: Boolean,
    prominent: Boolean = false,
    destructive: Boolean = false,
    onClick: () -> Unit,
) {
    val colors = LocalTsColors.current
    Column(Modifier.fillMaxWidth(), verticalArrangement = Arrangement.spacedBy(Space.s)) {
        Text(title, style = TsType.body, color = colors.textPrimary)
        Text(detail, style = TsType.caption, color = colors.textSecondary)
        when {
            destructive -> TsDangerButton(button, onClick, Modifier.fillMaxWidth(), enabled = enabled)
            prominent -> TsAccentButton(button, onClick, Modifier.fillMaxWidth(), enabled = enabled)
            else -> TsSecondaryButton(button, onClick, Modifier.fillMaxWidth(), enabled = enabled)
        }
    }
}
