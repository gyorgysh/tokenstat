// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
package ai.tokenstat.tokenstat.ui.components

import ai.tokenstat.tokenstat.ui.localization.L10n
import ai.tokenstat.tokenstat.ui.theme.LocalTsColors
import androidx.compose.foundation.layout.WindowInsets
import androidx.compose.foundation.layout.ime
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.runtime.Composable
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.platform.LocalFocusManager
import androidx.compose.ui.platform.LocalSoftwareKeyboardController

/** Dismiss input without clearing text, submitting or leaving the screen. */
@Composable
fun KeyboardDismissButton(modifier: Modifier = Modifier) {
    val keyboard = LocalSoftwareKeyboardController.current
    val focus = LocalFocusManager.current
    if (WindowInsets.ime.getBottom(LocalDensity.current) > 0) {
        IconButton(
            onClick = { keyboard?.hide(); focus.clearFocus() },
            modifier = modifier,
        ) {
            Icon(
                ActionIcon.HideKeyboard.vector,
                L10n.text("android.terminalscreen.hide_keyboard.f6b0718e"),
                tint = LocalTsColors.current.accent,
            )
        }
    }
}
