// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
package ai.tokenstat.tokenstat.ui.components

import ai.tokenstat.tokenstat.ui.localization.L10n
import ai.tokenstat.tokenstat.ui.theme.LocalTsColors
import ai.tokenstat.tokenstat.ui.theme.Space
import androidx.compose.foundation.layout.BoxWithConstraints
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.ColumnScope
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.imePadding
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.safeDrawingPadding
import androidx.compose.foundation.layout.WindowInsets
import androidx.compose.foundation.layout.ime
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.SideEffect
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.platform.LocalView
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.unit.dp
import androidx.compose.ui.semantics.paneTitle
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.window.Dialog
import androidx.compose.ui.window.DialogProperties
import androidx.compose.ui.window.DialogWindowProvider
import androidx.core.view.WindowCompat

/** A phone form owns its whole surface, with actions kept clear of the keyboard. */
@Composable
internal fun TsModalScreen(
    title: String,
    onDismiss: () -> Unit,
    subtitle: String = "",
    dismissEnabled: Boolean = true,
    footer: (@Composable ColumnScope.() -> Unit)? = null,
    content: @Composable ColumnScope.() -> Unit,
) {
    val colors = LocalTsColors.current
    Dialog(
        onDismissRequest = { if (dismissEnabled) onDismiss() },
        properties = DialogProperties(usePlatformDefaultWidth = false, decorFitsSystemWindows = false),
    ) {
        val view = LocalView.current
        SideEffect {
            val window = (view.parent as? DialogWindowProvider)?.window
            if (window != null) {
                WindowCompat.getInsetsController(window, view).apply {
                    isAppearanceLightStatusBars = !colors.isDark
                    isAppearanceLightNavigationBars = !colors.isDark
                }
            }
        }
        Surface(Modifier.fillMaxSize().testTag("modal-screen").semantics { paneTitle = title }, color = colors.background) {
            val keyboardVisible = WindowInsets.ime.getBottom(LocalDensity.current) > 0
            BoxWithConstraints(Modifier.fillMaxSize().safeDrawingPadding().imePadding()) {
                // With a tall keyboard, keep the action and a way out ahead of the title.
                val compact = footer != null && keyboardVisible && maxHeight < 200.dp
                Column(Modifier.fillMaxSize()) {
                    if (!compact) {
                        Row(
                            Modifier.fillMaxWidth().padding(start = Space.l, end = Space.s, top = Space.s, bottom = Space.s),
                            verticalAlignment = Alignment.CenterVertically,
                        ) {
                            Column(Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(Space.xs)) {
                                Text(title, style = TsType.title3, color = colors.textPrimary)
                                if (subtitle.isNotBlank()) Text(subtitle, style = TsType.caption, color = colors.textSecondary)
                            }
                            IconButton(onClick = onDismiss, enabled = dismissEnabled) {
                                Icon(ActionIcon.Dismiss.vector, L10n.text("common.close"), tint = if (dismissEnabled) colors.textPrimary else colors.textTertiary)
                            }
                        }
                        HorizontalDivider(color = colors.border)
                    }
                    Column(
                        Modifier.weight(1f).fillMaxWidth().verticalScroll(rememberScrollState())
                            .padding(horizontal = Space.l, vertical = if (compact) Space.xs else Space.l),
                        verticalArrangement = Arrangement.spacedBy(Space.m),
                        content = content,
                    )
                    if (footer != null) {
                        HorizontalDivider(color = colors.border)
                        Row(
                            Modifier.fillMaxWidth().padding(if (compact) Space.xs else Space.l).testTag("modal-actions"),
                            verticalAlignment = Alignment.CenterVertically,
                            horizontalArrangement = Arrangement.spacedBy(Space.s),
                        ) {
                            if (compact) IconButton(onClick = onDismiss, enabled = dismissEnabled) {
                                Icon(ActionIcon.Dismiss.vector, L10n.text("common.close"), tint = if (dismissEnabled) colors.textPrimary else colors.textTertiary)
                            }
                            Column(Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(Space.s), content = footer)
                        }
                    }
                }
            }
        }
    }
}
