// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
package ai.tokenstat.tokenstat.ui.components

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
import androidx.compose.ui.draw.clip
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import ai.tokenstat.tokenstat.ui.theme.LocalTsColors
import ai.tokenstat.tokenstat.ui.theme.Space

/// Minutes as a choice, with the field kept for anything else.
///
/// Ported from `TimeLimitChips` in `Sources/Design/Theme.swift`: the presets
/// are the values a person actually picks, and a custom number typed into the
/// field selects none of them.
val TIME_LIMIT_PRESETS = listOf(15 to "15m", 30 to "30m", 60 to "1h", 180 to "3h", 480 to "8h")

/// Which preset the field currently holds, or null when it holds a custom
/// number. A custom number selects none of the chips, exactly like the Apple
/// original.
fun selectedTimeLimitPreset(minutesText: String, noLimit: Boolean): Int? {
    if (noLimit) return null
    val minutes = minutesText.toIntOrNull() ?: return null
    return TIME_LIMIT_PRESETS.firstOrNull { it.first == minutes }?.first
}

/// Ported from `ConcurrentChips` in `Sources/Design/Theme.swift`. 0 is a real
/// host value meaning no cap, and the chip says that in words so nobody has
/// to know the sentinel.
val CONCURRENT_PRESETS = listOf(1u to "1", 2u to "2", 4u to "4", 8u to "8")

/// Whether the field means uncapped. Unparseable text falls back to 1, the
/// same default the Apple original decodes to, so half-typed input never
/// reads as "no cap".
fun isConcurrentUncapped(countText: String): Boolean =
    (countText.trim().toUIntOrNull() ?: 1u) == 0u

/// Which preset the field currently holds, or null for a custom number or
/// the uncapped sentinel.
fun selectedConcurrentPreset(countText: String): UInt? {
    if (isConcurrentUncapped(countText)) return null
    val count = countText.trim().toUIntOrNull() ?: return null
    return CONCURRENT_PRESETS.firstOrNull { it.first == count }?.first
}

/// One option in a mutually exclusive set, in the same capsule family as the
/// action buttons. Ported from `ChoiceChip`: tapping a selected chip does
/// not deselect it. Empty is a valid state, and it comes from a value that
/// matches none of the options, not from tapping again.
@Composable
fun ChoiceChip(title: String, isSelected: Boolean, onSelect: () -> Unit, modifier: Modifier = Modifier) {
    if (isSelected) {
        TsAccentButton(label = title, onClick = onSelect, modifier = modifier, small = true)
    } else {
        TsSecondaryButton(label = title, onClick = onSelect, modifier = modifier, small = true)
    }
}

/// A two-state chip in the same capsule family as the action buttons.
/// Ported from `BrandToggleChip`: a system switch next to the accent buttons
/// is a different language on the same row, so a single flag is an on/off
/// chip and the row stays in theme.
@Composable
fun BrandToggleChip(title: String, isOn: Boolean, onToggle: () -> Unit, modifier: Modifier = Modifier) {
    ChoiceChip(title = title, isSelected = isOn, onSelect = onToggle, modifier = modifier)
}

/// Minutes as chips plus the No limit chip, wrapping like the Apple
/// `FlowLayout`.
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
            title = "No limit",
            isSelected = noLimit,
            onSelect = {
                onNoLimitChange(true)
                onChange()
            },
        )
    }
}

/// How many jobs may run at once, the same chips as the time limit.
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
            title = "No cap",
            isSelected = isConcurrentUncapped(countText),
            onSelect = {
                onCountChange("0")
                onChange()
            },
        )
    }
}

/// The tags pointing at a commit, as small pills under its subject. Ported
/// from `CommitTagPills`: usually zero or one, and empty draws nothing so
/// untagged rows read exactly as before. Text-only: the shared `ActionIcon`
/// vocabulary carries no tag glyph, so there is no mark to borrow.
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
