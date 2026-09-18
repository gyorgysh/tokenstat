// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
package ai.tokenstat.tokenstat.ui.components

import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.horizontalScroll
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.widthIn
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.Icon
import androidx.compose.material3.ModalBottomSheet
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.material3.rememberModalBottomSheetState
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import ai.tokenstat.tokenstat.ui.theme.LocalTsColors
import ai.tokenstat.tokenstat.ui.theme.Space
import ai.tokenstat.tokenstat.ui.theme.rowSelected

/// A picker that opens a panel you can type into, for lists a menu cannot
/// carry. Port of `Sources/Design/SearchablePicker.swift`.
///
/// A dropdown is the right control for four efforts. It is the wrong one for
/// the forty-odd model ids an agent CLI now lists, where the only way to reach
/// `meta/muse-spark-1.3` is to read every line above it, and where a list that
/// changed a minute ago has nowhere to say so. The panel adds the two things
/// the dropdown has no room for: a filter, and a way to ask the host to look
/// again.

/// One option in a searchable picker.
///
/// `detail` is a second line, and `section` a heading. Both are optional and
/// the plain case, one flat list of labels, needs neither.
data class PickerChoice<T>(
    val value: T,
    val label: String,
    val detail: String? = null,
    val section: String = "",
) {
    /// Every word of the query has to appear somewhere in the row.
    ///
    /// Word by word rather than as one substring, so "meta 1.3" finds
    /// `meta/muse-spark-1.3` without anybody having to remember where the
    /// slashes and dashes fall in an id they did not choose.
    fun matches(query: String): Boolean {
        val words = query.split(' ', '\t', '\n').filter { it.isNotEmpty() }
        if (words.isEmpty()) return true
        val haystack = listOf(label, detail.orEmpty(), section).joinToString(" ")
        return words.all { haystack.contains(it, ignoreCase = true) }
    }
}

/// Sections in first-seen order. Grouping by map would sort them by name and
/// put Effort above Agent.
fun <T> pickerSections(choices: List<PickerChoice<T>>): List<Pair<String, List<PickerChoice<T>>>> {
    val order = mutableListOf<String>()
    val grouped = mutableMapOf<String, MutableList<PickerChoice<T>>>()
    for (choice in choices) {
        if (grouped[choice.section] == null) {
            order.add(choice.section)
            grouped[choice.section] = mutableListOf()
        }
        grouped[choice.section]?.add(choice)
    }
    return order.map { it to (grouped[it] ?: emptyList()) }
}

/// Which rows survive the filter field and the section tab.
fun <T> pickerFiltered(
    choices: List<PickerChoice<T>>,
    query: String,
    selectedSection: String,
): List<PickerChoice<T>> = choices.filter {
    it.matches(query) && (selectedSection.isEmpty() || it.section == selectedSection)
}

/// What Done on the keyboard takes, which is what a person typing three
/// letters of a model id is asking for. Prefer an exact label match, then a
/// match inside the section being filtered, so typing a model id that
/// substring-matches an Agent row does not select the Agent.
fun <T> pickerSubmitTarget(
    choices: List<PickerChoice<T>>,
    query: String,
    selectedSection: String,
): T? {
    val filtered = pickerFiltered(choices, query, selectedSection)
    if (filtered.isEmpty()) return null
    val trimmed = query.trim()
    filtered.firstOrNull { it.label.equals(trimmed, ignoreCase = true) }?.let { return it.value }
    if (selectedSection.isNotEmpty()) return filtered.first().value
    // No section filter: prefer a non-Agent section, since the combined
    // panel's Agent rows otherwise shadow model ids like "codex".
    val sections = pickerSections(filtered)
    if (sections.size > 1) {
        sections.firstOrNull { !it.first.contains("agent", ignoreCase = true) }
            ?.second?.firstOrNull()?.let { return it.value }
    }
    return filtered.first().value
}

/// The panel shell: a bottom sheet with the title and Done, matching the
/// sheet the iPhone puts the same list in.
@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun TsPickerSheet(
    title: String,
    onDismiss: () -> Unit,
    content: @Composable () -> Unit,
) {
    val colors = LocalTsColors.current
    val state = rememberModalBottomSheetState(skipPartiallyExpanded = true)
    ModalBottomSheet(
        onDismissRequest = onDismiss,
        sheetState = state,
        containerColor = colors.background,
    ) {
        Column(Modifier.fillMaxWidth()) {
            Row(
                Modifier.fillMaxWidth().padding(horizontal = Space.l),
                verticalAlignment = Alignment.CenterVertically,
            ) {
                Text(
                    title,
                    style = TsType.headline,
                    color = colors.textPrimary,
                    modifier = Modifier.weight(1f),
                )
                TextButton(onClick = onDismiss) { Text("Done") }
            }
            content()
        }
    }
}

