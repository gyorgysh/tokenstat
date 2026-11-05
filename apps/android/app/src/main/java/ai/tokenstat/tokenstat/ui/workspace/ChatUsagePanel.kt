// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
package ai.tokenstat.tokenstat.ui.workspace

import ai.tokenstat.tokenstat.AppViewModel
import ai.tokenstat.tokenstat.ui.LimitCard
import ai.tokenstat.tokenstat.ui.components.TsCard
import ai.tokenstat.tokenstat.ui.localization.L10n
import ai.tokenstat.tokenstat.ui.logic.LimitLogic
import ai.tokenstat.tokenstat.ui.logic.harnessName
import ai.tokenstat.tokenstat.ui.theme.LocalTsColors
import androidx.compose.foundation.Canvas
import androidx.compose.foundation.layout.*
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.StrokeCap
import androidx.compose.ui.graphics.drawscope.Stroke
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.stateDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.lifecycle.Lifecycle
import androidx.lifecycle.compose.LocalLifecycleOwner
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import androidx.lifecycle.repeatOnLifecycle
import kotlinx.coroutines.delay
import kotlinx.serialization.json.*
import java.text.NumberFormat
import java.util.Locale

@Composable internal fun rememberChatQuota(model: AppViewModel, backend: String): JsonObject? {
    val state by model.state.collectAsStateWithLifecycle()
    val lifecycle = LocalLifecycleOwner.current.lifecycle
    val owner = state.account?.let(ai.tokenstat.tokenstat.ecosystem.UsageSnapshot::owner)
    LaunchedEffect(model, owner, lifecycle) {
        if (owner == null) return@LaunchedEffect
        lifecycle.repeatOnLifecycle(Lifecycle.State.RESUMED) {
            while (true) { model.refreshLimits(); delay(30_000) }
        }
    }
    return remember(state.limits, state.limitsError, backend) {
        chatQuotaReading(state.limits, backend, state.limitsError != null)
    }
}

@Composable internal fun ChatQuotaBadge(reading: JsonObject?, onOpen: () -> Unit) {
    val window = reading?.let(::chatQuotaMainWindow) ?: return
    val percent = chatQuotaPercent(window) ?: return
    val colors = LocalTsColors.current
    val stale = reading.bol("stale")
    val tint = if (stale) colors.textSecondary else quotaColor(window, percent)
    val description = L10n.text("common.chat.usage.allowance", harnessName(reading.str("source").orEmpty()),
        window.str("label").orEmpty(), NumberFormat.getIntegerInstance().format(percent))
    IconButton(onClick = onOpen, modifier = Modifier.semantics {
        contentDescription = description
        if (stale) stateDescription = L10n.text("common.chat.usage.stale")
    }) {
        Canvas(Modifier.size(20.dp)) {
            val stroke = 3.dp.toPx()
            drawCircle(colors.border, style = Stroke(stroke))
            drawArc(tint, -90f, (percent.coerceIn(0.0, 100.0) * 3.6).toFloat(), false,
                style = Stroke(stroke, cap = StrokeCap.Round))
        }
    }
}

@Composable private fun quotaColor(window: JsonObject, percent: Double): Color {
    val colors = LocalTsColors.current
    return when (LimitLogic.severityOf(window.str("severity"), percent)) {
        LimitLogic.Severity.NORMAL -> colors.accent
        LimitLogic.Severity.WARNING -> colors.warning
        LimitLogic.Severity.CRITICAL -> colors.danger
    }
}

