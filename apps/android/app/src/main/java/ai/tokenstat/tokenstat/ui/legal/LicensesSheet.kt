// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
package ai.tokenstat.tokenstat.ui.legal

import ai.tokenstat.tokenstat.ui.localization.L10n

import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.text.selection.SelectionContainer
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.Icon
import androidx.compose.material3.ModalBottomSheet
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.TextStyle
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import ai.tokenstat.tokenstat.ui.components.ActionIcon
import ai.tokenstat.tokenstat.ui.marks.FeatureMark
import ai.tokenstat.tokenstat.ui.components.TsAccentButton
import ai.tokenstat.tokenstat.ui.components.TsCard
import ai.tokenstat.tokenstat.ui.components.TsType
import ai.tokenstat.tokenstat.ui.theme.LocalTsColors
import ai.tokenstat.tokenstat.ui.theme.Space
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext

/// The Legal pane's licenses card: what the sheet holds and the way in.
@Composable
fun LicensesCard(onOpen: () -> Unit) {
    val colors = LocalTsColors.current
    TsCard {
        Column(verticalArrangement = Arrangement.spacedBy(Space.s)) {
            Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(Space.s)) {
                FeatureMark("mark_license", size = 22)
                Text(
                    L10n.text("android.licensessheet.open_source_licenses.1a1b83db"),
                    style = TextStyle(fontSize = 15.sp, fontWeight = FontWeight.SemiBold),
                    color = colors.textPrimary,
                )
            }
            Text(
                L10n.text("android.licensessheet.third_party_notices_for_the_libraries_bund.6e6b4668"),
                style = TsType.body,
                color = colors.textSecondary,
            )
            TsAccentButton(
                label = L10n.text("android.licensessheet.view_licenses.84534935"),
                icon = ActionIcon.Docs.vector,
                onClick = onOpen,
                modifier = Modifier.fillMaxWidth(),
            )
        }
    }
}

/// The generated notices file, read lazily in a monospaced selectable view.
/// A port of iOS `ClientLicensesSheet`, including its missing-file copy.
@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun LicensesSheet(onDismiss: () -> Unit) {
    val colors = LocalTsColors.current
    val context = LocalContext.current
    var text by remember { mutableStateOf<String?>(null) }
    var loadFailed by remember { mutableStateOf(false) }
    LaunchedEffect(Unit) {
        text = withContext(Dispatchers.IO) {
            runCatching {
                context.assets.open("THIRD_PARTY_NOTICES.md").bufferedReader().readText()
            }.getOrNull()
        }
        loadFailed = text == null
    }
    ModalBottomSheet(onDismissRequest = onDismiss, containerColor = colors.background) {
        Column(
            Modifier.fillMaxWidth().padding(horizontal = Space.l).padding(bottom = Space.xl),
            verticalArrangement = Arrangement.spacedBy(Space.m),
        ) {
            Row(verticalAlignment = Alignment.CenterVertically) {
                Text(
                    L10n.text("android.licensessheet.open_source_licenses.1a1b83db"),
                    style = TextStyle(fontSize = 17.sp, fontWeight = FontWeight.SemiBold),
                    color = colors.textPrimary,
                    modifier = Modifier.weight(1f),
                )
                TextButton(onClick = onDismiss) { Text(L10n.text("common.done")) }
            }
            when {
                text != null -> SelectionContainer {
                    Text(
                        text.orEmpty(),
                        style = TsType.mono(12),
                        color = colors.textPrimary,
                        modifier = Modifier
                            .weight(1f, fill = false)
                            .verticalScroll(rememberScrollState()),
                    )
                }
                loadFailed -> Text(
                    L10n.text("android.licensessheet.the_third_party_notices_are_generated_at_b.4594fa7d"),
                    style = TsType.body,
                    color = colors.textSecondary,
                )
                else -> CircularProgressIndicator()
            }
        }
    }
}
