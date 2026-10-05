// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
package ai.tokenstat.tokenstat.ui.ssh

import ai.tokenstat.tokenstat.ui.components.ActionIcon
import ai.tokenstat.tokenstat.ui.components.EmptyState
import ai.tokenstat.tokenstat.ui.components.TsAccentButton
import ai.tokenstat.tokenstat.ui.components.TsSecondaryButton
import ai.tokenstat.tokenstat.ui.localization.L10n
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.ui.Modifier
import ai.tokenstat.tokenstat.ui.theme.Space
import androidx.compose.runtime.Composable

/** The library's next step stays next to its search and Add controls. */
@Composable
internal fun SshLibraryEmptyState(
    tab: Int,
    tabName: String,
    onAdd: () -> Unit,
    modifier: Modifier = Modifier,
    query: String = "",
    onClearSearch: () -> Unit = {},
) {
    val searching = query.isNotBlank()
    Column(modifier.fillMaxWidth().verticalScroll(rememberScrollState()).padding(horizontal = Space.l)) {
        EmptyState(
            icon = if (searching) ActionIcon.Search.vector else when (tab) {
                0 -> ActionIcon.Device.vector
                1 -> ActionIcon.Token.vector
                else -> ActionIcon.Docs.vector
            },
            title = if (searching) L10n.text("android.sshlibrary.no_matches")
                else L10n.text("android.tokenstatapp.no_0_yet.91be7356", tabName.lowercase()),
            message = if (searching) L10n.text("android.sshlibrary.search_detail") else when (tab) {
                0 -> L10n.text("android.tokenstatapp.save_a_server_address_and_choose_authentic.268fdc9a")
                1 -> L10n.text("android.tokenstatapp.generated_and_imported_keys_are_protected.1a42622f")
                else -> L10n.text("android.tokenstatapp.save_commands_you_use_often.27b06324")
            },
            action = {
                if (searching) TsSecondaryButton(
                    label = L10n.text("android.sshlibrary.clear_search"),
                    icon = ActionIcon.Dismiss.vector,
                    onClick = onClearSearch,
                ) else TsAccentButton(
                    label = L10n.text("android.tokenstatapp.add_0.882c2180", tabName.lowercase().trimEnd('s')),
                    icon = ActionIcon.Create.vector,
                    onClick = onAdd,
                )
            },
        )
    }
}