@Composable internal fun ChatUsagePanel(reading: JsonObject?, snapshot: ChatInspectionSnapshot, fallback: ChatUsageTotals?) {
    val colors = LocalTsColors.current
    if (reading != null) LimitCard(reading)
    else Text(L10n.text("common.chat.usage.no_limits"), style = MaterialTheme.typography.bodySmall, color = colors.textSecondary)
    val data = snapshot.data
    val metrics = chatContextMetrics(data)
    TsCard(Modifier.fillMaxWidth()) {
        Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
            Text(L10n.text("common.chat.stats.context"), fontWeight = FontWeight.SemiBold, color = colors.textPrimary)
            val used = metrics.used
            val window = metrics.window
            if (used == null) Text(L10n.text("common.chat.stats.no_data"), color = colors.textSecondary)
            else {
                if (window == null) {
                    Text(L10n.text("common.chat.stats.in_context", NumberFormat.getIntegerInstance().format(used)), color = colors.textPrimary)
                    Text(L10n.text("common.chat.stats.window_unknown"), style = MaterialTheme.typography.bodySmall, color = colors.textSecondary)
                } else {
                    UsageRow(L10n.text("common.chat.stats.capacity", NumberFormat.getIntegerInstance().format(used), NumberFormat.getIntegerInstance().format(window)),
                        NumberFormat.getPercentInstance().format(used / window))
                    LinearProgressIndicator(progress = { (used / window).coerceIn(0.0, 1.0).toFloat() }, modifier = Modifier.fillMaxWidth(),
                        color = if (used / window >= .95) colors.danger else if (used / window >= .8) colors.warning else colors.accent)
                    if (data?.str("windowSource") == "catalog") Text(L10n.text("common.chat.stats.catalog_window"), style = MaterialTheme.typography.bodySmall, color = colors.textSecondary)
                    if (data?.str("windowSource") == "previousAgent") Text(L10n.text("common.chat.stats.last_window"), style = MaterialTheme.typography.bodySmall, color = colors.textSecondary)
                }
                if (snapshot.stale) Text(L10n.text("common.chat.usage.stale"), style = MaterialTheme.typography.bodySmall, color = colors.warning)
            }
        }
    }
    val reportedUsage = ChatUsageTotals.decode(data?.get("usage") as? JsonObject)
    val totals = (reportedUsage ?: fallback)?.takeUnless { it.isEmpty }
    TsCard(Modifier.fillMaxWidth()) {
        Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
            Text(L10n.text("common.chat.stats.conversation"), fontWeight = FontWeight.SemiBold, color = colors.textPrimary)
            if (totals == null) Text(L10n.text("common.chat.usage.no_totals"), style = MaterialTheme.typography.bodySmall, color = colors.textSecondary)
            else {
                val number = NumberFormat.getIntegerInstance()
                UsageRow(L10n.text("common.chat.stats.input"), number.format(totals.input))
                UsageRow(L10n.text("common.chat.stats.output"), number.format(totals.output))
                UsageRow(L10n.text("common.chat.stats.cache_read"), number.format(totals.cacheRead))
                UsageRow(L10n.text("common.chat.stats.cache_write"), number.format(totals.cacheWrite))
                if (totals.cost > 0) UsageRow(L10n.text("common.chat.stats.cost"), NumberFormat.getCurrencyInstance(Locale.US).format(totals.cost))
                if (snapshot.stale && reportedUsage != null) Text(L10n.text("common.chat.usage.stale"), style = MaterialTheme.typography.bodySmall, color = colors.warning)
            }
        }
    }
}

@Composable private fun UsageRow(label: String, value: String) {
    val colors = LocalTsColors.current
    if (LocalDensity.current.fontScale > 1.3f) {
        Column(Modifier.fillMaxWidth(), verticalArrangement = Arrangement.spacedBy(4.dp)) {
            Text(label, style = MaterialTheme.typography.bodySmall, color = colors.textSecondary)
            Text(value, style = MaterialTheme.typography.bodyMedium, fontWeight = FontWeight.Medium, color = colors.textPrimary)
        }
    } else {
        Row(Modifier.fillMaxWidth(), verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(12.dp)) {
            Text(label, Modifier.weight(1f), style = MaterialTheme.typography.bodySmall, color = colors.textSecondary)
            Text(value, style = MaterialTheme.typography.bodyMedium, fontWeight = FontWeight.Medium, color = colors.textPrimary)
        }
    }
}