/// Search field, filtered rows, and an optional way to reload the list.
///
/// The reload is not decoration. A model list is the agent CLI's answer as of
/// the last time the host asked it, cached so the picker does not shell out to
/// four CLIs on every keystroke. Add an API key to one of them and the new
/// provider is real everywhere except here, with nothing on screen admitting
/// it and no way to hurry it along. That is what the Refresh is for.
@Composable
fun <T> TsPickerOptionList(
    choices: List<PickerChoice<T>>,
    isSelected: (T) -> Boolean,
    prompt: String,
    emptyMessage: String,
    pick: (T) -> Unit,
    modifier: Modifier = Modifier,
    monospaced: Boolean = true,
    /// A line above the search field naming what the panel is for.
    caption: String? = null,
    onRefresh: (suspend () -> Unit)? = null,
    /// What a section is currently set to, shown beside its heading.
    sectionValue: ((String) -> String?)? = null,
    /// Quick filters for a picker with several independent settings. The
    /// agent/model/effort picker uses these to make its three editable
    /// dimensions obvious before somebody starts scrolling its long list.
    sectionTabs: List<String> = emptyList(),
    selectionSummary: String? = null,
    enabled: Boolean = true,
    /// Trailing accessory per row, for the model picker's favourite star.
    accessory: (@Composable (T) -> Unit)? = null,
) {
    val colors = LocalTsColors.current
    var query by remember { mutableStateOf("") }
    var refreshing by remember { mutableStateOf(false) }
    var refreshRequest by remember { mutableStateOf(0) }
    // Empty means every section. It avoids inventing a fourth, fake section
    // solely to represent the All tab.
    var selectedSection by remember { mutableStateOf("") }

    // The selected filter persists across choice changes. A hidden filter
    // that no longer exists would show "Nothing matches" with no affordance,
    // e.g. Effort selected then switching to an agent without Effort.
    LaunchedEffect(sectionTabs) {
        if (selectedSection.isNotEmpty() && selectedSection !in sectionTabs) selectedSection = ""
    }
    LaunchedEffect(refreshRequest) {
        if (refreshRequest == 0) return@LaunchedEffect
        val refresh = onRefresh ?: return@LaunchedEffect
        refreshing = true
        try {
            refresh()
        } finally {
            refreshing = false
        }
    }

    val filtered = pickerFiltered(choices, query, selectedSection)
    Column(modifier) {
        Column(
            Modifier.fillMaxWidth().padding(Space.m),
            verticalArrangement = Arrangement.spacedBy(Space.xs),
        ) {
            if (!caption.isNullOrEmpty()) {
                Text(caption, style = TsType.caption, color = colors.textSecondary)
            }
            if (selectionSummary != null) {
                Text(
                    selectionSummary,
                    style = TsType.callout,
                    color = colors.textSecondary,
                    modifier = Modifier.semantics {
                        contentDescription = "Current selection: $selectionSummary"
                    },
                )
            }
            Row(
                horizontalArrangement = Arrangement.spacedBy(Space.s),
                verticalAlignment = Alignment.CenterVertically,
            ) {
                TsSearchField(
                    prompt = prompt,
                    query = query,
                    onQueryChange = { query = it },
                    modifier = Modifier.weight(1f),
                    onSubmit = {
                        if (enabled) pickerSubmitTarget(choices, query, selectedSection)?.let(pick)
                    },
                )
                if (onRefresh != null) {
                    Icon(
                        ActionIcon.Refresh.vector,
                        "Ask this computer to read the agent's model list again",
                        tint = if (refreshing) colors.textTertiary else colors.accent,
                        modifier = Modifier
                            .size(44.dp)
                            .clip(CircleShape)
                            .clickable(enabled = !refreshing) { refreshRequest += 1 }
                            .padding(10.dp),
                    )
                }
            }
            // The group names stay visible while the list changes underneath
            // them. A search field alone told people they could search, not
            // that Agent, Model and Effort were separate things to change.
            if (sectionTabs.isNotEmpty()) {
                Row(
                    Modifier.horizontalScroll(rememberScrollState()),
                    horizontalArrangement = Arrangement.spacedBy(6.dp),
                ) {
                    TsPickerSectionTab("All", selectedSection.isEmpty()) {
                        selectedSection = ""
                        query = ""
                    }
                    sectionTabs.forEach { section ->
                        TsPickerSectionTab(section, selectedSection == section) {
                            selectedSection = section
                            query = ""
                        }
                    }
                }
            }
        }
        HorizontalDivider(color = colors.border)
        if (filtered.isEmpty()) {
            Column(
                Modifier.fillMaxWidth().padding(Space.l),
                horizontalAlignment = Alignment.CenterHorizontally,
                verticalArrangement = Arrangement.spacedBy(Space.xs),
            ) {
                Text(
                    if (query.isEmpty()) emptyMessage else "Nothing matches",
                    style = TsType.callout,
                    color = colors.textSecondary,
                )
                if (query.isNotEmpty()) {
                    Text(
                        "Try another part of the name.",
                        style = TsType.caption,
                        color = colors.textTertiary,
                    )
                }
            }
        } else {
            LazyColumn(
                Modifier.fillMaxWidth().heightIn(max = 420.dp).padding(horizontal = Space.s),
                verticalArrangement = Arrangement.spacedBy(2.dp),
            ) {
                pickerSections(filtered).forEachIndexed { index, (section, rows) ->
                    if (section.isNotEmpty()) {
                        item(key = "section-$section") {
                            Column {
                                if (index > 0) {
                                    HorizontalDivider(
                                        color = colors.border,
                                        modifier = Modifier.padding(top = Space.xs),
                                    )
                                }
                                TsPickerSectionHeading(section, sectionValue?.invoke(section))
                            }
                        }
                    }
                    items(rows.size, key = { "$section-${rows[it].label}-$it" }) { position ->
                        val choice = rows[position]
                        TsPickerRow(
                            choice = choice,
                            isSelected = isSelected(choice.value),
                            monospaced = monospaced,
                            enabled = enabled,
                            onPick = { pick(choice.value) },
                            accessory = accessory,
                        )
                    }
                }
            }
        }
    }
}

