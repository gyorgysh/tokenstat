// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
package ai.tokenstat.tokenstat.ui.chrome

import ai.tokenstat.tokenstat.ui.components.TsBottomSheet
import ai.tokenstat.tokenstat.ui.localization.L10n

import android.content.Context
import androidx.compose.foundation.gestures.awaitFirstDown
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.lazy.rememberLazyListState
import androidx.compose.foundation.clickable
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.ChevronRight
import androidx.compose.material.icons.filled.DragHandle
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.Icon
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableFloatStateOf
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.alpha
import androidx.compose.ui.layout.onSizeChanged
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.graphics.graphicsLayer
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.input.nestedscroll.NestedScrollConnection
import androidx.compose.ui.input.nestedscroll.NestedScrollSource
import androidx.compose.ui.input.nestedscroll.nestedScroll
import androidx.compose.ui.input.pointer.PointerEventPass
import androidx.compose.ui.input.pointer.pointerInput
import kotlin.math.abs
import androidx.compose.ui.text.TextStyle
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.compose.ui.zIndex
import ai.tokenstat.tokenstat.ui.components.ActionIcon
import ai.tokenstat.tokenstat.ui.components.BrandCheckDisc
import ai.tokenstat.tokenstat.ui.components.TsAccentButton
import ai.tokenstat.tokenstat.ui.components.TsCard
import ai.tokenstat.tokenstat.ui.components.TsType
import ai.tokenstat.tokenstat.ui.theme.LocalTsColors
import ai.tokenstat.tokenstat.ui.theme.Space

data class TabDef(val id: String, val label: String, val detail: String, val icon: ImageVector)

interface TabPrefs {
    fun loadOrder(): List<String>?
    fun loadHidden(): Set<String>
    fun save(order: List<String>, hidden: Set<String>)
}

class SharedPrefsTabs(context: Context) : TabPrefs {
    private val prefs = context.getSharedPreferences("ts.tabs", Context.MODE_PRIVATE)

    override fun loadOrder(): List<String>? {
        if (!prefs.contains(OrderKey)) return null
        return prefs.getStringSet(OrderKey, emptySet()).orEmpty().toList()
            .sorted()
            .mapNotNull { it.substringAfter(":", "").takeIf { slot -> slot.isNotEmpty() } }
            .takeIf { it.isNotEmpty() }
    }

    override fun loadHidden(): Set<String> = prefs.getStringSet(HiddenKey, emptySet()).orEmpty()

    override fun save(order: List<String>, hidden: Set<String>) {
        prefs.edit()
            .putStringSet(OrderKey, order.mapIndexed { index, id -> "%02d:%s".format(index, id) }.toSet())
            .putStringSet(HiddenKey, hidden)
            .apply()
    }

    companion object {
        private const val OrderKey = "client.tabOrder.v1"
        private const val HiddenKey = "client.tabHidden.v1"
    }
}

class TabCustomization(
    private val prefs: TabPrefs,
    allTabs: List<String>,
    defaultHidden: Set<String>,
) {
    var order by mutableStateOf(resolveOrder(prefs.loadOrder(), allTabs))
        private set
    var hidden by mutableStateOf(resolveHidden(prefs.loadOrder() == null, prefs.loadHidden(), order, defaultHidden))
        private set

    val visibleTabs: List<String>
        get() {
            val shown = order.filter { !hidden.contains(it) }
            return if (shown.isEmpty()) listOf(allTabs.first()) else shown
        }

    private val allTabs: List<String> = allTabs
    private val defaultHidden: Set<String> = defaultHidden

    fun displayed(selected: String): List<String> =
        TabVisibility.displayed(order, visibleTabs, selected)

    fun setVisible(visible: Boolean, tab: String): Boolean {
        if (!visible && !hidden.contains(tab) && order.count { !hidden.contains(it) } <= 1) return false
        hidden = if (visible) hidden - tab else hidden + tab
        save()
        return true
    }

    fun move(from: Int, to: Int) {
        if (from == to || from !in order.indices || to !in 0..order.size) return
        val next = order.toMutableList()
        val tab = next.removeAt(from)
        next.add(to.coerceAtMost(next.size), tab)
        order = next
        save()
    }

    fun reset() {
        order = allTabs
        hidden = defaultHidden
        save()
    }

    private fun save() = prefs.save(order, hidden)

    companion object {
        fun resolveOrder(stored: List<String>?, allTabs: List<String>): List<String> {
            val known = (stored ?: emptyList()).filter { allTabs.contains(it) }.distinct()
            return known + allTabs.filter { !known.contains(it) }
        }

        fun resolveHidden(
            neverStored: Boolean,
            storedHidden: Set<String>,
            order: List<String>,
            defaultHidden: Set<String>,
        ): Set<String> {
            val hidden = (if (neverStored) defaultHidden else storedHidden).intersect(order.toSet())
            return if (order.isNotEmpty() && hidden.size == order.size) hidden - order.first() else hidden
        }
    }
}

