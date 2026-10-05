// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
package ai.tokenstat.tokenstat.ui.ssh

import ai.tokenstat.tokenstat.ui.components.ActionIcon
import ai.tokenstat.tokenstat.ui.components.Banner
import ai.tokenstat.tokenstat.ui.components.BannerSeverity
import ai.tokenstat.tokenstat.ui.components.TsAccentButton
import ai.tokenstat.tokenstat.ui.components.TsDangerButton
import ai.tokenstat.tokenstat.ui.components.TsModalScreen
import ai.tokenstat.tokenstat.ui.components.TsSecondaryButton
import ai.tokenstat.tokenstat.ui.components.TsType
import ai.tokenstat.tokenstat.ui.localization.L10n
import ai.tokenstat.tokenstat.ui.logic.vaultPasswordProblems
import ai.tokenstat.tokenstat.ui.theme.LocalTsColors
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.text.input.ImeAction
import androidx.compose.ui.text.input.KeyboardType
import androidx.compose.ui.text.input.PasswordVisualTransformation

@Composable
internal fun VaultPasswordDialog(
    existing: Boolean,
    working: Boolean,
    error: String?,
    onDismiss: () -> Unit,
    onCreate: (String) -> Unit,
    onUnlock: (String) -> Unit,
    onReset: (String, String) -> Unit,
    onDrop: () -> Unit,
) {
    var password by remember(existing) { mutableStateOf("") }
    var confirm by remember(existing) { mutableStateOf("") }
    var recovery by remember(existing) { mutableStateOf("") }
    var forgot by remember(existing) { mutableStateOf(false) }
    val colors = LocalTsColors.current
    val problems = vaultPasswordProblems(password)
    val canSubmit = when {
        !existing -> problems.isEmpty() && password == confirm
        forgot -> recovery.trim().isNotEmpty() && problems.isEmpty() && password == confirm
        else -> password.isNotEmpty()
    }
    TsModalScreen(
        title = if (existing) L10n.text("android.tokenstatapp.unlock_your_vault.67a7b04b")
        else L10n.text("android.tokenstatapp.create_your_vault.de203ed0"),
        onDismiss = onDismiss,
        dismissEnabled = !working,
        footer = {
            TsAccentButton(
                label = if (!existing) L10n.text("android.tokenstatapp.create_vault.c8c44253")
                else if (forgot) L10n.text("android.tokenstatapp.reset_password.e0edfeb3")
                else L10n.text("android.tokenstatapp.unlock.4ac709aa"),
                icon = ActionIcon.Security.vector,
                enabled = canSubmit && !working,
                modifier = Modifier.fillMaxWidth(),
                onClick = {
                    when {
                        !existing -> onCreate(password)
                        forgot -> onReset(recovery, password)
                        else -> onUnlock(password)
                    }
                },
            )
        },
    ) {
        Text(
            if (!existing) L10n.text("android.tokenstatapp.one_password_protects_every_saved_server_a.8bb557dc")
            else if (forgot) L10n.text("android.tokenstatapp.enter_your_recovery_code_and_choose_a_new.42e12740")
            else L10n.text("android.vaultmanagement.unlock_detail"),
            style = TsType.body,
            color = colors.textSecondary,
        )
        error?.let { Banner(it, BannerSeverity.DANGER) }
        if (existing && forgot) OutlinedTextField(
            value = recovery,
            onValueChange = { recovery = it },
            label = { Text(L10n.text("android.tokenstatapp.recovery_code.5bda8302")) },
            minLines = 2,
            enabled = !working,
            modifier = Modifier.fillMaxWidth().testTag("vault-recovery"),
        )
        OutlinedTextField(
            value = password,
            onValueChange = { password = it },
            label = {
                Text(if (forgot) L10n.text("android.tokenstatapp.new_password.3dd9df44")
                else L10n.text("android.tokenstatapp.vault_password.1853752f"))
            },
            visualTransformation = PasswordVisualTransformation(),
            keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Password,
                imeAction = if (existing && !forgot) ImeAction.Done else ImeAction.Next),
            singleLine = true,
            enabled = !working,
            modifier = Modifier.fillMaxWidth().testTag("vault-password"),
        )
        if (!existing || forgot) {
            OutlinedTextField(
                value = confirm,
                onValueChange = { confirm = it },
                label = { Text(L10n.text("android.tokenstatapp.type_it_again.3b2acc21")) },
                visualTransformation = PasswordVisualTransformation(),
                keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Password, imeAction = ImeAction.Done),
                singleLine = true,
                enabled = !working,
                modifier = Modifier.fillMaxWidth().testTag("vault-confirm"),
            )
            problems.forEach { Text(it, style = TsType.caption, color = colors.textSecondary) }
        }
        if (existing) {
            TsSecondaryButton(
                label = if (forgot) L10n.text("android.tokenstatapp.use_the_password_instead.8dd1f753")
                else L10n.text("android.tokenstatapp.i_forgot_the_password.c3aabb38"),
                icon = ActionIcon.Help.vector,
                modifier = Modifier.fillMaxWidth(),
                enabled = !working,
                onClick = { forgot = !forgot },
            )
            HorizontalDivider(color = colors.border)
            TsDangerButton(
                label = L10n.text("android.tokenstatapp.delete_vault.9fd7de76"),
                icon = ActionIcon.Delete.vector,
                modifier = Modifier.fillMaxWidth(),
                enabled = !working,
                onClick = onDrop,
            )
        }
    }
}
