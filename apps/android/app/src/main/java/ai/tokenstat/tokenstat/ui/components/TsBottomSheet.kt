// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
package ai.tokenstat.tokenstat.ui.components

import ai.tokenstat.tokenstat.ui.theme.LocalTsColors
import androidx.compose.foundation.layout.ColumnScope
import androidx.compose.material3.BottomSheetDefaults
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.ModalBottomSheet
import androidx.compose.material3.ModalBottomSheetProperties
import androidx.compose.material3.SheetState
import androidx.compose.material3.rememberModalBottomSheetState
import androidx.compose.runtime.Composable
import androidx.compose.ui.graphics.Color

@OptIn(ExperimentalMaterial3Api::class)
@Composable
internal fun TsBottomSheet(
    onDismissRequest: () -> Unit,
    containerColor: Color,
    sheetState: SheetState = rememberModalBottomSheetState(),
    /// Null for a sheet whose own art runs to its top edge and draws a handle
    /// over it.
    dragHandle: (@Composable () -> Unit)? = { BottomSheetDefaults.DragHandle() },
    content: @Composable ColumnScope.() -> Unit,
) {
    val lightBars = !LocalTsColors.current.isDark
    // Sheets own their window. Match the visible app theme even on versions
    // that cannot apply an application night mode to new windows.
    ModalBottomSheet(
        onDismissRequest = onDismissRequest,
        sheetState = sheetState,
        containerColor = containerColor,
        dragHandle = dragHandle,
        properties = ModalBottomSheetProperties(
            isAppearanceLightStatusBars = lightBars,
            isAppearanceLightNavigationBars = lightBars,
        ),
        content = content,
    )
}
