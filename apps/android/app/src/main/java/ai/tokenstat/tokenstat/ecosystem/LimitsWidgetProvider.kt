// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
package ai.tokenstat.tokenstat.ecosystem

import android.app.PendingIntent
import android.appwidget.AppWidgetManager
import android.content.Context
import android.content.Intent
import android.graphics.*
import android.os.Bundle
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
            val manager = AppWidgetManager.getInstance(context)
            if (android.os.Build.VERSION.SDK_INT >= 31) return RemoteViews(mapOf(
                SizeF(110f, 130f) to renderSize(context, snapshot, readings(context, snapshot, id), id, rings, 110, 130, refresh, refreshing),
                SizeF(160f, 130f) to renderSize(context, snapshot, readings(context, snapshot, id), id, rings, 160, 130, refresh, refreshing),
                SizeF(280f, 130f) to renderSize(context, snapshot, readings(context, snapshot, id), id, rings, 300, 130, refresh, refreshing),
                SizeF(160f, 280f) to renderSize(context, snapshot, readings(context, snapshot, id), id, rings, 180, 280, refresh, refreshing),
                SizeF(280f, 280f) to renderSize(context, snapshot, readings(context, snapshot, id), id, rings, 300, 280, refresh, refreshing)))
            val options = manager.getAppWidgetOptions(id)
            val width = options.getInt(AppWidgetManager.OPTION_APPWIDGET_MIN_WIDTH, 160).coerceAtLeast(110)
            val height = options.getInt(AppWidgetManager.OPTION_APPWIDGET_MIN_HEIGHT, 130).coerceAtLeast(130)
            return renderSize(context, snapshot, readings(context, snapshot, id), id, rings, width, height, refresh, refreshing)
        }
        /** Render bounded native gauges without exposing credentials, commands or account names. */
        fun renderSize(context: Context, snapshot: UsageSnapshot?, readings: List<QuotaProvider>, id: Int,
                       rings: Boolean, width: Int, height: Int, refresh: PendingIntent? = null, refreshing: Boolean = false): RemoteViews {
            val now = System.currentTimeMillis()
            val views = RemoteViews(context.packageName, R.layout.limits_widget)
            val scale = context.resources.displayMetrics.density
            val availableWidth = (width - 24).coerceAtLeast(86).toFloat()
            val availableHeight = (height - 64).coerceIn(60, 300).toFloat()
            val bitmap = createBitmap((availableWidth * scale).toInt().coerceAtLeast(1), (availableHeight * scale).toInt().coerceAtLeast(1))
            val canvas = Canvas(bitmap).apply { scale(scale, scale) }
            val accent = context.getColor(R.color.ts_widget_accent)
            val ink = context.getColor(R.color.ts_widget_text)
            val muted = context.getColor(R.color.ts_widget_muted)
            val paint = Paint(Paint.ANTI_ALIAS_FLAG).apply { typeface = androidx.core.content.res.ResourcesCompat.getFont(context, R.font.widget_manrope) ?: Typeface.create("sans-serif", Typeface.NORMAL) }
            fun text(value: String, x: Float, y: Float, maxWidth: Float, size: Float, color: Int, center: Boolean = false) {
                paint.style = Paint.Style.FILL; paint.color = color; paint.textSize = size * context.resources.configuration.fontScale; paint.textAlign = if (center) Paint.Align.CENTER else Paint.Align.LEFT
                if (value.endsWith("%")) paint.textSize *= (maxWidth / paint.measureText(value).coerceAtLeast(1f)).coerceAtMost(1f)
                val fitted = android.text.TextUtils.ellipsize(value, android.text.TextPaint(paint), maxWidth, android.text.TextUtils.TruncateAt.END).toString()
                canvas.drawText(fitted, x, y, paint)
            }
            val columns = if (rings) (availableWidth / 80).toInt().coerceIn(1, 3) else if (availableWidth >= 240) 3 else 1
            val rowHeight = if (rings) 84f else if (readings.size == 1) availableHeight else 62f
            val rowCount = (availableHeight / rowHeight).toInt().coerceAtLeast(1)
            val maximum = columns * rowCount
            val shown = readings.take(maximum)
            shown.forEachIndexed { index, provider ->
                val cellWidth = availableWidth / columns
                val column = index % columns
                val x = (if (context.resources.configuration.layoutDirection == View.LAYOUT_DIRECTION_RTL) columns - 1 - column else column) * cellWidth
                val y = index / columns * rowHeight
                val window = provider.peak(now)
                val expired = window == null && provider.windows.any { it.expired(now) }
                val percent = window?.let { NumberFormat.getIntegerInstance().format(it.percent) + "%" } ?: "—"
                val color = when { (window?.percent ?: 0.0) >= 100 -> context.getColor(R.color.ts_widget_danger)
                    (window?.percent ?: 0.0) >= 85 -> context.getColor(R.color.ts_widget_warning); else -> accent }
                if (rings) {
                    val diameter = if (availableHeight < 84) 38f else 46f
                    val cx = x + cellWidth / 2
                    val rect = RectF(cx - diameter / 2, y + 3, cx + diameter / 2, y + 3 + diameter)
                    paint.style = Paint.Style.STROKE; paint.strokeWidth = 4f; paint.strokeCap = Paint.Cap.ROUND; paint.color = muted; paint.alpha = 55
                    canvas.drawArc(rect, 0f, 360f, false, paint); paint.alpha = 255; paint.color = color
                    if (window != null) canvas.drawArc(rect, -90f, window.fraction * 360, false, paint)
                    text(percent, cx, y + diameter / 2 + 8, diameter - 8, 14f, ink, true)
                    text(provider.name, cx, y + diameter + 18, cellWidth - 6, 11f, ink, true)
                    if (availableHeight >= 84) text(if (expired) context.getString(R.string.widget_reset_passed) else window?.displayLabel ?: context.getString(R.string.widget_no_reading),
                        cx, y + diameter + 31, cellWidth - 6, 9f, muted, true)
                } else {
                    text(provider.name, x + 2, y + 13, cellWidth - 8, 12f, ink)
                    val windows = if (readings.size == 1) provider.windows.take((availableHeight / 46).toInt().coerceIn(1, 4)) else listOfNotNull(window ?: provider.windows.firstOrNull())
                    windows.forEachIndexed { wi, reading ->
                        val top = y + 29 + wi * 46
                        val label = if (reading.expired(now)) context.getString(R.string.widget_reset_passed) else reading.displayLabel
                        text(label, x + 2, top, cellWidth - 38, 9f, muted)
                        text(if (reading.expired(now)) "—" else NumberFormat.getIntegerInstance().format(reading.percent) + "%", x + cellWidth - 35, top, 33f, 11f, ink)
                        paint.style = Paint.Style.FILL; paint.color = muted; paint.alpha = 55
                        canvas.drawRoundRect(x + 2, top + 7, x + cellWidth - 8, top + 12, 3f, 3f, paint)
                        paint.alpha = 255; paint.color = when { reading.percent >= 100 -> context.getColor(R.color.ts_widget_danger); reading.percent >= 85 -> context.getColor(R.color.ts_widget_warning); else -> accent }
                        if (!reading.expired(now)) canvas.drawRoundRect(x + 2, top + 7, x + 2 + (cellWidth - 10) * reading.fraction, top + 12, 3f, 3f, paint)
                        if (readings.size == 1 && reading.resetsAt != null && !reading.expired(now)) text(context.getString(R.string.widget_resets, android.text.format.DateUtils.getRelativeTimeSpanString(reading.resetsAt, now, 60_000)), x + 2, top + 26, cellWidth - 8, 9f, muted)
                    }
                }
            }
            views.setImageViewBitmap(R.id.limits_gauges, bitmap)
            views.setViewVisibility(R.id.limits_gauges, if (readings.isEmpty()) View.GONE else View.VISIBLE)
            views.setViewVisibility(R.id.limits_empty, if (readings.isEmpty()) View.VISIBLE else View.GONE)
            val oldest = shown.minOfOrNull { it.observedAt }
            val date = oldest?.let { android.text.format.DateUtils.formatDateTime(context, it, android.text.format.DateUtils.FORMAT_SHOW_DATE or android.text.format.DateUtils.FORMAT_SHOW_TIME or android.text.format.DateUtils.FORMAT_ABBREV_MONTH) }
            val status = when {
                refreshing -> context.getString(R.string.widget_updating)
                readings.isEmpty() -> context.getString(R.string.widget_open_to_sync)
                shown.any { it.stale(now) } -> context.getString(R.string.widget_cached, date.orEmpty())
                else -> context.getString(R.string.widget_used, date.orEmpty())
            } + if (readings.size > shown.size) " · +${readings.size - shown.size}" else ""
            views.setTextViewText(R.id.limits_status, status)
            views.setContentDescription(R.id.limits_status, status)
            views.setContentDescription(R.id.limits_gauges, shown.joinToString(". ") { provider ->
                provider.name + ": " + provider.windows.joinToString(", ") { window ->
                    if (window.expired(now)) context.getString(R.string.widget_reset_passed)
                    else window.displayLabel + " " + context.getString(R.string.widget_percent_used, NumberFormat.getIntegerInstance().format(window.percent)) +
                        (window.resetsAt?.let { " " + context.getString(R.string.widget_resets, java.util.Date(it).toString()) } ?: "")
                } + ". " + java.util.Date(provider.observedAt)
            })
            views.setOnClickPendingIntent(R.id.limits_root, QuickAccess.pendingIntent(context, "home"))
            views.setOnClickPendingIntent(R.id.limits_configure, PendingIntent.getActivity(context, id,
                Intent(context, LimitsWidgetConfigurationActivity::class.java).putExtra(AppWidgetManager.EXTRA_APPWIDGET_ID, id), PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE))
            views.setBoolean(R.id.limits_refresh, "setEnabled", !refreshing)
            if (refresh != null) views.setOnClickPendingIntent(R.id.limits_refresh, refresh)
            return views
        }
    }
}