object TabVisibility {
    fun <T> displayed(order: List<T>, visible: List<T>, selected: T): List<T> {
        if (visible.contains(selected)) return visible
        return order.filter { visible.contains(it) || it == selected }
    }
}

fun tabSummary(visibleLabels: List<String>): String = when (visibleLabels.size) {
    0 -> L10n.text("common.home")
    in 1..3 -> visibleLabels.joinToString(", ")
    else -> {
        val rest = visibleLabels.size - 2
        visibleLabels.take(2).joinToString(", ") + L10n.text("android.tabcustomization.and_0_more.5a1fce7b", "${rest}")
    }
}

@Composable
fun TabsCard(summary: String, onOpen: () -> Unit) {
    val colors = LocalTsColors.current
    TsCard(modifier = Modifier.clickable { onOpen() }) {
        Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(Space.m)) {
            Column(verticalArrangement = Arrangement.spacedBy(Space.xs), modifier = Modifier.weight(1f)) {
                Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(Space.s)) {
                    Icon(ActionIcon.Device.vector, null, tint = colors.accent)
                    Text(L10n.text("android.tabcustomization.tabs.8e5ea509"), style = TextStyle(fontSize = 15.sp, fontWeight = FontWeight.SemiBold), color = colors.textPrimary)
                }
                Text(summary, style = TsType.body, color = colors.textSecondary)
            }
            Icon(Icons.Default.ChevronRight, null, tint = colors.textTertiary)
        }
    }
}

