// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
package ai.tokenstat.tokenstat.ui.ssh

import ai.tokenstat.tokenstat.ui.marks.distroBrandRes
import ai.tokenstat.tokenstat.ui.theme.LocalTsColors
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Dns
import androidx.compose.material3.Icon
import androidx.compose.runtime.Composable
import androidx.compose.runtime.remember
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.res.painterResource
import androidx.compose.ui.unit.dp

/// A distribution's own mark on a tinted tile, or a neutral server glyph.
///
/// Port of `SSHHostPlatformMark`. Vendor marks, not ours: the drawables are
/// the same Simple Icons renditions (CC0) the Apple client ships, used only to
/// identify the OS the host itself reported. Anything without a bundled mark
/// gets the server glyph, because a wrong logo is worse than no logo. Never
/// an invented initial.
@Composable
fun SshHostMark(platformLabel: String?) {
    val colors = LocalTsColors.current
    val res = remember(platformLabel) { distroBrandRes(platformLabel, platformLabel) }
    Box(
        Modifier
            .size(34.dp)
            .clip(RoundedCornerShape(9.dp))
            .background(colors.accentSoft),
        contentAlignment = Alignment.Center,
    ) {
        if (res != 0) {
            Icon(
                painterResource(res),
                contentDescription = null,
                tint = colors.accent,
                modifier = Modifier.size(19.dp),
            )
        } else {
            Icon(
                Icons.Default.Dns,
                contentDescription = null,
                tint = colors.accent,
                modifier = Modifier.size(18.dp),
            )
        }
    }
}