/// One selectable row: the mark, the label, and whatever the caller hangs off
/// the end of it.
@Composable
private fun <T> TsPickerRow(
    choice: PickerChoice<T>,
    isSelected: Boolean,
    monospaced: Boolean,
    enabled: Boolean,
    onPick: () -> Unit,
    accessory: (@Composable (T) -> Unit)?,
) {
    val colors = LocalTsColors.current
    Row(
        Modifier
            .fillMaxWidth()
            .clip(RoundedCornerShape(Space.s))
            .background(if (isSelected) colors.rowSelected else Color.Transparent),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        Row(
            Modifier
                .weight(1f)
                .clip(RoundedCornerShape(Space.s))
                .clickable(enabled = enabled, onClick = onPick)
                .padding(horizontal = Space.s, vertical = 6.dp)
                .heightIn(min = 48.dp),
            verticalAlignment = Alignment.CenterVertically,
            horizontalArrangement = Arrangement.spacedBy(Space.s),
        ) {
            BrandCheckDisc(isSelected)
            Column(Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(1.dp)) {
                Text(
                    choice.label,
                    style = if (monospaced) {
                        TsType.mono(15, if (isSelected) FontWeight.SemiBold else FontWeight.Normal)
                    } else {
                        TsType.body.copy(
                            fontWeight = if (isSelected) FontWeight.SemiBold else FontWeight.Normal,
                        )
                    },
                    color = colors.textPrimary,
                    maxLines = 2,
                    overflow = TextOverflow.MiddleEllipsis,
                )
                if (!choice.detail.isNullOrEmpty()) {
                    Text(
                        choice.detail,
                        style = TsType.caption2,
                        color = colors.textTertiary,
                        maxLines = 1,
                        overflow = TextOverflow.Ellipsis,
                    )
                }
            }
        }
        accessory?.invoke(choice.value)
    }
}

