// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
package ai.tokenstat.tokenstat.ecosystem

import android.app.PendingIntent
import android.appwidget.AppWidgetManager
import android.content.Context
import android.content.Intent
import android.graphics.*
import android.util.SizeF
import android.view.View
import android.widget.RemoteViews
import androidx.core.graphics.createBitmap
import ai.tokenstat.tokenstat.R
import java.text.NumberFormat

/** Allowance widgets share the verified account cache and refresh worker with activity. */
class LimitsWidgetProvider : UsageWidgetProvider() {
    companion object {
        internal fun preferences(context: Context) = context.getSharedPreferences("usage-widget", Context.MODE_PRIVATE)
        internal fun readings(context: Context, snapshot: UsageSnapshot?, id: Int): List<QuotaProvider> {
            val chosen = preferences(context).getStringSet("provider.$id", null)
            return snapshot?.limits.orEmpty().filter { chosen == null || "${snapshot?.owner}\n${it.source}" in chosen }.sortedBy { it.source }
        }
        fun render(context: Context, snapshot: UsageSnapshot?, id: Int, refresh: PendingIntent? = null, refreshing: Boolean = false): RemoteViews {
            val rings = preferences(context).getString("style.$id", "rings") != "bars"
            val selected = readings(context, snapshot, id)
            if (android.os.Build.VERSION.SDK_INT >= 31) return RemoteViews(
                listOf(110 to 64, 160 to 64, 280 to 64, 110 to 130, 160 to 130, 160 to 160,
                    280 to 130, 160 to 280, 280 to 280).associate { (width, height) ->
                    SizeF(width.toFloat(), height.toFloat()) to renderSize(context, snapshot, selected, id, rings, width, height, refresh, refreshing)
                })
            val options = AppWidgetManager.getInstance(context).getAppWidgetOptions(id)
            val width = options.getInt(AppWidgetManager.OPTION_APPWIDGET_MIN_WIDTH, 160).coerceAtLeast(110)
            val height = options.getInt(AppWidgetManager.OPTION_APPWIDGET_MIN_HEIGHT, 130).coerceAtLeast(64)
            return renderSize(context, snapshot, selected, id, rings, width, height, refresh, refreshing)
        }
        internal data class Cell(val provider: QuotaProvider, val window: QuotaWindow?)
        internal fun cells(readings: List<QuotaProvider>, selection: QuotaWindowSelection, now: Long): List<Cell> = readings.flatMap { provider ->
            selection.windows(provider, now).map { Cell(provider, it) }.ifEmpty { listOf(Cell(provider, null)) }
        }
        /** Render bounded native gauges at the actual allocated size, including one-row cards. */
        fun renderSize(context: Context, snapshot: UsageSnapshot?, readings: List<QuotaProvider>, id: Int,
                       rings: Boolean, width: Int, height: Int, refresh: PendingIntent? = null, refreshing: Boolean = false): RemoteViews {
            val now = System.currentTimeMillis()
            val compact = height < 110
            val views = RemoteViews(context.packageName, if (compact) R.layout.limits_widget_compact else R.layout.limits_widget)
            val density = context.resources.displayMetrics.density
            val availableWidth = (width - if (compact) 56 else 16).coerceAtLeast(50).toFloat()
            val availableHeight = (height - if (compact) 12 else 56).coerceIn(36, 300).toFloat()
            val bitmap = createBitmap((availableWidth * density).toInt().coerceAtLeast(1), (availableHeight * density).toInt().coerceAtLeast(1))
            val canvas = Canvas(bitmap).apply { scale(density, density) }
            val accent = context.getColor(R.color.ts_widget_accent)
            val ink = context.getColor(R.color.ts_widget_text)
            val muted = context.getColor(R.color.ts_widget_muted)
            val paint = Paint(Paint.ANTI_ALIAS_FLAG).apply { typeface = androidx.core.content.res.ResourcesCompat.getFont(context, R.font.widget_manrope) ?: Typeface.create("sans-serif", Typeface.NORMAL) }
            fun text(value: String, x: Float, y: Float, maxWidth: Float, size: Float, color: Int, center: Boolean = false) {
                paint.style = Paint.Style.FILL; paint.color = color; paint.textSize = size * context.resources.configuration.fontScale
                paint.textAlign = if (center) Paint.Align.CENTER else Paint.Align.LEFT
                if (value.endsWith("%")) paint.textSize *= (maxWidth / paint.measureText(value).coerceAtLeast(1f)).coerceAtMost(1f)
                val fitted = android.text.TextUtils.ellipsize(value, android.text.TextPaint(paint), maxWidth, android.text.TextUtils.TruncateAt.END).toString()
                canvas.drawText(fitted, x, y, paint)
            }
            val selection = QuotaWindowSelection.fromKey(preferences(context).getString("window.$id", "highest"))
            val all = cells(readings, selection, now)
            val columns = (availableWidth / if (compact) 50 else 60).toInt().coerceIn(1, if (compact) 4 else 3)
            val rowHeight = when {
                !compact && availableHeight >= 140 -> 66f
                !compact && availableHeight in 72f..<88f -> 36f
                else -> 44f
            }
            val rowCount = if (compact) 1 else (availableHeight / rowHeight).toInt().coerceAtLeast(1)
            val shown = all.take(columns * rowCount)
            shown.forEachIndexed { index, cell ->
                val provider = cell.provider
                val window = cell.window
                val cellWidth = availableWidth / columns
                val column = index % columns
                val x = (if (context.resources.configuration.layoutDirection == View.LAYOUT_DIRECTION_RTL) columns - 1 - column else column) * cellWidth
                val y = index / columns * rowHeight
                val expired = window?.expired(now) == true
                val percent = window?.takeUnless { expired }?.let { NumberFormat.getIntegerInstance().format(it.percent) + "%" } ?: "—"
                val color = when { (window?.percent ?: 0.0) >= 100 -> context.getColor(R.color.ts_widget_danger)
                    (window?.percent ?: 0.0) >= 85 -> context.getColor(R.color.ts_widget_warning); else -> accent }
                if (rings) {
                    val diameter = if (rowHeight >= 66) 36f else if (compact || rowHeight < 44) 22f else 26f
                    val cx = x + cellWidth / 2
                    val rect = RectF(cx - diameter / 2, y + 2, cx + diameter / 2, y + 2 + diameter)
                    paint.style = Paint.Style.STROKE; paint.strokeWidth = 3f; paint.strokeCap = Paint.Cap.ROUND
                    paint.color = muted; paint.alpha = 55
                    canvas.drawArc(rect, 0f, 360f, false, paint); paint.alpha = 255; paint.color = color
                    if (window != null && !expired) canvas.drawArc(rect, -90f, window.fraction * 360, false, paint)
                    text(percent, cx, y + diameter / 2 + 7, diameter - 5, 12f, ink, true)
                    if (compact) {
                        text(provider.name, cx, y + 35, cellWidth - 4, 11f, ink, true)
                        text(window?.compactLabel ?: "—", cx, y + 48, cellWidth - 4, 9f, muted, true)
                    } else if (rowHeight >= 66) {
                        text(provider.name, cx, y + 51, cellWidth - 4, 11f, ink, true)
                        text(window?.compactLabel ?: context.getString(R.string.widget_no_reading), cx, y + 64, cellWidth - 4, 11f, muted, true)
                    } else {
                        text(provider.name + (window?.let { " · ${it.compactLabel}" } ?: ""), cx, y + if (rowHeight < 44) 32 else 42, cellWidth - 4, if (rowHeight < 44) 10f else 11f, ink, true)
                    }
                } else {
                    text(provider.name, x + 2, y + 12, cellWidth - 4, 11f, ink)
                    val readingY = y + if (rowHeight < 44) 24 else 26
                    val barY = y + if (rowHeight < 44) 30 else 33
                    text(window?.compactLabel ?: context.getString(R.string.widget_no_reading), x + 2, readingY, (cellWidth - 36).coerceAtLeast(15f), 11f, muted)
                    // Right-align the percentage without relying on the widget's layout direction.
                    paint.textAlign = Paint.Align.RIGHT; paint.color = ink; paint.textSize = 12f * context.resources.configuration.fontScale
                    paint.textSize *= (32f / paint.measureText(percent).coerceAtLeast(1f)).coerceAtMost(1f)
                    canvas.drawText(percent, x + cellWidth - 2, readingY, paint)
                    paint.style = Paint.Style.FILL; paint.color = muted; paint.alpha = 55
                    canvas.drawRoundRect(x + 2, barY, x + cellWidth - 2, barY + 4, 3f, 3f, paint)
                    paint.alpha = 255; paint.color = color
                    if (window != null && !expired) canvas.drawRoundRect(x + 2, barY, x + 2 + (cellWidth - 4) * window.fraction, barY + 4, 3f, 3f, paint)
                    if (rowHeight >= 66 && window?.resetsAt != null && !expired) {
                        val remaining = (window.resetsAt - now).coerceAtLeast(60_000)
                        val (units, resource) = when {
                            remaining >= 86_400_000 -> remaining / 86_400_000 to R.string.widget_reset_days
                            remaining >= 3_600_000 -> remaining / 3_600_000 to R.string.widget_reset_hours
                            else -> remaining / 60_000 to R.string.widget_reset_minutes
                        }
                        text(context.getString(resource, NumberFormat.getIntegerInstance().format(units)), x + 2, y + 56, cellWidth - 4, 11f, muted)
                    }
                }
            }
            views.setImageViewBitmap(R.id.limits_gauges, bitmap)
            views.setViewVisibility(R.id.limits_gauges, if (readings.isEmpty()) View.GONE else View.VISIBLE)
            views.setViewVisibility(R.id.limits_empty, if (readings.isEmpty()) View.VISIBLE else View.GONE)
            if (compact) views.setTextViewText(R.id.limits_empty, context.getString(R.string.widget_open_to_sync))
            else views.setViewVisibility(R.id.limits_brand, if (width >= 160) View.VISIBLE else View.GONE)
            val oldest = shown.minOfOrNull { it.provider.observedAt }
            val age = oldest?.let { android.text.format.DateUtils.getRelativeTimeSpanString(it, now, 60_000, android.text.format.DateUtils.FORMAT_ABBREV_RELATIVE).toString() }
            val status = when { refreshing -> context.getString(R.string.widget_updating)
                readings.isEmpty() -> context.getString(R.string.widget_open_to_sync); else -> age.orEmpty() } +
                if (all.size > shown.size) " · +${all.size - shown.size}" else ""
            views.setTextViewText(R.id.limits_status, status)
            if (compact) {
                views.setViewVisibility(R.id.limits_overflow, if (all.size > shown.size) View.VISIBLE else View.GONE)
                views.setTextViewText(R.id.limits_overflow, "+${all.size - shown.size}")
            }
            views.setContentDescription(R.id.limits_status, status)
            views.setContentDescription(R.id.limits_gauges, shown.joinToString(". ") { cell ->
                cell.provider.name + ": " + (cell.window?.let { window ->
                    if (window.expired(now)) context.getString(R.string.widget_reset_passed)
                    else window.displayLabel + " " + context.getString(R.string.widget_percent_used, NumberFormat.getIntegerInstance().format(window.percent)) +
                        (window.resetsAt?.let { " " + context.getString(R.string.widget_resets, java.util.Date(it).toString()) } ?: "")
                } ?: context.getString(R.string.widget_no_reading)) + ". " + java.util.Date(cell.provider.observedAt)
            })
            views.setOnClickPendingIntent(R.id.limits_root, QuickAccess.pendingIntent(context, "home"))
            views.setOnClickPendingIntent(R.id.limits_configure, PendingIntent.getActivity(context, id,
                Intent(context, LimitsWidgetConfigurationActivity::class.java).putExtra(AppWidgetManager.EXTRA_APPWIDGET_ID, id), PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE))
            views.setBoolean(R.id.limits_refresh, "setEnabled", !refreshing)
            views.setViewVisibility(R.id.limits_refresh, if (refreshing) View.INVISIBLE else View.VISIBLE)
            views.setViewVisibility(R.id.limits_progress, if (refreshing) View.VISIBLE else View.GONE)
            if (refresh != null) views.setOnClickPendingIntent(R.id.limits_refresh, refresh)
            return views
        }
    }
}
