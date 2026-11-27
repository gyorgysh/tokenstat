// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
package ai.tokenstat.tokenstat.ui.components

import ai.tokenstat.tokenstat.ui.localization.L10n

import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.ExperimentalLayoutApi
import androidx.compose.foundation.layout.FlowRow
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.semantics.selected
import androidx.compose.ui.semantics.toggleableState
import androidx.compose.ui.state.ToggleableState
import androidx.compose.ui.draw.clip
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import ai.tokenstat.tokenstat.ui.theme.LocalTsColors
import ai.tokenstat.tokenstat.ui.theme.Space

val TIME_LIMIT_PRESETS = listOf(15 to "15m", 30 to "30m", 60 to "1h", 180 to "3h", 480 to "8h")

fun selectedTimeLimitPreset(minutesText: String, noLimit: Boolean): Int? {
    if (noLimit) return null
    val minutes = minutesText.toIntOrNull() ?: return null
    return TIME_LIMIT_PRESETS.firstOrNull { it.first == minutes }?.first
}

val CONCURRENT_PRESETS = listOf(1u to "1", 2u to "2", 4u to "4", 8u to "8")

fun isConcurrentUncapped(countText: String): Boolean =
    (countText.trim().toUIntOrNull() ?: 1u) == 0u

fun selectedConcurrentPreset(countText: String): UInt? {
    if (isConcurrentUncapped(countText)) return null
    val count = countText.trim().toUIntOrNull() ?: return null
    return CONCURRENT_PRESETS.firstOrNull { it.first == count }?.first
}

@Composable
fun ChoiceChip(title: String, isSelected: Boolean, onSelect: () -> Unit, modifier: Modifier = Modifier) {
    if (isSelected) {
        TsAccentButton(label = title, onClick = onSelect, modifier = modifier.semantics { selected = isSelected }, small = true)
    } else {
        TsSecondaryButton(label = title, onClick = onSelect, modifier = modifier.semantics { selected = isSelected }, small = true)
    }
}

@Composable
fun BrandToggleChip(title: String, isOn: Boolean, onToggle: () -> Unit, modifier: Modifier = Modifier) {
    ChoiceChip(title = title, isSelected = isOn, onSelect = onToggle, modifier = modifier.semantics { toggleableState = ToggleableState(isOn) })
}

@OptIn(ExperimentalLayoutApi::class)
@Composable
fun TimeLimitChips(
    minutesText: String,
    noLimit: Boolean,
    onMinutesChange: (String) -> Unit,
    onNoLimitChange: (Boolean) -> Unit,
    modifier: Modifier = Modifier,
    onChange: () -> Unit = {},
) {
    FlowRow(
        modifier = modifier,
        horizontalArrangement = Arrangement.spacedBy(Space.s),
        verticalArrangement = Arrangement.spacedBy(Space.s),
    ) {
        TIME_LIMIT_PRESETS.forEach { (minutes, title) ->
            ChoiceChip(
                title = title,
                isSelected = !noLimit && (minutesText.toIntOrNull() ?: 0) == minutes,
                onSelect = {
                    onNoLimitChange(false)
                    onMinutesChange(minutes.toString())
                    onChange()
                },
            )
        }
        ChoiceChip(
            title = L10n.text("android.tschips.no_limit.f7fcff0d"),
            isSelected = noLimit,
            onSelect = {
                onNoLimitChange(true)
                onChange()
            },
        )
    }
}

@OptIn(ExperimentalLayoutApi::class)
@Composable
fun ConcurrentChips(
    countText: String,
    onCountChange: (String) -> Unit,
    modifier: Modifier = Modifier,
    onChange: () -> Unit = {},
) {
    FlowRow(
        modifier = modifier,
        horizontalArrangement = Arrangement.spacedBy(Space.s),
        verticalArrangement = Arrangement.spacedBy(Space.s),
    ) {
        CONCURRENT_PRESETS.forEach { (count, title) ->
            ChoiceChip(
                title = title,
                isSelected = !isConcurrentUncapped(countText) && countText.trim().toUIntOrNull() == count,
                onSelect = {
                    onCountChange(count.toString())
                    onChange()
                },
            )
        }
        ChoiceChip(
            title = L10n.text("android.tschips.no_cap.59db2115"),
            isSelected = isConcurrentUncapped(countText),
            onSelect = {
                onCountChange("0")
                onChange()
            },
        )
    }
}

@OptIn(ExperimentalLayoutApi::class)
@Composable
fun CommitTagPills(tags: List<String>, modifier: Modifier = Modifier) {
    if (tags.isEmpty()) return
    val colors = LocalTsColors.current
    FlowRow(
        modifier = modifier,
        horizontalArrangement = Arrangement.spacedBy(Space.xs),
        verticalArrangement = Arrangement.spacedBy(Space.xs),
    ) {
        tags.forEach { tag ->
            Row(
                Modifier
                    .clip(RoundedCornerShape(50))
                    .background(colors.accentSoft)
                    .padding(horizontal = 6.dp, vertical = 2.dp),
                verticalAlignment = Alignment.CenterVertically,
            ) {
                Text(
                    tag,
                    style = TsType.mono(10, FontWeight.Medium),
                    color = colors.accent,
                    maxLines = 1,
                    overflow = TextOverflow.Ellipsis,
                )
            }
        }
    }
}