/// A section heading inside a panel, with what that section is currently set
/// to on the right of it.
///
/// The value is the part that earns its keep. A panel holding agent, model and
/// effort reads as one long list of names unless each group says what it is and
/// what it is set to, and the person who opened it came to change one of the
/// three.
@Composable
private fun TsPickerSectionHeading(title: String, value: String?) {
    val colors = LocalTsColors.current
    Row(
        Modifier
            .fillMaxWidth()
            .padding(horizontal = Space.s)
            .padding(top = Space.s, bottom = 2.dp),
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(Space.xs),
    ) {
        Text(
            title.uppercase(),
            style = TsType.caption2.copy(fontWeight = FontWeight.SemiBold),
            color = colors.accent,
        )
        Spacer(Modifier.weight(1f))
        if (!value.isNullOrEmpty()) {
            Text(
                value,
                style = TsType.caption2,
                color = colors.textSecondary,
                maxLines = 1,
                overflow = TextOverflow.MiddleEllipsis,
            )
        }
    }
}

/// One quick filter. Its own capsule rather than a `ChoiceChip`, because a
/// solid accent fill here would outweigh the row the person came to change.
@Composable
private fun TsPickerSectionTab(title: String, selected: Boolean, onSelect: () -> Unit) {
    val colors = LocalTsColors.current
    val shape = RoundedCornerShape(50)
    Box(
        Modifier
            .clip(shape)
            .background(if (selected) colors.accentSoft else colors.background)
            .border(1.dp, if (selected) colors.accent.copy(alpha = 0.35f) else colors.border, shape)
            .clickable(onClick = onSelect)
            .widthIn(min = 54.dp)
            .heightIn(min = 44.dp)
            .padding(horizontal = 9.dp),
        contentAlignment = Alignment.Center,
    ) {
        Text(
            title,
            style = TsType.caption.copy(
                fontWeight = if (selected) FontWeight.SemiBold else FontWeight.Normal,
            ),
            color = if (selected) colors.accent else colors.textSecondary,
            maxLines = 1,
            overflow = TextOverflow.Ellipsis,
        )
    }
}

/// The field that says what a setting is and opens its picker. Port of
/// `ChatAgentField`: the summary is the label, and the chevron is the only
/// decoration it carries.
@Composable
fun TsPickerField(
    summary: String,
    onOpen: () -> Unit,
    modifier: Modifier = Modifier,
    enabled: Boolean = true,
) {
    val colors = LocalTsColors.current
    val shape = RoundedCornerShape(Space.s)
    Row(
        modifier
            .clip(shape)
            .background(colors.panel)
            .border(1.dp, colors.border, shape)
            .clickable(enabled = enabled, onClick = onOpen)
            .padding(horizontal = 10.dp, vertical = 6.dp)
            .heightIn(min = 44.dp),
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(6.dp),
    ) {
        Text(
            summary,
            style = TsType.callout.copy(fontWeight = FontWeight.Medium),
            color = if (enabled) colors.textPrimary else colors.textTertiary,
            maxLines = 2,
            overflow = TextOverflow.MiddleEllipsis,
            modifier = Modifier.weight(1f, fill = false),
        )
        Icon(
            ActionIcon.Disclosure.vector,
            null,
            tint = colors.textTertiary,
            modifier = Modifier.size(16.dp),
        )
    }
}

/// A full-width picker row: a label on the left, the field on the right.
@Composable
fun TsPickerFieldRow(
    label: String,
    summary: String,
    onOpen: () -> Unit,
    modifier: Modifier = Modifier,
    enabled: Boolean = true,
) {
    Row(
        modifier.fillMaxWidth(),
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(Space.s),
    ) {
        Text(
            label,
            style = TsType.callout,
            color = LocalTsColors.current.textPrimary,
        )
        Spacer(Modifier.weight(1f))
        TsPickerField(
            summary = summary,
            onOpen = onOpen,
            enabled = enabled,
            modifier = Modifier.widthIn(max = 220.dp),
        )
    }
}

/// A flat list in the picker's sheet, for the single-setting cases: pick a
/// persona, pick which agent drafts one.
@Composable
fun <T> TsSimplePickerSheet(
    title: String,
    choices: List<PickerChoice<T>>,
    isSelected: (T) -> Boolean,
    prompt: String,
    emptyMessage: String,
    onPick: (T) -> Unit,
    onDismiss: () -> Unit,
    monospaced: Boolean = false,
) {
    TsPickerSheet(title = title, onDismiss = onDismiss) {
        Box(Modifier.fillMaxSize()) {
            TsPickerOptionList(
                choices = choices,
                isSelected = isSelected,
                prompt = prompt,
                emptyMessage = emptyMessage,
                monospaced = monospaced,
                pick = {
                    onPick(it)
                    onDismiss()
                },
            )
        }
    }
}
