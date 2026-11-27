// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
package ai.tokenstat.tokenstat.ui.components

import ai.tokenstat.tokenstat.ui.localization.L10n

import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.size
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Check
import androidx.compose.material3.Icon
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import ai.tokenstat.tokenstat.ui.theme.LocalTsColors
import ai.tokenstat.tokenstat.ui.theme.Space

enum class FieldSaveState {
    Idle,
    Dirty,
    Saving,
    Saved,
    Failed,
}

fun saveStateLabel(state: FieldSaveState): String? = when (state) {
    FieldSaveState.Idle -> null
    FieldSaveState.Dirty -> L10n.text("android.fieldsavebar.unsaved.6250d572")
    FieldSaveState.Saving -> L10n.text("android.fieldsavebar.saving.096b7362")
    FieldSaveState.Saved -> L10n.text("android.fieldsavebar.saved.b5c120b3")
    FieldSaveState.Failed -> L10n.text("android.fieldsavebar.not_saved.22b3467c")
}

fun saveBarShowsActions(state: FieldSaveState): Boolean =
    state == FieldSaveState.Dirty || state == FieldSaveState.Failed

@Composable
fun FieldSaveBar(
    state: FieldSaveState,
    onSave: () -> Unit,
    onCancel: () -> Unit,
    modifier: Modifier = Modifier,
    saveTitle: String = L10n.text("common.save"),
    canSave: Boolean = true,
) {
    val colors = LocalTsColors.current
    Row(
        modifier.semantics { contentDescription = saveStateLabel(state) ?: "" },
        horizontalArrangement = Arrangement.spacedBy(Space.s),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        when (state) {
            FieldSaveState.Idle -> Unit
            FieldSaveState.Dirty -> Text(
                L10n.text("android.fieldsavebar.unsaved.6250d572"),
                style = TsType.caption.copy(fontWeight = FontWeight.Medium),
                color = colors.warning,
            )
            FieldSaveState.Saving -> Row(
                horizontalArrangement = Arrangement.spacedBy(6.dp),
                verticalAlignment = Alignment.CenterVertically,
            ) {
                CircularProgressIndicator(
                    modifier = Modifier.size(12.dp),
                    strokeWidth = 1.5.dp,
                    color = colors.textSecondary,
                )
                Text(L10n.text("android.fieldsavebar.saving.096b7362"), style = TsType.caption, color = colors.textSecondary)
            }
            FieldSaveState.Saved -> Row(
                horizontalArrangement = Arrangement.spacedBy(4.dp),
                verticalAlignment = Alignment.CenterVertically,
            ) {
                Icon(Icons.Filled.Check, null, tint = colors.success, modifier = Modifier.size(12.dp))
                Text(
                    L10n.text("android.fieldsavebar.saved.b5c120b3"),
                    style = TsType.caption.copy(fontWeight = FontWeight.Medium),
                    color = colors.success,
                )
            }
            FieldSaveState.Failed -> Text(
                L10n.text("android.fieldsavebar.not_saved.22b3467c"),
                style = TsType.caption.copy(fontWeight = FontWeight.Medium),
                color = colors.danger,
            )
        }
        Spacer(Modifier.weight(1f))
        if (saveBarShowsActions(state)) {
            TsSecondaryButton(label = L10n.text("common.cancel"), onClick = onCancel, small = true)
            TsAccentButton(
                label = saveTitle,
                onClick = onSave,
                small = true,
                enabled = canSave && state != FieldSaveState.Saving,
            )
        }
    }
}