@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun TabEditorSheet(tabs: List<TabDef>, customization: TabCustomization, onDismiss: () -> Unit) {
    val colors = LocalTsColors.current
    var refused by remember { mutableStateOf<TabDef?>(null) }
    val listState = rememberLazyListState()
    var dragging by remember { mutableStateOf<String?>(null) }
    var dragOffset by remember { mutableFloatStateOf(0f) }
    val dragScrollGate = remember(dragging) {
        object : NestedScrollConnection {
            override fun onPreScroll(available: Offset, source: NestedScrollSource): Offset =
                if (dragging != null) available else Offset.Zero

            override fun onPostScroll(
                consumed: Offset,
                available: Offset,
                source: NestedScrollSource,
            ): Offset = if (dragging != null) available else Offset.Zero
        }
    }
    TsBottomSheet(onDismissRequest = onDismiss, containerColor = colors.background) {
        Column(
            Modifier.fillMaxWidth().padding(horizontal = Space.l).padding(bottom = Space.xl),
            verticalArrangement = Arrangement.spacedBy(Space.m),
        ) {
            Row(verticalAlignment = Alignment.CenterVertically) {
                Text(
                    L10n.text("android.tabcustomization.tabs.8e5ea509"),
                    style = TextStyle(fontSize = 17.sp, fontWeight = FontWeight.SemiBold),
                    color = colors.textPrimary,
                    modifier = Modifier.weight(1f),
                )
                TextButton(onClick = onDismiss) { Text(L10n.text("common.done")) }
            }
            Text(L10n.text("android.tabcustomization.drag_to_reorder_uncheck_what_you_never_ope.ce93af9a"), style = TsType.body, color = colors.textSecondary)
            var columnWidthPx by remember { mutableIntStateOf(0) }
            val density = LocalDensity.current
            val handleZonePx = remember(density) { with(density) { 64.dp.toPx() } }
            fun dragBy(dy: Float) {
                val id = dragging ?: return
                dragOffset += dy
                val info = listState.layoutInfo.visibleItemsInfo
                val current = info.find { it.key == id } ?: return
                val middle = current.offset + dragOffset + current.size / 2
                val under = info.find { middle >= it.offset && middle <= it.offset + it.size && it.key != id }
                if (under != null) {
                    val from = customization.order.indexOf(id)
                    val to = customization.order.indexOf(under.key)
                    if (from >= 0 && to >= 0) {
                        customization.move(from, to)
                        dragOffset = middle - (under.offset + under.size / 2)
                    }
                }
            }
            LazyColumn(
                state = listState,
                verticalArrangement = Arrangement.spacedBy(Space.s),
                modifier = Modifier
                    .nestedScroll(dragScrollGate)
                    .onSizeChanged { columnWidthPx = it.width }
                    .pointerInput(columnWidthPx, handleZonePx) {
                        try {
                        awaitPointerEventScope {
                            val slop = viewConfiguration.touchSlop
                            while (true) {
                                val down = awaitFirstDown(pass = PointerEventPass.Initial)
                                val hit = listState.layoutInfo.visibleItemsInfo
                                    .find { down.position.y >= it.offset && down.position.y <= it.offset + it.size }
                                val grabbed: String? = if (down.position.x < columnWidthPx - handleZonePx) {
                                    null
                                } else {
                                    val key = hit?.key as? String
                                    if (key != null && customization.order.contains(key)) key else null
                                }
                                if (grabbed != null) {
                                    down.consume()
                                    dragging = grabbed
                                    dragOffset = 0f
                                    var previous = down.position.y
                                    var travelled = 0f
                                    var moved = false
                                    var held = true
                                    while (held) {
                                        val event = awaitPointerEvent(pass = PointerEventPass.Initial)
                                        val change = event.changes.firstOrNull { it.id == down.id }
                                        if (change == null) {
                                            continue
                                        }
                                        if (!change.pressed) {
                                            change.consume()
                                            held = false
                                        } else {
                                            val dy = change.position.y - previous
                                            previous = change.position.y
                                            travelled += dy
                                            if (moved || abs(travelled) >= slop) {
                                                moved = true
                                                change.consume()
                                                dragBy(dy)
                                            }
                                        }
                                    }
                                    dragging = null
                                    dragOffset = 0f
                                }
                            }
                        }
                        } finally {
                            dragging = null
                            dragOffset = 0f
                        }
                    },
            ) {
                items(customization.order, key = { id: String -> id }) { id ->
                    val def = tabs.find { it.id == id } ?: return@items
                    val on = !customization.hidden.contains(id)
                    val lastStanding = on && customization.visibleTabs.size <= 1
                    TabEditorRow(
                        def = def,
                        on = on,
                        dimmed = lastStanding,
                        dragging = dragging == id,
                        dragOffset = if (dragging == id) dragOffset else 0f,
                        onToggle = {
                            if (customization.setVisible(!on, id)) refused = null else refused = def
                        },
                    )
                }
            }
            val off = customization.order.filter { customization.hidden.contains(it) }
                .mapNotNull { id -> tabs.find { it.id == id }?.label }
            Text(
                if (off.isEmpty()) L10n.text("android.tabcustomization.every_tab_is_on.07e49fd9")
                else L10n.text("android.tabcustomization.off_0_a_hidden_tab_appears_temporarily_whe.e422c93c", "${off.joinToString(", ")}"),
                style = TsType.body,
                color = colors.textSecondary,
            )
            TsAccentButton(
                label = L10n.text("android.tabcustomization.reset_tabs.e5fcb0cc"),
                icon = ActionIcon.Refresh.vector,
                onClick = { customization.reset(); refused = null },
            )
        }
    }
    refused?.let { def ->
        AlertDialog(
            onDismissRequest = { refused = null },
            title = { Text(L10n.text("android.tabcustomization.one_tab_stays_on.6676423c")) },
            text = { Text(L10n.text("android.tabcustomization.hiding_0_too_would_leave_the_bar_empty.2725d7a6", "${def.label}")) },
            confirmButton = { TextButton(onClick = { refused = null }) { Text(L10n.text("android.tabcustomization.ok.565339bc")) } },
        )
    }
}

@Composable
private fun TabEditorRow(
    def: TabDef,
    on: Boolean,
    dimmed: Boolean,
    dragging: Boolean,
    dragOffset: Float,
    onToggle: () -> Unit,
) {
    val colors = LocalTsColors.current
    TsCard(
        modifier = Modifier
            .zIndex(if (dragging) 1f else 0f)
            .graphicsLayer { translationY = dragOffset }
            .alpha(if (dragging) 0.92f else 1f)
            .clickable { if (!dimmed) onToggle() },
    ) {
        Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(Space.m)) {
            Icon(def.icon, null, tint = if (on) colors.accent else colors.textSecondary, modifier = Modifier.width(24.dp))
            Column(Modifier.weight(1f)) {
                Text(
                    def.label,
                    style = TsType.body,
                    color = if (on) colors.textPrimary else colors.textSecondary,
                )
                Text(def.detail, style = TsType.caption, color = colors.textSecondary)
            }
            BrandCheckDisc(on = on, modifier = Modifier.alpha(if (dimmed) 0.35f else 1f))
            Icon(
                Icons.Default.DragHandle,
                L10n.text("android.tabcustomization.reorder.14ac200e"),
                tint = colors.textTertiary,
            )
        }
    }
}
