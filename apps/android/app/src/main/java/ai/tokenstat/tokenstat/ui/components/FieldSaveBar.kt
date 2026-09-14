// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
package ai.tokenstat.tokenstat.ui.components

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

/// Whether an editable field has something waiting to be written. Ported
/// from `FieldSaveState` in `Sources/Design/Theme.swift`, same five states
/// in the same order.
enum class FieldSaveState {
    Idle,
    Dirty,
    Saving,
    Saved,
    Failed,
}

/// The status word the bar shows for a state, or null when the bar shows
/// nothing. Same copy as the Apple status view: Unsaved, Saving, Saved,
/// and Not saved for a failure.
fun saveStateLabel(state: FieldSaveState): String? = when (state) {
    FieldSaveState.Idle -> null
    FieldSaveState.Dirty -> "Unsaved"
    FieldSaveState.Saving -> "Saving"
    FieldSaveState.Saved -> "Saved"
    FieldSaveState.Failed -> "Not saved"
}

/// Whether the Save and Cancel buttons are on screen. Ported from
/// `FieldSaveBar`: implicit blur-save hid failures, so the buttons stay
/// visible exactly while there is something unwritten or a write that
/// failed.
fun saveBarShowsActions(state: FieldSaveState): Boolean =
    state == FieldSaveState.Dirty || state == FieldSaveState.Failed

/// Unsaved / Saving / Saved next to Save and Cancel. A card that looks
/// finished after a keystroke, then reverts later, is worse than a button
/// that says it wrote.
@Composable
fun FieldSaveBar(
    state: FieldSaveState,
    onSave: () -> Unit,
    onCancel: () -> Unit,
    modifier: Modifier = Modifier,
    saveTitle: String = "Save",
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
                "Unsaved",
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
                Text("Saving", style = TsType.caption, color = colors.textSecondary)
            }
            FieldSaveState.Saved -> Row(
                horizontalArrangement = Arrangement.spacedBy(4.dp),
                verticalAlignment = Alignment.CenterVertically,
            ) {
                Icon(Icons.Filled.Check, null, tint = colors.success, modifier = Modifier.size(12.dp))
                Text(
                    "Saved",
                    style = TsType.caption.copy(fontWeight = FontWeight.Medium),
                    color = colors.success,
                )
            }
            FieldSaveState.Failed -> Text(
                "Not saved",
                style = TsType.caption.copy(fontWeight = FontWeight.Medium),
                color = colors.danger,
            )
        }
        Spacer(Modifier.weight(1f))
        if (saveBarShowsActions(state)) {
            TsSecondaryButton(label = "Cancel", onClick = onCancel, small = true)
            TsAccentButton(
                label = saveTitle,
                onClick = onSave,
                small = true,
                enabled = canSave && state != FieldSaveState.Saving,
            )
        }
    }
}
