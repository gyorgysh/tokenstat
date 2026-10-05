// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
package ai.tokenstat.tokenstat.ui.workspace

import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.IntrinsicSize
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxHeight
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.runtime.Composable
import androidx.compose.ui.Modifier
import ai.tokenstat.tokenstat.ui.theme.Space

/** Both directions keep the same width and height, including wrapped labels. */
@Composable
internal fun GitTransferActions(
    pull: @Composable (Modifier) -> Unit,
    push: @Composable (Modifier) -> Unit,
) {
    Row(Modifier.fillMaxWidth().height(IntrinsicSize.Min), horizontalArrangement = Arrangement.spacedBy(Space.s)) {
        pull(Modifier.weight(1f).fillMaxHeight())
        push(Modifier.weight(1f).fillMaxHeight())
    }
}
