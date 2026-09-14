// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
package ai.tokenstat.tokenstat.ui.components

import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.interaction.MutableInteractionSource
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.BasicTextField
import androidx.compose.foundation.text.KeyboardActions
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.material3.Icon
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.remember
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.text.input.KeyboardCapitalization
import androidx.compose.ui.unit.dp
import ai.tokenstat.tokenstat.ui.theme.LocalTsColors
import ai.tokenstat.tokenstat.ui.theme.Space

/// The filter field, shared so every panel's search looks like the same
/// control rather than whatever each screen invented. Ported from
/// `PickerSearchField` in `Sources/Design/SearchablePicker.swift`: a
/// magnifier, the prompt, and a clear button that appears only while there
/// is something to clear. The field never capitalizes or autocorrects, so a
/// branch name or model id stays exactly as typed.
@Composable
fun TsSearchField(
    prompt: String,
    query: String,
    onQueryChange: (String) -> Unit,
    modifier: Modifier = Modifier,
    onSubmit: () -> Unit = {},
) {
    val colors = LocalTsColors.current
    val shape = RoundedCornerShape(Space.s)
    Row(
        modifier
            .clip(shape)
            .background(colors.background)
            .border(1.dp, colors.border, shape)
            .padding(horizontal = Space.s)
            .heightIn(min = 44.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        Icon(ActionIcon.Search.vector, null, tint = colors.textTertiary)
        Box(Modifier.weight(1f).padding(horizontal = Space.s)) {
            BasicTextField(
                value = query,
                onValueChange = onQueryChange,
                modifier = Modifier,
                textStyle = TsType.body.copy(color = colors.textPrimary),
                singleLine = true,
                keyboardOptions = KeyboardOptions(
                    capitalization = KeyboardCapitalization.None,
                    autoCorrectEnabled = false,
                ),
                keyboardActions = KeyboardActions(onDone = { onSubmit() }),
                decorationBox = { inner ->
                    if (query.isEmpty()) {
                        Text(prompt, style = TsType.body, color = colors.textTertiary, maxLines = 1)
                    }
                    inner()
                },
            )
        }
        if (query.isNotEmpty()) {
            Icon(
                ActionIcon.Dismiss.vector,
                "Clear filter",
                tint = colors.textTertiary,
                modifier = Modifier
                    .padding(vertical = Space.xs)
                    .clickable(
                        indication = null,
                        interactionSource = remember { MutableInteractionSource() },
                    ) { onQueryChange("") },
            )
        }
    }
}
